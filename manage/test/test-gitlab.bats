#!/usr/bin/env bats
# devzone test-gitlab (#263): end-to-end test of the gitlab module and of the
# platform. Fake kind, kubectl, curl, git, ssh-keygen, glab, gh, getent and
# devzone in the PATH: no cluster, no network, no real GitLab.
# Each fake binary logs its arguments in $BATS_TEST_TMPDIR/<tool>.log.

setup() {
    load commun
    kube_isole
    SCRIPT="$BATS_TEST_DIRNAME/../../.devcontainer/gitlab/test-gitlab.sh"
    export HOME="$BATS_TEST_TMPDIR/home"
    export DEVZONE_RACINE="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_ETAT="$BATS_TEST_TMPDIR/modules"
    export DEVZONE_HOSTS="$BATS_TEST_TMPDIR/hosts"
    export KIND_CLUSTERS="$BATS_TEST_TMPDIR/clusters"
    export GITLAB_TEST_PIPELINE=2
    export GITLAB_TEST_INTERVALLE=0
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"
    export DEVZONE_INSTANCE=mon-devzone
    export INSTANCE_TEST=-mon-devzone
    export DEVZONE_TEST_DEVZONE="$BATS_TEST_TMPDIR/bin/devzone"
    mkdir -p "$HOME/.local/bin" "$DEVZONE_RACINE/workspace/.gitlab" \
        "$BATS_TEST_TMPDIR/bin" "$TMPDIR"
    printf 'token-root-secret' >"$DEVZONE_RACINE/workspace/.gitlab/root-token"
    touch "$BATS_TEST_TMPDIR/namespace"
    # Web and SSH relays running: live PID (the test's own) in their folder
    for relay in web ssh; do
        mkdir -p "$DEVZONE_RACINE/workspace/.gitlab-$relay"
        echo $$ >"$DEVZONE_RACINE/workspace/.gitlab-$relay/relais.pid"
    done
    printf 'gitlab%s\n' "$INSTANCE_TEST" >"$KIND_CLUSTERS"
    printf 'kind-gitlab%s\nkind-dev\n' "$INSTANCE_TEST" >"$BATS_TEST_TMPDIR/contexts"
    printf '127.0.0.1 localhost\n127.0.0.1\tgitlab.localhost # devzone:gitlab\n' >"$DEVZONE_HOSTS"
    : >"$DEVZONE_ETAT"
    touch "$BATS_TEST_TMPDIR/module_active"

    # devzone: double of the commands used by test-gitlab.sh
    cat >"$BATS_TEST_TMPDIR/bin/devzone" <<'DEVZONE'
#!/usr/bin/env bash
echo "devzone $*" >>"$BATS_TEST_TMPDIR/devzone.log"
case "$1 $2" in
    "is-enabled gitlab")
        [ -f "$BATS_TEST_TMPDIR/module_active" ]
        exit $?
        ;;
    "enable gitlab")
        [ -n "${FAKE_ENABLE_FAIL:-}" ] && exit 1
        touch "$BATS_TEST_TMPDIR/module_active" "$BATS_TEST_TMPDIR/namespace"
        mkdir -p "$DEVZONE_RACINE/workspace/.gitlab"
        printf 'token-root-secret' >"$DEVZONE_RACINE/workspace/.gitlab/root-token"
        ;;
    "disable gitlab")
        [ -n "${FAKE_DISABLE_FAIL:-}" ] && exit 1
        rm -f "$BATS_TEST_TMPDIR/module_active"
        if [ "${FAKE_DISABLE_LEFT:-}" != namespace ]; then
            rm -f "$BATS_TEST_TMPDIR/namespace"
        fi
        if [ "${FAKE_DISABLE_LEFT:-}" != secrets ]; then
            rm -rf "$DEVZONE_RACINE/workspace/.gitlab"
        fi
        if [ "${FAKE_DISABLE_LEFT:-}" != hosts ]; then
            grep -v 'devzone:gitlab' "$DEVZONE_HOSTS" >"$DEVZONE_HOSTS.tmp" 2>/dev/null || true
            mv "$DEVZONE_HOSTS.tmp" "$DEVZONE_HOSTS"
        fi
        ;;
    "platform gitlab")
        [ -n "${FAKE_PLATFORM_FAIL:-}" ] && exit 1
        mkdir -p "$HOME/.local/bin" "$HOME/.config/glab-cli"
        cp "$BATS_TEST_TMPDIR/bin/glab" "$HOME/.local/bin/glab"
        chmod +x "$HOME/.local/bin/glab"
        grep -vE '^(plateforme|gitlab_url)=' "$DEVZONE_ETAT" >"$DEVZONE_ETAT.tmp" 2>/dev/null || true
        mv "$DEVZONE_ETAT.tmp" "$DEVZONE_ETAT"
        printf 'plateforme=gitlab\ngitlab_url=http://gitlab.localhost:8929\n' >>"$DEVZONE_ETAT"
        ;;
    "platform github")
        rm -f "$HOME/.local/bin/glab"
        rm -rf "$HOME/.config/glab-cli"
        grep -vE '^(plateforme|gitlab_url)=' "$DEVZONE_ETAT" >"$DEVZONE_ETAT.tmp" 2>/dev/null || true
        mv "$DEVZONE_ETAT.tmp" "$DEVZONE_ETAT"
        ;;
    "plateforme "*)
        echo "devzone : plateforme gitlab"
        ;;
    *)
        echo "devzone : unknown command: $*" >&2
        exit 1
        ;;
esac
exit 0
DEVZONE

    # kind: clusters held in $KIND_CLUSTERS
    cat >"$BATS_TEST_TMPDIR/bin/kind" <<'KIND'
#!/usr/bin/env bash
echo "kind $*" >>"$BATS_TEST_TMPDIR/kind.log"
case "$1 $2" in
    "get clusters") cat "$KIND_CLUSTERS" ;;
    "delete cluster") grep -vx "${4:-}" "$KIND_CLUSTERS" >"$KIND_CLUSTERS.tmp" || true; mv "$KIND_CLUSTERS.tmp" "$KIND_CLUSTERS" ;;
esac
KIND

    # kubectl: contexts held in a file
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"$BATS_TEST_TMPDIR/kubectl.log"
case "$*" in
    *"config get-contexts"*) cat "$BATS_TEST_TMPDIR/contexts" 2>/dev/null || true ;;
    *"config current-context"*) echo "${FAKE_CONTEXT:-kind-dev}" ;;
    *"get namespace "*) [ -f "$BATS_TEST_TMPDIR/namespace" ] && exit 0 ; exit 1 ;;
esac
exit 0
KUBE

    # docker: instance containers on the host's Docker
    cat >"$BATS_TEST_TMPDIR/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
echo "docker $*" >>"$BATS_TEST_TMPDIR/docker.log"
case "$*" in
    "ps -aq"*) [ -z "${FAKE_LABELLED_CONTAINERS:-}" ] || echo "$FAKE_LABELLED_CONTAINERS" ;;
esac
exit 0
DOCKER

    # curl: simulated GitLab API (pipeline, keys, module state)
    export CURL_SETUP="$BATS_TEST_TMPDIR/curl_setup"
    mkdir -p "$CURL_SETUP"
    printf '0' >"$CURL_SETUP/pipeline_count"
    cat >"$BATS_TEST_TMPDIR/bin/curl" <<'CURL'
#!/usr/bin/env bash
echo "curl $*" >>"$BATS_TEST_TMPDIR/curl.log"
[ -n "${FAKE_GITLAB_FAIL:-}" ] && exit 7
method=GET
url=""
while [ $# -gt 0 ]; do
    case "$1" in
        --request) method="$2"; shift 2 ;;
        --header | --data | --data-urlencode) shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
pipeline_file="$CURL_SETUP/pipeline_count"
    case "$url" in
    *"/api/v4/projects/devzone%2Fdemo/pipeline")
        [ -n "${FAKE_PIPELINE_CREATE_FAIL:-}" ] && exit 22
        printf '{"id":42,"web_url":"http://gitlab.localhost:8929/devzone/demo/-/pipelines/42"}\n'
        ;;
    *"/api/v4/projects/devzone%2Fdemo/pipelines/42")
        if [ -n "${FAKE_PIPELINE_STATE:-}" ]; then
            case "${FAKE_PIPELINE_STATE}" in
                success) printf '{"status":"success"}\n' ;;
                failed) printf '{"status":"failed"}\n' ;;
                *) printf '{"status":"running"}\n' ;;
            esac
        else
            # Default: running -> success at the next call
            pipeline_count="$(cat "$pipeline_file" 2>/dev/null || echo 0)"
            if [ "$pipeline_count" -eq 0 ]; then
                printf '{"status":"running"}\n'
            else
                printf '{"status":"success"}\n'
            fi
            printf '%d' $((pipeline_count + 1)) >"$pipeline_file"
        fi
        ;;
    *"/api/v4/user/keys/7") exit 0 ;;
    *"/api/v4/user/keys")
        [ -n "${FAKE_KEY_FAIL:-}" ] && exit 22
        printf '{"id":7}\n'
        ;;
    *"/api/v4/runners/all"*)
        if [ -n "${FAKE_RUNNERS:-}" ]; then
            printf '%s\n' "$FAKE_RUNNERS"
        else
            printf '%s\n' '[{"id":1}]'
        fi
        ;;
    *"/-/readiness"* | *"/users/sign_in"*) exit 0 ;;
    *"/api/v4/projects/devzone%2Fdemo/repository"*) exit 0 ;;
esac
exit 0
CURL

    # git: simulated clone; the repowarden suite is a real bats file
    cat >"$BATS_TEST_TMPDIR/bin/git" <<'GIT'
#!/usr/bin/env bash
echo "git $*" >>"$BATS_TEST_TMPDIR/git.log"
case "$*" in
    "rev-parse HEAD") echo "0123456789abcdef"; exit 0 ;;
esac
clone=0
for a in "$@"; do
    [ "$a" = clone ] && clone=1
done
if [ "$clone" = 1 ]; then
    for a in "$@"; do target="$a"; done
    case "$*" in
        *repowarden*)
            [ -n "${FAKE_REPOWARDEN_CLONE_FAIL:-}" ] && exit 1
            if [ -z "${FAKE_REPOWARDEN_NO_TEST:-}" ]; then
                mkdir -p "$target/test/gitlab"
                : >"$target/test/gitlab/forge.bats"
            else
                mkdir -p "$target"
            fi
            ;;
        *"ssh://git@"*)
            [ "${FAKE_CLONE_FAIL:-}" = ssh ] && exit 1
            mkdir -p "$target/.git"
            : >"$target/.git/config"
            ;;
        *"http://"* | *"https://"*)
            [ "${FAKE_CLONE_FAIL:-}" = http ] && exit 1
            mkdir -p "$target/.git"
            if [ -n "${FAKE_TOKEN_IN_CONFIG:-}" ]; then
                printf 'extraheader = PRIVATE-TOKEN: token-root-secret\n' >"$target/.git/config"
            else
                : >"$target/.git/config"
            fi
            ;;
        *)
            mkdir -p "$target/.git"
            : >"$target/.git/config"
            ;;
    esac
fi
exit 0
GIT

    # ssh-keygen: fake throwaway key
    cat >"$BATS_TEST_TMPDIR/bin/ssh-keygen" <<'SSHKEYGEN'
#!/usr/bin/env bash
echo "ssh-keygen $*" >>"$BATS_TEST_TMPDIR/ssh-keygen.log"
[ -n "${FAKE_SSH_KEYGEN_FAIL:-}" ] && exit 1
f=""
while [ $# -gt 0 ]; do
    case "$1" in
        -f) f="$2"; shift 2 ;;
        *) shift ;;
    esac
done
[ -n "$f" ] || exit 1
printf 'private-key\n' >"$f"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI test@devzone\n' >"$f.pub"
SSHKEYGEN

    # glab: simulated clone
    cat >"$BATS_TEST_TMPDIR/bin/glab" <<'GLAB'
#!/usr/bin/env bash
echo "glab $*" >>"$BATS_TEST_TMPDIR/glab.log"
case "$*" in
    "repo clone"*)
        [ -n "${FAKE_GLAB_CLONE_FAIL:-}" ] && exit 1
        for a in "$@"; do target="$a"; done
        mkdir -p "$target/.git"
        : >"$target/.git/config"
        ;;
    "--version") echo "glab 1.0.0" ;;
esac
exit 0
GLAB

    # bats: the simulated repowarden integration suite; on failure, it
    # prints the token received, to check that it is masked in the log
    cat >"$BATS_TEST_TMPDIR/bin/bats" <<'BATS'
#!/usr/bin/env bash
echo "bats $*" >>"$BATS_TEST_TMPDIR/bats.log"
if [ -n "${FAKE_SUITE_FAIL:-}" ]; then
    echo "suite failed with token ${REPOWARDEN_IT_GITLAB_TOKEN:-}"
    exit 1
fi
exit 0
BATS

    # gh: simulated login and API
    cat >"$BATS_TEST_TMPDIR/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "gh $*" >>"$BATS_TEST_TMPDIR/gh.log"
case "$*" in
    "auth status"*) exit "${FAKE_GH_AUTH_FAIL:-0}" ;;
    "repo view"*) echo "SimBienvenueHoulBoumi/devzone" ;;
esac
exit 0
GH

    # getent: gitlab.localhost to 127.0.0.1 (relays), host in IPv6 by
    # "hosts" but IPv4 by "ahostsv4" (as Docker Desktop, #320)
    cat >"$BATS_TEST_TMPDIR/bin/getent" <<'GETENT'
#!/usr/bin/env bash
echo "getent $*" >>"$BATS_TEST_TMPDIR/getent.log"
[ -n "${FAKE_GETENT_FAIL:-}" ] && exit 2
case "$*" in
    "hosts gitlab.localhost")
        if [ -n "${FAKE_GETENT_OTHER:-}" ]; then
            echo "172.17.0.1 gitlab.localhost"
        else
            echo "127.0.0.1 gitlab.localhost"
        fi
        ;;
    "ahostsv4 host.docker.internal")
        echo "172.17.0.1 STREAM host.docker.internal"
        ;;
    "hosts host.docker.internal")
        echo "fdc4:f303:9324::254 host.docker.internal"
        ;;
esac
exit 0
GETENT

    chmod +x "$BATS_TEST_TMPDIR"/bin/*
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "test-gitlab : all green, summary, code 0, key removed, token never shown" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"✔ 1. module"* ]] || false
    [[ "$output" == *"✔ 2. state"* ]] || false
    [[ "$output" == *"✔ 3. host name"* ]] || false
    [[ "$output" == *"✔ 4. pipeline"* ]] || false
    [[ "$output" == *"✔ 5. HTTP and SSH clones"* ]] || false
    [[ "$output" == *"✔ 6. platform"* ]] || false
    [[ "$output" == *"✔ 7. repowarden integration"* ]] || false
    [[ "$output" == *"devzone test-gitlab : summary"* ]] || false
    [[ "$output" != *"token-root-secret"* ]] || false
    grep -q "DELETE" "$BATS_TEST_TMPDIR/curl.log" || false
    grep -q "/user/keys/7" "$BATS_TEST_TMPDIR/curl.log" || false
    [ ! -e "$HOME/.local/bin/glab" ]
    ! grep -q '^plateforme=' "$DEVZONE_ETAT" || false
}

@test "test-gitlab : step 1 failed → ✖ with the reason, non-zero code" {
    rm -f "$BATS_TEST_TMPDIR/module_active"
    export FAKE_ENABLE_FAIL=1
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ 1. module"* ]] || false
    [[ "$output" == *"devzone enable gitlab failed"* ]] || false
}

@test "test-gitlab : step 2 failed (runner offline) → ✖ with the reason" {
    export FAKE_RUNNERS='[]'
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ 2. state"* ]] || false
    [[ "$output" == *"runner offline"* ]] || false
}

@test "test-gitlab : step 3 failed (name not resolved) → ✖ with the reason" {
    export FAKE_GETENT_FAIL=1
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ 3. host name"* ]] || false
    [[ "$output" == *"gitlab.localhost not resolved"* ]] || false
}

@test "test-gitlab : step 3 failed (name to another address) → ✖, 127.0.0.1 expected" {
    export FAKE_GETENT_OTHER=1
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ 3. host name"* ]] || false
    [[ "$output" == *"resolves to 172.17.0.1, expected 127.0.0.1"* ]] || false
}

@test "test-gitlab : step 3 failed (relay 2224 stopped) → ✖ with the reason" {
    rm -f "$DEVZONE_RACINE/workspace/.gitlab-ssh/relais.pid"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ 3. host name"* ]] || false
    [[ "$output" == *"gitlab relay stopped on 2224"* ]] || false
}

@test "test-gitlab : step 3 failed (no relay) → ✖ with both ports" {
    rm -f "$DEVZONE_RACINE/workspace/.gitlab-web/relais.pid"
    rm -f "$DEVZONE_RACINE/workspace/.gitlab-ssh/relais.pid"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ 3. host name"* ]] || false
    [[ "$output" == *"gitlab relay stopped on 8929 2224"* ]] || false
}

@test "test-gitlab : step 4, pipeline creation impossible → ✖ with the reason" {
    export FAKE_PIPELINE_CREATE_FAIL=1
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ 4. pipeline"* ]] || false
    [[ "$output" == *"creation of the pipeline"* ]] || false
}

@test "test-gitlab : step 4, pipeline failed → ✖ with the pipeline URL" {
    export FAKE_PIPELINE_STATE=failed
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ 4. pipeline"* ]] || false
    [[ "$output" == *"pipeline failed"* ]] || false
    [[ "$output" == *"/devzone/demo/-/pipelines/42"* ]] || false
}

@test "test-gitlab : step 4, pipeline timeout exceeded → ✖ with the reason" {
    export FAKE_PIPELINE_STATE=running
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ 4. pipeline"* ]] || false
    [[ "$output" == *"timeout 2 s exceeded"* ]] || false
}

@test "test-gitlab : step 4, pipeline running then success" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"✔ 4. pipeline"* ]] || false
}

@test "test-gitlab : step 5, HTTP clone through a credential helper, token absent from the arguments" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q 'credential.helper=!f()' "$BATS_TEST_TMPDIR/git.log" || false
    grep -q 'username=oauth2' "$BATS_TEST_TMPDIR/git.log" || false
    ! grep -q 'token-root-secret' "$BATS_TEST_TMPDIR/git.log" || false
    # The script refuses a clone whose .git/config holds the token: the
    # success of this test also proves that the double did not write it there.
}

@test "test-gitlab : step 5, SSH key upload impossible → ✖ with the reason" {
    export FAKE_KEY_FAIL=1
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ 5. HTTP and SSH clones"* ]] || false
    [[ "$output" == *"SSH key upload"* ]] || false
}

@test "test-gitlab : step 5, SSH clone impossible → ✖ with the reason" {
    export FAKE_CLONE_FAIL=ssh
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ 5. HTTP and SSH clones"* ]] || false
    [[ "$output" == *"SSH clone"* ]] || false
}

@test "test-gitlab : step 5, HTTP clone impossible → ✖, key removed, token absent" {
    export FAKE_CLONE_FAIL=http
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ 5. HTTP and SSH clones"* ]] || false
    [[ "$output" == *"HTTP clone"* ]] || false
    [[ "$output" != *"token-root-secret"* ]] || false
    grep -q "DELETE" "$BATS_TEST_TMPDIR/curl.log" || false
    grep -q "/user/keys/7" "$BATS_TEST_TMPDIR/curl.log" || false
}

@test "test-gitlab : step 5, token written to the clone's .git/config → ✖" {
    export FAKE_TOKEN_IN_CONFIG=1
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ 5. HTTP and SSH clones"* ]] || false
    [[ "$output" == *"written to .git/config"* ]] || false
    [[ "$output" != *"token-root-secret"* ]] || false
}

@test "test-gitlab : step 6, platform change impossible → ✖" {
    export FAKE_PLATFORM_FAIL=1
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ 6. platform"* ]] || false
    [[ "$output" == *"devzone platform gitlab failed"* ]] || false
}

@test "test-gitlab : step 6, glab clone impossible → ✖, previous platform restored" {
    export FAKE_GLAB_CLONE_FAIL=1
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ 6. platform"* ]] || false
    [[ "$output" == *"glab repo clone devzone/demo failed"* ]] || false
    [ ! -e "$HOME/.local/bin/glab" ]
    [ ! -e "$HOME/.config/glab-cli" ]
    ! grep -q '^plateforme=' "$DEVZONE_ETAT" || false
}

@test "test-gitlab : step 7, repowarden clone impossible → ✖" {
    export FAKE_REPOWARDEN_CLONE_FAIL=1
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ 7. repowarden integration"* ]] || false
    [[ "$output" == *"clone of repowarden"* ]] || false
}

@test "test-gitlab : step 7, test/gitlab suite failed → ✖" {
    export FAKE_SUITE_FAIL=1
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ 7. repowarden integration"* ]] || false
    [[ "$output" == *"the test/gitlab suite failed"* ]] || false
}

@test "test-gitlab : step 7, log kept with the token masked" {
    export FAKE_SUITE_FAIL=1
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"devzone-test-gitlab-repowarden.log"* ]] || false
    [ -f "$TMPDIR/devzone-test-gitlab-repowarden.log" ]
    grep -q 'TOKEN_MASKED' "$TMPDIR/devzone-test-gitlab-repowarden.log" || false
    ! grep -q 'token-root-secret' "$TMPDIR/devzone-test-gitlab-repowarden.log" || false
}

@test "test-gitlab : step 7, test/gitlab missing at the ref → skipped, code 0" {
    export FAKE_REPOWARDEN_NO_TEST=1
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"skipped: test/gitlab missing at ref develop"* ]] || false
}

@test "test-gitlab : --complet disables, checks that nothing remains, then reinstalls" {
    run bash "$SCRIPT" --complet
    [ "$status" -eq 0 ]
    [[ "$output" == *"✔ 8. full: disable"* ]] || false
    grep -q "devzone disable gitlab" "$BATS_TEST_TMPDIR/devzone.log" || false
    grep -q "label=devzone.instance=mon-devzone" "$BATS_TEST_TMPDIR/docker.log" || false
    grep -q "kubectl --context devzone get namespace devzone-gitlab-mon-devzone" "$BATS_TEST_TMPDIR/kubectl.log" || false
    [ -f "$BATS_TEST_TMPDIR/module_active" ]
}

@test "test-gitlab : --complet, the namespace stays → ✖ with the reason" {
    export FAKE_DISABLE_LEFT=namespace
    run bash "$SCRIPT" --complet
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ 8. full: disable"* ]] || false
    [[ "$output" == *"namespace devzone-gitlab-mon-devzone"* ]] || false
}

@test "test-gitlab : --complet, a container labelled for the instance stays → ✖" {
    export FAKE_LABELLED_CONTAINERS=abc123
    run bash "$SCRIPT" --complet
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ 8. full: disable"* ]] || false
    [[ "$output" == *"labelled container(s) devzone.instance=mon-devzone"* ]] || false
    grep -q "label=devzone.instance=mon-devzone" "$BATS_TEST_TMPDIR/docker.log" || false
}

@test "test-gitlab : --statut publishes gitlab-integration on HEAD through gh api" {
    run bash "$SCRIPT" --statut
    [ "$status" -eq 0 ]
    grep -q "gh api -X POST repos/SimBienvenueHoulBoumi/devzone/statuses/0123456789abcdef" "$BATS_TEST_TMPDIR/gh.log" || false
    grep -q "context=gitlab-integration" "$BATS_TEST_TMPDIR/gh.log" || false
    grep -q "state=success" "$BATS_TEST_TMPDIR/gh.log" || false
}

@test "test-gitlab : --statut on failure publishes failure, non-zero code" {
    export FAKE_CLONE_FAIL=http
    run bash "$SCRIPT" --statut
    [ "$status" -ne 0 ]
    grep -q "context=gitlab-integration" "$BATS_TEST_TMPDIR/gh.log" || false
    grep -q "state=failure" "$BATS_TEST_TMPDIR/gh.log" || false
}

@test "test-gitlab : --statut without gh logged in → clear refusal, non-zero code" {
    export FAKE_GH_AUTH_FAIL=1
    run bash "$SCRIPT" --statut
    [ "$status" -ne 0 ]
    [[ "$output" == *"gh not logged in"* ]] || false
    ! grep -q "gh api" "$BATS_TEST_TMPDIR/gh.log" || false
}
