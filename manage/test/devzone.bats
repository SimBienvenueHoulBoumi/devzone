#!/usr/bin/env bats
# devzone command: module state, activation, deactivation, migration.
# Temporary HOME; fake npm and kubectl (no real installation).

install_faux_repowarden() {
    cat >"$BATS_TEST_TMPDIR/bin/repowarden" <<'REP'
#!/usr/bin/env bash
echo "repowarden $*" >>"$BATS_TEST_TMPDIR/repowarden.log"
case "$*" in
    *"agents init"*)
        mkdir -p "$HOME/.claude" "$HOME/.config/opencode/plugins" "$HOME/.claude/skills/repowarden" "$HOME/.config/opencode/skills/repowarden"
        printf '{\n  "hooks": {\n    "PreToolUse": [\n      {\n        "matcher": "Bash",\n        "hooks": [\n          {\n            "type": "command",\n            "command": "repowarden garde"\n          }\n        ]\n      }\n    ]\n  }\n}\n' >"$HOME/.claude/settings.json"
        printf '#!/usr/bin/env bash\necho garde\n' >"$HOME/.config/opencode/plugins/repowarden-garde.js"
        printf '# repowarden\n' >"$HOME/.claude/skills/repowarden/SKILL.md"
        printf '# repowarden\n' >"$HOME/.config/opencode/skills/repowarden/SKILL.md"
        ;;
    *"agents retirer"*)
        tmp="$(mktemp)"
        jq '
            if (.hooks.PreToolUse // null) != null then
                .hooks.PreToolUse = [
                    .hooks.PreToolUse[] |
                    .hooks = [ (.hooks // [])[] | select(((.command // "") | (contains("repowarden garde") or contains("repowarden guard"))) | not) ] |
                    select((.hooks | length) > 0)
                ] |
                if (.hooks.PreToolUse | length) == 0 then del(.hooks.PreToolUse) else . end |
                if ((.hooks // {}) | keys | length) == 0 then del(.hooks) else . end
            else . end
        ' "$HOME/.claude/settings.json" >"$tmp"
        if [ "$(cat "$tmp")" = "{}" ]; then
            rm -f "$tmp" "$HOME/.claude/settings.json"
        else
            mv "$tmp" "$HOME/.claude/settings.json"
        fi
        rm -f "$HOME/.config/opencode/plugins/repowarden-garde.js" "$HOME/.config/opencode/plugins/repowarden-garde-v2.js"
        rm -f "$HOME/.claude/skills/repowarden/SKILL.md" "$HOME/.config/opencode/skills/repowarden/SKILL.md"
        ;;
esac
REP
    chmod +x "$BATS_TEST_TMPDIR/bin/repowarden"
}

# Fingerprint of a module's HOME files (files + sums, sorted):
# to compare the state before and after an enable/disable cycle (#242)
empreinte() {
    local folder f
    for folder in .claude .config/opencode .local/state; do
        if [ -e "$HOME/$folder" ]; then
            find "$HOME/$folder" -type f -print | sort | while IFS= read -r f; do
                sha256sum "$f"
            done
        fi
    done | sha256sum | awk '{print $1}'
}

# ~/.kube/cache/ is the cache of kubectl itself, not a configuration
# written by devzone: outside the fingerprint
kube_empreinte() {
    find "$HOME/.kube" -path "$HOME/.kube/cache" -prune -o -type f -print 2>/dev/null | sort | while IFS= read -r f; do
        sha256sum "$f"
    done | sha256sum | awk '{print $1}'
}

setup() {
    load commun
    kube_isole
    kind_vide
    export DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    # Go binary of the pod, built outside the image: the launcher uses it for
    # the commands ported to Go (help, repair, state helpers). Built once per file.
    devzone_go_pret ./cmd/devzone-pod
    # Pinned versions read from the files: an automatic bump (versions
    # workflow) does not break these tests
    REPOWARDEN_FIGE="$(sed -nE 's/^REPOWARDEN_VERSION=([^[:space:]]+)$/\1/p' "$BATS_TEST_DIRNAME/../../.devcontainer/versions.env" | head -1)"
    IA_FIGES="$(sed -nE 's/^IA_[A-Z0-9_]+=([^[:space:]()"]+)@([^@[:space:]()"]+)$/\1 \2/p' "$DEVZONE")"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin"
    # Outside the clone: its .git/config (a contributor's local identity) and
    # the system configuration would distort the "git identity" state
    cd "$BATS_TEST_TMPDIR" || return 1
    export GIT_CONFIG_NOSYSTEM=1
    # Fake devzone root: worktrees of the real repository do not interfere
    export DEVZONE_ROOT="$BATS_TEST_TMPDIR/racine"
    mkdir -p "$DEVZONE_ROOT/workspace"
    # Fake npm: logs its arguments; "npm ls -g --depth=0 --json" returns the
    # installed tools (NPM_INSTALLEES). Installation of the AI assistants:
    # lasts NPM_DUREE seconds, creates fake claude and opencode;
    # NPM_ECHEC=1 -> always fails, the first N fail (NPM_IA_ECHECS), with an
    # npm journal written like the real one (~/.npm/_logs), or they succeed
    # without opencode (NPM_IA_SANS_BINAIRE: optional binary dropped by npm, #194)
    export NPM_LOG="$BATS_TEST_TMPDIR/npm.log"
    export NPM_INSTALLEES="$BATS_TEST_TMPDIR/installees"
    export NPM_BIN="$BATS_TEST_TMPDIR/bin"
    : >"$NPM_INSTALLEES"
    cat >"$BATS_TEST_TMPDIR/bin/npm" <<'NPM'
#!/usr/bin/env bash
echo "npm $*" >>"$NPM_LOG"
if [ "${1:-}" = view ]; then
    sleep "${NPM_VIEW_DUREE:-0}"
    [ "${NPM_VIEW_CODE:-0}" -eq 0 ] || exit "${NPM_VIEW_CODE:-0}"
    [ -n "${NPM_PUBLIEE:-}" ] && printf '%s\n' "$NPM_PUBLIEE"
    exit 0
fi
if [ "${1:-}" = install ]; then
    sleep "${NPM_DUREE:-0}"
    if [[ " $* " == *"claude-code@"* ]]; then
        printf '#!/usr/bin/env bash\necho "2.1.0 (Claude Code)"\n' >"$NPM_BIN/claude"
        chmod +x "$NPM_BIN/claude"
    fi
    if [[ " $* " == *" opencode-ai@"* ]]; then
        n="$(grep -c "^npm install.* opencode-ai@" "$NPM_LOG")"
        if [ "${NPM_ECHEC:-0}" = 1 ] || [ "$n" -le "${NPM_IA_ECHECS:-0}" ]; then
            mkdir -p "$HOME/.npm/_logs"
            echo "error code EBADPLATFORM" >"$HOME/.npm/_logs/2026-10-24T11_46_18_245Z-debug-0.log"
            echo "npm error A complete log of this run can be found in: $HOME/.npm/_logs/2026-10-24T11_46_18_245Z-debug-0.log" >&2
            exit 1
        fi
        if [ "$n" -gt "${NPM_IA_SANS_BINAIRE:-0}" ]; then
            printf '#!/usr/bin/env bash\necho 1.0.0\n' >"$NPM_BIN/opencode"
        else
            printf '#!/usr/bin/env bash\necho "binaire absent" >&2\nexit 1\n' >"$NPM_BIN/opencode"
        fi
        chmod +x "$NPM_BIN/opencode"
    fi
fi
if [ "${1:-}" = ls ] && [ "${2:-}" = -g ]; then
    printf '{"dependencies":{'
    sep=""
    while read -r p v; do
        [ -n "$p" ] || continue
        printf '%s"%s":{"version":"%s"}' "$sep" "$p" "$v"
        sep=","
    done <"$NPM_INSTALLEES"
    printf '}}\n'
fi
NPM
    # Fake repowarden: logs its arguments (guard of the ai module)
    printf '#!/usr/bin/env bash\necho "repowarden $*" >>"%s/repowarden.log"\n' "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/bin/repowarden"
    # kubectl is faked: kubernetes is tested from the state only
    printf '#!/usr/bin/env bash\nexit 1\n' >"$BATS_TEST_TMPDIR/bin/kubectl"
    # Fake gh: GH_ETAT = absent (default), without (connected without workflow), with
    cat >"$BATS_TEST_TMPDIR/bin/gh" <<'GH'
#!/usr/bin/env bash
case "${GH_ETAT:-absent}" in
    absent) echo "You are not logged into any GitHub hosts." >&2; exit 1 ;;
    without) echo "  - Token scopes: 'gist', 'read:org', 'repo'" ;;
    with) echo "  - Token scopes: 'gist', 'read:org', 'repo', 'workflow'" ;;
esac
GH
    cat >"$BATS_TEST_TMPDIR/bin/devzone" <<'DEVZONE'
#!/usr/bin/env bash
case "$*" in
    "cluster clean"*) exit 0 ;;
    "metrics remove") exec "$DEVZONE" metrics remove ;;
esac
exit 0
DEVZONE
    chmod +x "$BATS_TEST_TMPDIR/bin/"*
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "disable kubernetes: removes the host config file, without starting anything" {
    mkdir -p "$HOME/.kube" && touch "$HOME/.kube/hote.config"
    run bash "$DEVZONE" disable kubernetes
    [ "$status" -eq 0 ]
    [ ! -e "$HOME/.kube/hote.config" ]
    [[ "$output" == *"kubernetes disabled"* ]] || false
}

@test "disable kubernetes: metrics-server removed only from the marked context, others left" {
    cat >"$BATS_TEST_TMPDIR/kube-contexts" <<'CTX'
kind-dev
kind-staging
CTX
    cat >"$BATS_TEST_TMPDIR/kube-marcus" <<'CTX'
kind-dev
CTX
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
args="$*"
case "$args" in
    *"get-contexts"*)
        cat "$KUBE_CONTEXTS_FILE"
        ;;
    *"get deployment metrics-server"*)
        contexte=""
        prev=""
        for a in "$@"; do
            if [ "$prev" = "--context" ]; then contexte="$a"; fi
            prev="$a"
        done
        # Like the real kubectl: a name with a selector is refused (#255)
        if [[ "$args" == *" -l "* ]]; then
            echo "error: name cannot be provided when a selector is specified" >&2
            exit 1
        fi
        # metrics-server present in every context; marked for devzone
        # only in the contexts of KUBE_MARKED_FILE (label read by jsonpath)
        if [[ "$args" == *"jsonpath"* ]] && grep -qxF "$contexte" "$KUBE_MARKED_FILE"; then
            printf 'installe'
        fi
        exit 0
        ;;
    *"config view"*)
        ctx="$(printf '%s' "$args" | sed -n 's/.*name=="\([^"]*\)".*/\1/p')"
        if [[ "$args" == *".cluster.server"* ]]; then echo "https://127.0.0.1:6443"; else echo "$ctx"; fi
        exit 0
        ;;
    *"delete -f"*)
        contexte=""
        prev=""
        for a in "$@"; do
            if [ "$prev" = "--context" ]; then contexte="$a"; fi
            prev="$a"
        done
        echo "delete -f $contexte" >>"${KUBE_DELETE_LOG}"
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
KUBE
    chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
    export KUBE_CONTEXTS_FILE="$BATS_TEST_TMPDIR/kube-contexts"
    export KUBE_MARKED_FILE="$BATS_TEST_TMPDIR/kube-marcus"
    export KUBE_DELETE_LOG="$BATS_TEST_TMPDIR/kube-delete.log"
    : >"$KUBE_DELETE_LOG"
    run bash "$DEVZONE" disable kubernetes
    [ "$status" -eq 0 ]
    [ "$(cat "$KUBE_DELETE_LOG")" = "delete -f kind-dev" ]
    [[ "$output" == *"metrics-server present without a devzone mark, left: kind-staging"* ]] || false
}

@test "disable kubernetes: enable + disable cycle -> ~/.kube identical" {
    mkdir -p "$HOME/.kube"
    touch "$HOME/.kube/config"
    # Neither a kind cluster nor a workstation cluster: only what devzone writes counts
    printf '#!/usr/bin/env bash\nexit 0\n' >"$BATS_TEST_TMPDIR/bin/kind"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$BATS_TEST_TMPDIR/bin/kubectl"
    chmod +x "$BATS_TEST_TMPDIR/bin/kind" "$BATS_TEST_TMPDIR/bin/kubectl"
    kube_empreinte_avant="$(kube_empreinte)"
    run bash "$DEVZONE" enable kubernetes
    [ "$status" -eq 0 ]
    run bash "$DEVZONE" disable kubernetes
    [ "$status" -eq 0 ]
    [ "$(kube_empreinte)" = "$kube_empreinte_avant" ]
}

@test "unknown module: message and error, state intact" {
    run bash "$DEVZONE" enable nexistepas
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown module : nexistepas"* ]] || false
    run bash "$DEVZONE" enable
    [ "$status" -eq 1 ]
    run bash "$DEVZONE" is-enabled nexistepas
    [ "$status" -eq 2 ]
}

@test "unknown command : erreur" {
    run bash "$DEVZONE" truc
    [ "$status" -eq 1 ]
}

@test "ai: pod binary absent -> Go message, exit 1, no loop (#882)" {
    # DEVZONE_NO_GO=1 skips the pod binary: the shell reaches the case as if it were absent
    run timeout 30 env DEVZONE_NO_GO=1 bash "$DEVZONE" ai
    [ "$status" -eq 1 ]
    [ "$output" = "devzone ai: Go binary of the pod unavailable (.devcontainer/bin)" ]
}

@test "enable ai: works without devzone on PATH, the launcher calls itself by its path (#882)" {
    # The host may have a devzone (the launcher is linked in /usr/local/bin): PATH is cleaned
    rm -f "$BATS_TEST_TMPDIR/bin/devzone"
    local dir clean=""
    while IFS= read -r dir; do
        [ -x "$dir/devzone" ] || clean="$clean:$dir"
    done < <(tr ':' '\n' <<<"$PATH")
    export PATH="${clean#:}"
    ! command -v devzone || false
    run timeout 300 bash "$DEVZONE" enable ai
    [ "$status" -eq 0 ]
    [[ "$output" != *"command not found"* ]] || false
    grep -qx 'ai=on' "$DEVZONE_ROOT/.devzone.modules"
}

@test "active: code 0 or 1, without writing anything (startup scripts test)" {
    run bash "$DEVZONE" is-enabled ai
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    bash "$DEVZONE" enable ai >/dev/null
    run bash "$DEVZONE" is-enabled ai
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run bash "$DEVZONE" is-enabled kubernetes
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "shared Claude connection: reported when the state is created, once" {
    mkdir -p "$HOME/.claude" && echo '{}' >"$HOME/.claude/.credentials.json"
    run bash "$DEVZONE" is-enabled ai
    [ "$status" -ne 0 ]
    [[ "$output" == *"shared Claude Code/opencode connection found: devzone enable ai to use it here"* ]] || false
    run bash "$DEVZONE" is-enabled ai
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "shared opencode connection: reported when the state is created, once" {
    mkdir -p "$HOME/.local/share/opencode" && echo '{}' >"$HOME/.local/share/opencode/auth.json"
    run bash "$DEVZONE" is-enabled ai
    [ "$status" -ne 0 ]
    [[ "$output" == *"shared Claude Code/opencode connection found"* ]] || false
    run bash "$DEVZONE" is-enabled ai
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "shared connection: never reported when the state is taken over (migration)" {
    mkdir -p "$HOME/.config/devzone" "$HOME/.claude"
    printf 'ai=on\nkubernetes=on\n' >"$HOME/.config/devzone/modules"
    echo '{}' >"$HOME/.claude/.credentials.json"
    run bash "$DEVZONE" is-enabled ai
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "migration: former global state taken over once, source removed" {
    mkdir -p "$HOME/.config/devzone"
    printf 'ai=on\nkubernetes=on\n' >"$HOME/.config/devzone/modules"
    run bash "$DEVZONE" is-enabled ai
    [ "$status" -eq 0 ]
    [ -f "$DEVZONE_ROOT/.devzone.modules" ]
    [ ! -e "$HOME/.config/devzone/modules" ]
    grep -qx 'ai=on' "$DEVZONE_ROOT/.devzone.modules"
}

@test "migration: second devzone (source already moved) -> default values" {
    mkdir -p "$HOME/.config/devzone"
    printf 'ai=on\nkubernetes=on\n' >"$HOME/.config/devzone/modules"
    bash "$DEVZONE" is-enabled ai
    export DEVZONE_ROOT="$BATS_TEST_TMPDIR/racine2"
    mkdir -p "$DEVZONE_ROOT/workspace"
    run bash "$DEVZONE" is-enabled ai
    [ "$status" -ne 0 ]
    [ -f "$DEVZONE_ROOT/.devzone.modules" ]
    grep -qx 'ai=off' "$DEVZONE_ROOT/.devzone.modules"
    grep -qx 'kubernetes=off' "$DEVZONE_ROOT/.devzone.modules"
}

@test "apply: outdated repowarden -> installed at the pinned version" {
    printf 'repowarden 4.9.2\n' >"$NPM_INSTALLEES"
    run bash "$DEVZONE" apply
    [ "$status" -eq 0 ]
    RPW=repowarden
    grep -qx "npm install -g ${RPW}@$REPOWARDEN_FIGE" "$BATS_TEST_TMPDIR/npm.log"
    grep -qx "repowarden install --global --lang fr" "$BATS_TEST_TMPDIR/repowarden.log"
    [[ "$output" == *"repowarden 4.9.2 → $REPOWARDEN_FIGE"* ]] || false
}

@test "opencode template: hardened defaults (bash ask, secrets and curl denied)" {
    modele="$BATS_TEST_DIRNAME/../../.devcontainer/opencode.jsonc"
    grep -q '"edit": "allow"' "$modele"
    grep -q '"webfetch": "ask"' "$modele"
    grep -q '"\*": "ask"' "$modele"
    grep -q '"git \*": "allow"' "$modele"
    grep -q '"bats\*": "allow"' "$modele"
    grep -q '"gh auth token\*": "deny"' "$modele"
    grep -q '"gh auth status --show-token\*": "deny"' "$modele"
    grep -q '"\*hosts.yml\*": "deny"' "$modele"
    grep -q '"\*\.credentials\*": "deny"' "$modele"
    grep -q '"\*auth.json\*": "deny"' "$modele"
    grep -q '"\*/.ssh/\*": "deny"' "$modele"
    grep -q '"curl\*": "deny"' "$modele"
    grep -q '"wget\*": "deny"' "$modele"
}

@test "opencode template: deny rules come after allow rules (last pattern wins)" {
    modele="$BATS_TEST_DIRNAME/../../.devcontainer/opencode.jsonc"
    dernier_allow="$(grep -n '": "allow"' "$modele" | tail -1 | cut -d: -f1)"
    premier_deny="$(grep -n '": "deny"' "$modele" | head -1 | cut -d: -f1)"
    [ -n "$dernier_allow" ] && [ -n "$premier_deny" ]
    [ "$premier_deny" -gt "$dernier_allow" ]
}

@test ".gitignore: state and failure invisible to git status" {
    folder="$BATS_TEST_TMPDIR/git"
    mkdir -p "$folder" && cd "$folder" || return 1
    git init -q
    cp "$BATS_TEST_DIRNAME/../../.gitignore" ./.gitignore
    printf "ai=on\nkubernetes=on\n" >.devzone.modules
    printf "gitlab\n" >.devzone.modules-failed-gitlab
    run git status --porcelain
    [ "$status" -eq 0 ]
    [ -z "$(grep "\.devzone\.modules" <<<"$output")" ]
}


