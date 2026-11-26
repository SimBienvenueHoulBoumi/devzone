#!/usr/bin/env bats
# gitlab module (#239, #273): install, uninstall, status, seed, host
# gitlab.localhost in /etc/hosts (DEVZONE_HOSTS) and module activation. Fake kind,
# kubectl, helm, curl, git, docker and gh in the PATH: no cluster is
# created. Each fake binary logs its arguments in
# $BATS_TEST_TMPDIR/<tool>.log.

# Fake devzone: the gitlab module is Go (#866), only its calls are logged.
# Ready once the namespace exists; runner online when FAKE_RUNNERS is set.
fake_devzone_gitlab() {
    cat >"$BATS_TEST_TMPDIR/bin/devzone" <<'FAKE'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
printf 'devzone %s\n' "$*" >>"$T/devzone.log"
case "$*" in
    "gitlab status")
        if [ ! -f "$T/namespace" ]; then
            echo "disabled"
        elif [ -n "${FAKE_RUNNERS:-}" ]; then
            echo "ready, runner online"
        else
            echo "ready, no runner"
        fi
        ;;
    "gitlab installe") [ -f "$T/namespace" ] ;;
    "gitlab hote-poser") echo "127.0.0.1 gitlab.localhost # devzone:gitlab" >>"$DEVZONE_HOSTS" ;;
esac
FAKE
    chmod +x "$BATS_TEST_TMPDIR/bin/devzone"
}

setup() {
    bats_require_minimum_version 1.5.0
    load commun
    kind_vide
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    GITLAB="$BATS_TEST_DIRNAME/../../.devcontainer/gitlab/gitlab.sh"
    kube_isole
    export HOME="$BATS_TEST_TMPDIR/home"
    export DEVZONE_ROOT="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_STATE="$BATS_TEST_TMPDIR/modules"
    export DEVZONE_MEMINFO="$BATS_TEST_TMPDIR/meminfo"
    export DEVZONE_HOSTS="$BATS_TEST_TMPDIR/hosts"
    export KIND_CLUSTERS="$BATS_TEST_TMPDIR/clusters"
    SECRETS="$DEVZONE_ROOT/workspace/.gitlab"
    mkdir -p "$HOME" "$DEVZONE_ROOT/workspace" "$BATS_TEST_TMPDIR/bin"
    printf 'MemAvailable: 16000000 kB\n' >"$DEVZONE_MEMINFO"
    : >"$KIND_CLUSTERS"
    printf '127.0.0.1 localhost\n' >"$DEVZONE_HOSTS"

    # kind: clusters held in $KIND_CLUSTERS
    cat >"$BATS_TEST_TMPDIR/bin/kind" <<'KIND'
#!/usr/bin/env bash
echo "kind $*" >>"$BATS_TEST_TMPDIR/kind.log"
case "$1 $2" in
    "get clusters") cat "$KIND_CLUSTERS" ;;
    "create cluster") echo "${4:-}" >>"$KIND_CLUSTERS" ;;
    "delete cluster") grep -vx "${4:-}" "$KIND_CLUSTERS" >"$KIND_CLUSTERS.tmp" || true; mv "$KIND_CLUSTERS.tmp" "$KIND_CLUSTERS" ;;
esac
KIND
    # kubectl: allocatable memory of the nodes (FAKE_CLUSTER_MEMORY), devzone-gitlab
    # namespace present after creation, root secret "password123"
    # (base64), toolbox pod and root token
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"$BATS_TEST_TMPDIR/kubectl.log"
T="$BATS_TEST_TMPDIR"
case "$*" in
    *"config current-context"*) echo "${FAKE_CONTEXT:-}" ;;
    *"get nodes -o jsonpath"*) printf '%s\n' "${FAKE_CLUSTER_MEMORY:-16777216Ki}" ;;
    *"create namespace"*) printf 'kind: Namespace\nmetadata:\n  name: devzone-gitlab\n' ;;
    *"apply -f -"*) tee -a "$T/apply.log" ;;
    *"label namespace "*) touch "$T/namespace" ;;
    *"get namespace "*) [ -f "$T/namespace" ] && exit 0 ; exit 1 ;;
    *"delete namespace "*) rm -f "$T/namespace" ;;
    *"get secret "*"gitlab-rails-secret"*)
        cat <<'SECRET'
{
  "apiVersion": "v1",
  "data": {"secrets.yml": "c2VjcmV0czoK"},
  "kind": "Secret",
  "metadata": {
    "name": "gitlab-rails-secret",
    "namespace": "devzone-gitlab",
    "resourceVersion": "123",
    "uid": "abc"
  },
  "type": "Opaque"
}
SECRET
        ;;
    *"get secret"*) echo "cGFzc3dvcmQxMjM=" ;;
    *"get pod"*) echo "gitlab-toolbox-1" ;;
    *"gitlab-rails runner"*) echo "token-root-secret" ;;
esac
exit 0
KUBE
    # helm: logs the calls and the content of the values files
    cat >"$BATS_TEST_TMPDIR/bin/helm" <<'HELM'
#!/usr/bin/env bash
echo "helm $*" >>"$BATS_TEST_TMPDIR/helm.log"
precedent=""
for a in "$@"; do
    if [ "$precedent" = -f ] && [ -f "$a" ]; then
        cat "$a" >>"$BATS_TEST_TMPDIR/helm.log"
    fi
    precedent="$a"
done
exit 0
HELM
    # docker: network connect (kind network), SSH mapping of the kind cluster
    # (nodePort 32022) and node publications (docker port without port).
    # FAKE_DOCKER_NETWORK_FAIL: connect fails; FAKE_DOCKER_NETWORK_EXISTS:
    # "already exists" (success); FAKE_DOCKER_PORT: SSH mapping present;
    # FAKE_DOCKER_PORT_EXPOSED / _LOCAL: node published on 0.0.0.0 / 127.0.0.1.
    cat >"$BATS_TEST_TMPDIR/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
echo "docker $*" >>"$BATS_TEST_TMPDIR/docker.log"
case "$*" in
    *"network connect kind "*)
        if [ -n "${FAKE_DOCKER_NETWORK_EXISTS:-}" ]; then
            echo "Error response from daemon: endpoint with name $(hostname) already exists in network kind"
            exit 1
        fi
        if [ -n "${FAKE_DOCKER_NETWORK_FAIL:-}" ]; then
            echo "Error response from daemon: network kind not found"
            exit 1
        fi
        exit 0
        ;;
    *"port gitlab-control-plane 32022"*)
        if [ -n "${FAKE_DOCKER_PORT:-}" ]; then
            echo "0.0.0.0:2224 -> 32022/tcp"
            exit 0
        fi
        exit 1
        ;;
    *"port gitlab"*"control-plane"*)
        if [ -n "${FAKE_DOCKER_PORT_EXPOSED:-}" ]; then
            printf '80/tcp -> 0.0.0.0:8929\n32022/tcp -> 0.0.0.0:2224\n'
        elif [ -n "${FAKE_DOCKER_PORT_LOCAL:-}" ]; then
            printf '80/tcp -> 127.0.0.1:8929\n32022/tcp -> 127.0.0.1:2224\n'
        fi
        exit 0
        ;;
esac
exit 0
DOCKER
    # curl: simulated GitLab API; FAKE_GROUP_FAIL=1 makes the group fail;
    # FAKE_RUNNER_VERIFY_CODE: HTTP code returned for /api/v4/runners/verify;
    # FAKE_RUNNER_UNREACHABLE: the token check is unreachable (exit 7)
    cat >"$BATS_TEST_TMPDIR/bin/curl" <<'CURL'
#!/usr/bin/env bash
echo "curl $*" | sed -e 's/token=[^ &]*/token=<masked>/g' -e 's/PRIVATE-TOKEN: [^ "]*/PRIVATE-TOKEN: <masked>/g' >>"$BATS_TEST_TMPDIR/curl.log"
[ -n "${FAKE_GITLAB_FAIL:-}" ] && exit 7
case "$*" in
    *"api/v4/runners/verify"*)
        if [ -n "${FAKE_RUNNER_UNREACHABLE:-}" ]; then
            exit 7
        fi
        echo "${FAKE_RUNNER_VERIFY_CODE:-200}"
        ;;
    *"api/v4/groups/devzone"*)
        [ -n "${FAKE_GROUP_FAIL:-}" ] && exit 22
        echo '{"id":42}' ;;
    *"--request POST"*"api/v4/groups"*) [ -n "${FAKE_GROUP_FAIL:-}" ] && exit 22 ;;
    *"--request POST"*"api/v4/user/runners"*) echo '{"token":"token-runner-secret"}' ;;
    # main branch: absent until the fake git has pushed
    *"api/v4/projects/devzone%2Fdemo/repository"*) [ -f "$BATS_TEST_TMPDIR/pushed" ] || exit 22 ;;
    *"--request POST"*) ;;
    *"api/v4/projects/devzone%2Fdemo"*) exit 22 ;;
    *"api/v4/users?username=dev"*) echo '[]' ;;
    *"api/v4/runners/all"*) echo "${FAKE_RUNNERS:-[]}" ;;
esac
exit 0
CURL
    cat >"$BATS_TEST_TMPDIR/bin/git" <<'GIT'
#!/usr/bin/env bash
echo "git $*" >>"$BATS_TEST_TMPDIR/git.log"
case "$*" in *" push "*) touch "$BATS_TEST_TMPDIR/pushed" ;; esac
GIT
    # npm: nothing installed globally (devzone apply checks repowarden)
    cat >"$BATS_TEST_TMPDIR/bin/npm" <<'NPM'
#!/usr/bin/env bash
if [ "${1:-}" = ls ]; then printf '{"dependencies":{}}\n'; fi
NPM
    # gh: never logged in: no network call
    cat >"$BATS_TEST_TMPDIR/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "gh $*" >>"$BATS_TEST_TMPDIR/gh.log"
exit 1
GH
    # getent: hosts gives the IPv6 of Docker Desktop, ahostsv4 the IPv4 of the host
    cat >"$BATS_TEST_TMPDIR/bin/getent" <<'GETENT'
#!/usr/bin/env bash
echo "getent $*" >>"$BATS_TEST_TMPDIR/getent.log"
case "$*" in
    "hosts host.docker.internal") echo "fdc4:f303:9324::254 host.docker.internal" ;;
    "ahostsv4 host.docker.internal") echo "192.168.65.254 STREAM host.docker.internal" ;;
    "hosts gitlab.localhost") echo "127.0.0.1 gitlab.localhost" ;;
esac
exit 0
GETENT
    # socat/setsid: logged TCP relay, without a real process
    cat >"$BATS_TEST_TMPDIR/bin/socat" <<'SOCAT'
#!/usr/bin/env bash
echo "socat $*" >>"$BATS_TEST_TMPDIR/socat.log"
exit 0
SOCAT
    # setsid: logs the port-forward relay without starting a real process
    cat >"$BATS_TEST_TMPDIR/bin/setsid" <<'SETSID'
#!/usr/bin/env bash
echo "setsid $*" >>"$BATS_TEST_TMPDIR/setsid.log"
exit 0
SETSID
    # kill: -0 keeps the test alive, the other signals are only logged
    cat >"$BATS_TEST_TMPDIR/bin/kill" <<'KILL'
#!/usr/bin/env bash
if [ "${1:-}" = "-0" ]; then
    builtin kill -0 "${2:-}" 2>/dev/null
    exit $?
fi
echo "kill $*" >>"$BATS_TEST_TMPDIR/kill.log"
exit 0
KILL
    cat >"$BATS_TEST_TMPDIR/bin/pgrep" <<'PGREP'
#!/usr/bin/env bash
echo "pgrep $*" >>"$BATS_TEST_TMPDIR/pgrep.log"
exit 1
PGREP
    chmod +x "$BATS_TEST_TMPDIR"/bin/*
    HELM_BIN="$(command -v helm)"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    fake_devzone_gitlab
}

wait_log() {
    local file="$1" pattern="$2" i=0
    while [ "$i" -lt 50 ]; do
        if grep -q -- "$pattern" "$file" 2>/dev/null; then
            return 0
        fi
        i=$((i + 1))
        sleep 0.1
    done
    echo "$file : line missing after 5 s : $pattern" >&2
    return 1
}

@test "devzone : enabling gitlab skips the installation if ready and runner online" {
    touch "$BATS_TEST_TMPDIR/namespace"
    mkdir -p "$SECRETS" && echo token >"$SECRETS/root-token"
    FAKE_RUNNERS='[{"id":1}]' run bash "$DEVZONE" enable gitlab
    [ "$status" -eq 0 ]
    [[ "$output" == *"already active, nothing to do"* ]] || false
    ! grep -qx "devzone gitlab install" "$BATS_TEST_TMPDIR/devzone.log" || false
}

@test "devzone : enable gitlab: ready without runner online → install (seed, runner)" {
    touch "$BATS_TEST_TMPDIR/namespace"
    mkdir -p "$SECRETS" && echo token >"$SECRETS/root-token"
    run bash "$DEVZONE" enable gitlab
    [ "$status" -eq 0 ]
    [[ "$output" != *"already active, nothing to do"* ]] || false
    grep -qx "devzone gitlab install" "$BATS_TEST_TMPDIR/devzone.log"
}

@test "devzone apply: gitlab active, ready without runner online → install" {
    printf 'gitlab=on\n' >"$DEVZONE_STATE"
    touch "$BATS_TEST_TMPDIR/namespace"
    mkdir -p "$SECRETS" && echo token >"$SECRETS/root-token"
    run bash "$DEVZONE" apply
    [ "$status" -eq 0 ]
    grep -qx "devzone gitlab install" "$BATS_TEST_TMPDIR/devzone.log"
}

@test "devzone apply: gitlab active, ready with runner online → no install" {
    printf 'gitlab=on\n' >"$DEVZONE_STATE"
    touch "$BATS_TEST_TMPDIR/namespace"
    mkdir -p "$SECRETS" && echo token >"$SECRETS/root-token"
    FAKE_RUNNERS='[{"id":1}]' run bash "$DEVZONE" apply
    [ "$status" -eq 0 ]
    [[ "$output" == *"already active, nothing to do"* ]] || false
    ! grep -qx "devzone gitlab install" "$BATS_TEST_TMPDIR/devzone.log" || false
}

@test "devzone apply: gitlab disabled → nothing" {
    printf 'gitlab=off\n' >"$DEVZONE_STATE"
    run bash "$DEVZONE" apply
    [ "$status" -eq 0 ]
    [ ! -e "$BATS_TEST_TMPDIR/helm.log" ]
    [ ! -e "$BATS_TEST_TMPDIR/kind.log" ]
}

@test "devzone apply: gitlab active, ready → gitlab.localhost line set" {
    printf 'gitlab=on\n' >"$DEVZONE_STATE"
    touch "$BATS_TEST_TMPDIR/namespace"
    mkdir -p "$SECRETS" && echo token >"$SECRETS/root-token"
    FAKE_RUNNERS='[{"id":1}]' run bash "$DEVZONE" apply
    [ "$status" -eq 0 ]
    [[ "$output" == *"already active, nothing to do"* ]] || false
    grep -q 'devzone:gitlab' "$DEVZONE_HOSTS"
}

