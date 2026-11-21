#!/usr/bin/env bash
# devzone test-gitlab: end-to-end test of the gitlab module and of the GitLab
# platform, in the container. Each step is timed; the final summary gives
# ✔/✖/skipped and the exit code is 0 only without ✖.
#
# Why a separate script: the GitHub CI does not have the 8 GB of RAM of the gitlab
# module. This test therefore replays by hand, on the workstation, what the CI
# cannot do, and possibly publishes its result as a commit status.
#
# Options: --complet (disables then reinstalls), --statut (publishes the
# gitlab-integration status on HEAD with gh).
# The steps are called indirectly by run_step: shellcheck cannot see it and
# would take them for unreachable (SC2317).
# shellcheck disable=SC2317
set -uo pipefail

ICI="$(cd "$(dirname "$0")" && pwd)"
# Same root as gitlab.sh: DEVZONE_ROOT for the tests
RACINE="${DEVZONE_ROOT:-$(dirname "$(dirname "$ICI")")}"
GITLAB="$ICI/gitlab.sh"
SECRETS="$RACINE/workspace/.gitlab"
TOKEN_FILE="$SECRETS/root-token"
STATE_FILE="${DEVZONE_STATE:-$RACINE/.devzone.modules}"
HOSTS="${DEVZONE_HOSTS:-/etc/hosts}"
# Instance name: DEVZONE_INSTANCE suffix computed by cluster.sh, as in
# gitlab.sh (suffixed devzone-gitlab namespace).
# shellcheck source=SCRIPTDIR/../cluster.sh
# shellcheck disable=SC1091
. "$ICI/../cluster.sh"
# shellcheck source=SCRIPTDIR/test-gitlab-restes.sh
# shellcheck disable=SC1091
. "$ICI/test-gitlab-restes.sh"
URL="${GITLAB_TEST_URL:-http://gitlab.localhost:8929}"
# Pipeline timeout: 600 s by default, short in the tests
PIPELINE_TIMEOUT="${GITLAB_TEST_PIPELINE:-600}"
# Pipeline polling interval: 5 s by default, short in the tests
INTERVAL="${GITLAB_TEST_INTERVALLE:-5}"
# Ref of the repowarden integration suite (#533)
REPOWARDEN_REF="${REPOWARDEN_TEST_REF:-develop}"

# devzone itself: the command of the PATH (link set by post-create.sh), otherwise
# the script of the repository. DEVZONE_TEST_DEVZONE allows a test double.
DEVZONE_BIN="${DEVZONE_TEST_DEVZONE:-}"
if [ -z "$DEVZONE_BIN" ]; then
    if command -v devzone >/dev/null 2>&1; then
        DEVZONE_BIN=devzone
    else
        DEVZONE_BIN="$RACINE/.devcontainer/devzone"
    fi
fi
# Same path as devzone: glab lives in ~/.local/bin, never in the PATH
GLAB="$HOME/.local/bin/glab"

FULL=0
PUBLISH=0
TOKEN=""
KEY_ID=""
FAILED=0
TOTAL=0
REASON=""
PLATFORM_CHANGED=0
TMP_DIRS=()
NAMES=()
SYMBOLS=()
DURATIONS=()
SUFFIXES=()

# Previous platform, read from the same state file as devzone: the trap
# must be able to restore it even if step 6 fails midway.
PLATFORM_BEFORE="$(grep -E '^platform=' "$STATE_FILE" 2>/dev/null | tail -1 | cut -d= -f2 || true)"
[ "$PLATFORM_BEFORE" = gitlab ] || PLATFORM_BEFORE=github
URL_BEFORE="$(grep -E '^gitlab_url=' "$STATE_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true)"

usage() {
    cat <<'USAGE'
devzone test-gitlab [--complet] [--statut]

End-to-end test of the gitlab module and of the GitLab platform.
  --complet   disables gitlab, checks that nothing remains, then reinstalls
  --statut    publishes the result as the gitlab-integration status on HEAD (gh)
USAGE
}

# GitLab API call: the token never appears in a message nor in a file of the
# clone. curl receives it in a header, as the seed of gitlab.sh does.
api() {
    local method="$1" path="$2"
    shift 2
    curl -sS --fail --request "$method" --header "PRIVATE-TOKEN: ${TOKEN:-}" \
        "${URL}/api/v4${path}" "$@"
}

read_token() {
    if [ ! -f "$TOKEN_FILE" ]; then
        REASON="root token missing ($TOKEN_FILE): run with the devzone test-gitlab command of the PATH, or set DEVZONE_ROOT to the root of the enabled repository"
        return 1
    fi
    TOKEN="$(cat "$TOKEN_FILE")"
    if [ -z "$TOKEN" ]; then
        REASON="root token empty ($TOKEN_FILE)"
        return 1
    fi
    return 0
}

# Restores the previous platform (github by default, or the GitLab instance with its
# URL). The trap calls it too: an interrupted step 6 does not leave the
# platform of the user changed.
restore_platform() {
    if [ "$PLATFORM_BEFORE" = gitlab ] && [ -n "$URL_BEFORE" ]; then
        "$DEVZONE_BIN" platform gitlab --url "$URL_BEFORE" >/dev/null 2>&1
    else
        "$DEVZONE_BIN" platform github >/dev/null 2>&1
    fi
}

# Guaranteed cleanup: throwaway SSH key removed from GitLab, temporary folders
# deleted, previous platform restored. Even when a step failed.
cleanup() {
    local code=$? d
    trap - EXIT
    if [ -n "${KEY_ID:-}" ]; then
        api DELETE "/user/keys/$KEY_ID" >/dev/null 2>&1 || true
    fi
    if [ "$PLATFORM_CHANGED" = 1 ]; then
        restore_platform || true
    fi
    for d in ${TMP_DIRS[@]+"${TMP_DIRS[@]}"}; do
        [ -n "$d" ] && rm -rf "$d"
    done
    exit "$code"
}
trap cleanup EXIT

# ---- The steps, one function per step ----

# 1. Module: active, otherwise enabled (the activation also installs if needed).
step_module() {
    if "$DEVZONE_BIN" is-enabled gitlab >/dev/null 2>&1; then
        return 0
    fi
    if ! "$DEVZONE_BIN" enable gitlab >/dev/null 2>&1; then
        REASON="devzone enable gitlab failed"
        return 1
    fi
    return 0
}

# 2. State: the module must be ready and its runner online (without a runner, the
# pipeline would wait forever).
step_state() {
    local state
    state="$(bash "$GITLAB" status 2>&1 || true)"
    if [[ "$state" != *"ready"* ]]; then
        REASON="state: ${state:-unreadable}"
        return 1
    fi
    if [[ "$state" != *"runner online"* ]]; then
        REASON="runner offline ($state)"
        return 1
    fi
    return 0
}

# 3. Name and relays: ssh and glab go through the system resolver; curl and
# git in HTTP resolve *.localhost to the loopback without reading /etc/hosts.
# gitlab.localhost must therefore point to 127.0.0.1 AND the relays 8929/2224
# must run in the container (gitlab.sh hote-poser, relay-start).
step_name() {
    local host ip_name relays
    host="$(getent hosts gitlab.localhost 2>/dev/null || true)"
    ip_name="$(printf '%s\n' "$host" | awk '{print $1; exit}')"
    if [ -z "$ip_name" ]; then
        REASON="gitlab.localhost not resolved (getent hosts)"
        return 1
    fi
    if [ "$ip_name" != "127.0.0.1" ]; then
        REASON="gitlab.localhost resolves to $ip_name, expected 127.0.0.1"
        return 1
    fi
    if ! relays="$(bash "$GITLAB" relay-status 2>&1)"; then
        REASON="gitlab.localhost points to 127.0.0.1, but ${relays:-gitlab relay stopped}"
        return 1
    fi
    return 0
}

# 4. Pipeline: starts the one of devzone/demo on main and waits for success.
step_pipeline() {
    local response id web_url state start
    read_token || return 1
    response="$(api POST "/projects/devzone%2Fdemo/pipeline" --data "ref=main" 2>/dev/null)" || {
        REASON="creation of the pipeline of devzone/demo impossible"
        return 1
    }
    id="$(printf '%s' "$response" | jq -r '.id // empty' 2>/dev/null || true)"
    web_url="$(printf '%s' "$response" | jq -r '.web_url // empty' 2>/dev/null || true)"
    if [ -z "$id" ]; then
        REASON="pipeline creation response without id"
        return 1
    fi
    start="$(date +%s)"
    while :; do
        response="$(api GET "/projects/devzone%2Fdemo/pipelines/$id" 2>/dev/null || true)"
        state="$(printf '%s' "$response" | jq -r '.status // empty' 2>/dev/null || true)"
        case "$state" in
            success) return 0 ;;
            failed | canceled | skipped)
                REASON="pipeline $state: ${web_url:-$URL/devzone/demo/-/pipelines/$id}"
                return 1
                ;;
        esac
        if [ $(( $(date +%s) - start )) -ge "$PIPELINE_TIMEOUT" ]; then
            REASON="timeout ${PIPELINE_TIMEOUT} s exceeded (state ${state:-unknown}): ${web_url:-$URL/devzone/demo/-/pipelines/$id}"
            return 1
        fi
        sleep "$INTERVAL"
    done
}

# 5. HTTP and SSH clones: throwaway ed25519 key placed on root, then removed
# by the trap. The HTTP clone authenticates with Basic oauth2 + token, provided
# by a credential helper that reads the file (a git http.extraHeader would pass
# the token in clear in the arguments of a process): the token appears neither
# in these arguments, nor in the URL, nor in .git/config.
step_clones() {
    local d pub response
    read_token || return 1
    d="$(mktemp -d "${TMPDIR:-/tmp}/devzone-test-gitlab-clones.XXXXXX")" || {
        REASON="temporary directory impossible"
        return 1
    }
    TMP_DIRS+=("$d")
    if ! ssh-keygen -q -t ed25519 -N '' -f "$d/id_ed25519" >/dev/null 2>&1; then
        REASON="ed25519 key generation impossible"
        return 1
    fi
    pub="$(cat "$d/id_ed25519.pub" 2>/dev/null || true)"
    response="$(api POST "/user/keys" --data-urlencode "title=devzone test-gitlab" \
        --data-urlencode "key=$pub" 2>/dev/null)" || {
        REASON="SSH key upload to GitLab impossible"
        return 1
    }
    KEY_ID="$(printf '%s' "$response" | jq -r '.id // empty' 2>/dev/null || true)"
    if [ -z "$KEY_ID" ]; then
        REASON="key upload response without id"
        return 1
    fi
    if ! git clone -q \
        -c "core.sshCommand=ssh -i $d/id_ed25519 -o UserKnownHostsFile=$d/known_hosts -o StrictHostKeyChecking=accept-new" \
        "ssh://git@gitlab.localhost:2224/devzone/demo.git" "$d/ssh-demo" >/dev/null 2>&1; then
        REASON="SSH clone (ssh://git@gitlab.localhost:2224/devzone/demo.git) impossible"
        return 1
    fi
    if ! git -c credential.helper= \
        -c "credential.helper=!f() { echo username=oauth2; printf 'password='; cat \"$TOKEN_FILE\"; echo; }; f" \
        clone -q "$URL/devzone/demo.git" "$d/http-demo" >/dev/null 2>&1; then
        REASON="HTTP clone of devzone/demo impossible"
        return 1
    fi
    if grep -qF "$TOKEN" "$d/http-demo/.git/config" 2>/dev/null; then
        REASON="the token was written to .git/config of the clone"
        return 1
    fi
    return 0
}

# 6. Platform: gitlab (glab clone), then back to the previous platform;
# when back to github, glab and its configuration must no longer be there.
step_platform() {
    local d
    d="$(mktemp -d "${TMPDIR:-/tmp}/devzone-test-gitlab-plateforme.XXXXXX")" || {
        REASON="temporary directory impossible"
        return 1
    }
    TMP_DIRS+=("$d")
    PLATFORM_CHANGED=1
    if ! "$DEVZONE_BIN" platform gitlab >/dev/null 2>&1; then
        REASON="devzone platform gitlab failed"
        return 1
    fi
    if ! "$GLAB" repo clone devzone/demo "$d/demo" >/dev/null 2>&1; then
        REASON="glab repo clone devzone/demo failed"
        return 1
    fi
    if ! restore_platform; then
        REASON="return to platform $PLATFORM_BEFORE impossible"
        return 1
    fi
    if [ "$PLATFORM_BEFORE" = github ]; then
        if [ -e "$GLAB" ] || [ -e "$HOME/.config/glab-cli" ]; then
            REASON="glab or its configuration remains after returning to github"
            return 1
        fi
    fi
    PLATFORM_CHANGED=0
    return 0
}

# 7. repowarden integration: test/gitlab/ suite (#533) against the instance of the
# module, with the URL and the token as environment variables. Missing at the
# chosen ref -> step skipped, not failed.
step_repowarden() {
    local d log bats_exit bats_output
    read_token || return 1
    d="$(mktemp -d "${TMPDIR:-/tmp}/devzone-test-gitlab-repowarden.XXXXXX")" || {
        REASON="temporary directory impossible"
        return 1
    }
    TMP_DIRS+=("$d")
    log="${TMPDIR:-/tmp}/devzone-test-gitlab-repowarden.log"
    if ! git clone -q --depth 1 --branch "$REPOWARDEN_REF" \
        https://github.com/simdevWarden/repowarden.git "$d/repowarden" >/dev/null 2>&1; then
        REASON="clone of repowarden (ref $REPOWARDEN_REF) impossible"
        return 1
    fi
    if [ ! -d "$d/repowarden/test/gitlab" ]; then
        REASON="test/gitlab missing at ref $REPOWARDEN_REF"
        return 2
    fi
    if ! command -v bats >/dev/null 2>&1; then
        REASON="bats not found"
        return 1
    fi
    if bats_output="$(REPOWARDEN_IT_GITLAB_URL="$URL" REPOWARDEN_IT_GITLAB_TOKEN="$TOKEN" \
        bats "$d/repowarden/test/gitlab/" 2>&1)"; then
        bats_exit=0
    else
        bats_exit=$?
    fi
    printf '%s' "$bats_output" | sed "s/${TOKEN}/TOKEN_MASKED/g" > "$log"
    if [ "$bats_exit" -ne 0 ]; then
        REASON="the test/gitlab suite failed (log: $log)"
        return 1
    fi
    return 0
}

# 8. --complet: disabling first, then checks that no namespace, container, secret
# or /etc/hosts line remains. Steps 1 to 7 then reinstall. The namespace is
# suffixed per instance, as in gitlab.sh.
step_full() {
    local leftovers="" instance namespace containers
    instance="${DEVZONE_INSTANCE:-devzone}"
    namespace="devzone-gitlab${INSTANCE_SUFFIX}"
    if ! "$DEVZONE_BIN" disable gitlab >/dev/null 2>&1; then
        leftovers="$leftovers disable failed;"
    fi
    if kubectl --context devzone get namespace "$namespace" >/dev/null 2>&1; then
        leftovers="$leftovers namespace $namespace;"
    fi
    containers="$(gitlab_restes_conteneurs "$instance")"
    if [ -n "$containers" ]; then
        leftovers="$leftovers labelled container(s) devzone.instance=$instance;"
    fi
    if [ -e "$SECRETS" ]; then
        leftovers="$leftovers $SECRETS;"
    fi
    if grep -q '# devzone:gitlab' "$HOSTS" 2>/dev/null; then
        leftovers="$leftovers /etc/hosts line;"
    fi
    if [ -n "$leftovers" ]; then
        REASON="remaining:$leftovers"
        return 1
    fi
    return 0
}

# ---- Common frame: times, records ✔/✖/skipped + reason ----

run_step() {
    local name="$1" func="$2" start end duration code symbol suffix
    REASON=""
    printf '▶ %s…\n' "$name"
    start="$(date +%s)"
    "$func"
    code=$?
    end="$(date +%s)"
    duration=$((end - start))
    case "$code" in
        0) symbol="✔"; suffix="" ;;
        2) symbol="–"; suffix=" — skipped: ${REASON:-no reason}" ;;
        *) symbol="✖"; FAILED=1; suffix=" — ${REASON:-failed}" ;;
    esac
    NAMES+=("$name")
    SYMBOLS+=("$symbol")
    DURATIONS+=("$duration")
    SUFFIXES+=("$suffix")
    printf '  %s %s (%d s)%s\n' "$symbol" "$name" "$duration" "$suffix"
}

# Short summary for the status: never a token, a description < 140 characters.
short_summary() {
    local i ok=0 failed=0 skipped=0 first_failed=""
    for i in "${!SYMBOLS[@]}"; do
        case "${SYMBOLS[$i]}" in
            ✔) ok=$((ok + 1)) ;;
            ✖) failed=$((failed + 1)); [ -n "$first_failed" ] || first_failed="${NAMES[$i]}" ;;
            *) skipped=$((skipped + 1)) ;;
        esac
    done
    if [ "$failed" -gt 0 ]; then
        printf '%d ✔, %d ✖ (%s), %d skipped — %d s' "$ok" "$failed" "$first_failed" "$skipped" "$TOTAL"
    else
        printf '%d ✔, %d skipped — %d s' "$ok" "$skipped" "$TOTAL"
    fi
}

summary() {
    local i ok=0 failed=0 skipped=0
    echo
    echo "devzone test-gitlab : summary"
    for i in "${!SYMBOLS[@]}"; do
        printf '  %s %-28s %3d s%s\n' "${SYMBOLS[$i]}" "${NAMES[$i]}" "${DURATIONS[$i]}" "${SUFFIXES[$i]}"
        case "${SYMBOLS[$i]}" in
            ✔) ok=$((ok + 1)) ;;
            ✖) failed=$((failed + 1)) ;;
            *) skipped=$((skipped + 1)) ;;
        esac
    done
    printf '  total: %d step(s), %d s, %d ✔, %d ✖, %d skipped\n' \
        "${#NAMES[@]}" "$TOTAL" "$ok" "$failed" "$skipped"
}

# --statut: publishes the result on the HEAD commit of the current repository, through
# the GitHub API of gh (maintainer token). Clear refusal if gh is not logged in.
publish_status() {
    local repo sha state description
    if ! gh auth status >/dev/null 2>&1; then
        echo "devzone test-gitlab : gh not logged in, gitlab-integration status not published (gh auth login -s workflow)" >&2
        return 1
    fi
    repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
    if [ -z "$repo" ]; then
        echo "devzone test-gitlab : current GitHub repository not found, status not published" >&2
        return 1
    fi
    sha="$(git rev-parse HEAD 2>/dev/null || true)"
    if [ -z "$sha" ]; then
        echo "devzone test-gitlab : HEAD commit not found, status not published" >&2
        return 1
    fi
    if [ "$FAILED" -eq 0 ]; then state=success; else state=failure; fi
    description="$(short_summary)"
    if ! gh api -X POST "repos/$repo/statuses/$sha" \
        -f state="$state" -f context=gitlab-integration -f description="$description" >/dev/null; then
        echo "devzone test-gitlab : publishing the gitlab-integration status impossible" >&2
        return 1
    fi
    echo "devzone test-gitlab : gitlab-integration status ($state) published on $repo@$sha"
}

# ---- Options and run ----

for arg in "$@"; do
    case "$arg" in
        --complet) FULL=1 ;;
        --statut) PUBLISH=1 ;;
        -h | --help) usage; exit 0 ;;
        *)
            echo "devzone test-gitlab : unknown option: $arg" >&2
            usage >&2
            exit 2
            ;;
    esac
done

START_TIME="$(date +%s)"

if [ "$FULL" = 1 ]; then
    run_step "8. full: disable" step_full
fi
run_step "1. module" step_module
run_step "2. state" step_state
run_step "3. host name" step_name
run_step "4. pipeline" step_pipeline
run_step "5. HTTP and SSH clones" step_clones
run_step "6. platform" step_platform
run_step "7. repowarden integration" step_repowarden

TOTAL=$(( $(date +%s) - START_TIME ))
summary

CODE=0
[ "$FAILED" -eq 0 ] || CODE=1
if [ "$PUBLISH" = 1 ]; then
    publish_status || CODE=1
fi
exit "$CODE"
