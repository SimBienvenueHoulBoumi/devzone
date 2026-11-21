#!/usr/bin/env bats
# gitlab module (#239, #273): install, uninstall, status, seed, host
# gitlab.localhost in /etc/hosts (DEVZONE_HOSTS) and startup. Fake kind,
# kubectl, helm, curl, git, docker and gh in the PATH: no cluster is
# created. Each fake binary logs its arguments in
# $BATS_TEST_TMPDIR/<tool>.log.

setup() {
    bats_require_minimum_version 1.5.0
    load commun
    kind_vide
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    GITLAB="$BATS_TEST_DIRNAME/../../.devcontainer/gitlab/gitlab.sh"
    DEMARRAGE="$BATS_TEST_DIRNAME/../../.devcontainer/startup.sh"
    relais_docker_isole
    kube_isole
    export HOME="$BATS_TEST_TMPDIR/home"
    export DEVZONE_RACINE="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_ETAT="$BATS_TEST_TMPDIR/modules"
    export DEVZONE_MEMINFO="$BATS_TEST_TMPDIR/meminfo"
    export DEVZONE_HOSTS="$BATS_TEST_TMPDIR/hosts"
    export KIND_CLUSTERS="$BATS_TEST_TMPDIR/clusters"
    # startup.sh starts the auto port watcher: its folder stays under the test (#394)
    export DEVZONE_PORTS_AUTO_DIR="$BATS_TEST_TMPDIR/ports-auto"
    SECRETS="$DEVZONE_RACINE/workspace/.gitlab"
    mkdir -p "$HOME" "$DEVZONE_RACINE/workspace" "$BATS_TEST_TMPDIR/bin"
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
    # gh: never logged in (git-identity, devzone state): no network call
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

@test "gitlab : disabled by default" {
    run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"○ module gitlab"* ]] || false
    run bash "$DEVZONE" is-enabled gitlab
    [ "$status" -ne 0 ]
}

@test "gitlab : less than 8 GiB of allocatable memory in the cluster → refused, nothing started" {
    FAKE_CLUSTER_MEMORY='4000000Ki' run bash "$GITLAB" install
    [ "$status" -eq 2 ] || false
    [[ "$output" == *"8 GiB"* ]] || false
    [ ! -e "$BATS_TEST_TMPDIR/helm.log" ] || false
    [ ! -e "$BATS_TEST_TMPDIR/kind.log" ] || false
}

@test "gitlab : installation in the services cluster, no kind cluster created" {
    echo "dev" >"$KIND_CLUSTERS"
    run bash "$GITLAB" install
    [ "$status" -eq 0 ] || false
    grep -Eq -- "helm --kubeconfig [^ ]+ upgrade --install gitlab [^ ]*charts/devzone-gitlab --namespace devzone-gitlab" "$BATS_TEST_TMPDIR/helm.log" || false
    ! grep -q "create cluster" "$BATS_TEST_TMPDIR/kind.log" || false
}

@test "gitlab : the kubectl working context is not switched" {
    mkdir -p "$HOME/.kube"
    printf 'current-context: docker-desktop\n' >"$HOME/.kube/config"
    run bash "$GITLAB" install
    [ "$status" -eq 0 ] || false
    ! grep -q "config use-context" "$BATS_TEST_TMPDIR/kubectl.log" || false
    ! grep -q "config unset current-context" "$BATS_TEST_TMPDIR/kubectl.log" || false
    [ "$(sed -n 's/^current-context:[[:space:]]*//p' "$HOME/.kube/config")" = docker-desktop ] || false
}

@test "gitlab : old gitlab cluster already there → no kind created or used" {
    echo "gitlab" >"$KIND_CLUSTERS"
    run bash "$GITLAB" install
    [ "$status" -eq 0 ] || false
    ! grep -q "create cluster" "$BATS_TEST_TMPDIR/kind.log" || false
    grep -Eq -- "helm --kubeconfig [^ ]+ upgrade --install gitlab [^ ]*charts/devzone-gitlab" "$BATS_TEST_TMPDIR/helm.log" || false
}

@test "gitlab : values.yaml configures the SSH clone (port 2224) and ClusterIP services" {
    local values="$BATS_TEST_DIRNAME/../../charts/devzone-gitlab/values.yaml"
    grep -q "port: 2224" "$values" || false
    grep -q "type: ClusterIP" "$values" || false
    grep -q "nginx-ingress:" "$values" || false
    grep -A1 "nginx-ingress:" "$values" | grep -q "enabled: false" || false
}

@test "gitlab : values.yaml pins the HPAs to 1 replica (#490)" {
    local values="$BATS_TEST_DIRNAME/../../charts/devzone-gitlab/values.yaml"
    local name block
    for name in webservice sidekiq gitlab-shell; do
        block="$(awk -v n="$name" '
            $0 == "    " n ":" { inside=1; next }
            inside && /^    [^ ]/ { inside=0 }
            inside { print }
        ' "$values")"
        [[ "$block" == *"minReplicas: 1"* ]] || false
        [[ "$block" == *"maxReplicas: 1"* ]] || false
    done
}

@test "gitlab : kind.yaml and the kind-gitlab cluster are removed" {
    [ ! -e "$BATS_TEST_DIRNAME/../../.devcontainer/gitlab/kind.yaml" ] || false
    ! grep -q "kind create cluster --name gitlab" "$BATS_TEST_DIRNAME/../../.devcontainer/gitlab/installation.sh" || false
}

@test "gitlab : values without NodePort, LoadBalancer or hostPort" {
    local values="$BATS_TEST_DIRNAME/../../charts/devzone-gitlab/values.yaml"
    ! grep -q "NodePort" "$values" || false
    ! grep -q "LoadBalancer" "$values" || false
    ! grep -q "hostPort" "$values" || false
}

@test "gitlab : helm template: ssh_port 2224, no nodePort nor exposed service" {
    if [ -z "${DEVZONE_GITLAB_CHART:-}" ] || ! command -v helm >/dev/null 2>&1; then
        skip "helm unavailable (DEVZONE_GITLAB_CHART or helm)"
    fi
    local helm_bin="${HELM_BIN:-$(command -v helm)}"
    [ -x "$helm_bin" ] || skip "helm unavailable (DEVZONE_GITLAB_CHART or helm)"
    local output_text
    output_text="$("$helm_bin" template gitlab "${DEVZONE_GITLAB_CHART:-/tmp/gl/devzone-gitlab}" 2>&1)"
    [[ "$output_text" == *"ssh_port: 2224"* ]] || false
    [[ "$output_text" != *"nodePort: 32022"* ]] || false
    [[ "$output_text" != *"nodePort: 2224"* ]] || false
    [[ "$output_text" != *"type: NodePort"* ]] || false
}

@test "gitlab : installation without node SSH mapping warning" {
    echo "gitlab" >"$KIND_CLUSTERS"
    run bash "$GITLAB" install
    [ "$status" -eq 0 ] || false
    [[ "$output" != *"SSH clone (port 2224) unavailable"* ]] || false
}

@test "gitlab : old cluster present → no network exposure warning" {
    echo "gitlab" >"$KIND_CLUSTERS"
    run bash "$GITLAB" install
    [ "$status" -eq 0 ] || false
    [[ "$output" != *"exposed to the local network"* ]] || false
}

@test "gitlab : charts pinned, devzone context and instance namespace" {
    run bash "$GITLAB" install
    [ "$status" -eq 0 ]
    grep -Eq -- "helm --kubeconfig [^ ]+ upgrade --install gitlab [^ ]*charts/devzone-gitlab --namespace devzone-gitlab" "$BATS_TEST_TMPDIR/helm.log"
    grep -Eq -- "helm --kubeconfig [^ ]+ upgrade --install gitlab [^ ]*charts/devzone-gitlab .*replicas=1" "$BATS_TEST_TMPDIR/helm.log"
}

@test "gitlab : secrets in workspace/.gitlab (600), never in the repository nor shown" {
    run bash "$GITLAB" install
    [ "$status" -eq 0 ]
    for f in root-password root-token runner-token dev-password; do
        [ -f "$SECRETS/$f" ] || { echo "missing: $f"; false; }
        [ "$(stat -c %a "$SECRETS/$f" 2>/dev/null || stat -f %Lp "$SECRETS/$f")" = 600 ]
    done
    [ "$(cat "$SECRETS/root-password")" = password123 ]
    [ ! -e "$BATS_TEST_DIRNAME/../../.devcontainer/workspace" ]
    [[ "$output" != *"password123"* ]] || false
    [[ "$output" != *"token-root-secret"* ]] || false
    [[ "$output" != *"token-runner-secret"* ]] || false
}

@test "gitlab : seed and uninstall regenerate .password" {
    run bash "$GITLAB" install
    [ "$status" -eq 0 ]
    grep -q $'^gitlab\thttp://gitlab.localhost:8929\tdev\t' "$DEVZONE_RACINE/.password"
    grep -q $'^gitlab\thttp://gitlab.localhost:8929\troot\tpassword123$' "$DEVZONE_RACINE/.password"
    run bash "$GITLAB" uninstall
    [ "$status" -eq 0 ]
    [ ! -e "$DEVZONE_RACINE/.password" ]
}

@test "gitlab : project created with the numeric group ID, push with the root token" {
    run bash "$GITLAB" install
    [ "$status" -eq 0 ]
    grep -q "namespace_id=42" "$BATS_TEST_TMPDIR/curl.log"
    grep -q "oauth2:token-root-secret@127.0.0.1:8929/devzone/demo.git" "$BATS_TEST_TMPDIR/git.log"
    ! grep -q "token-runner-secret@" "$BATS_TEST_TMPDIR/git.log" || false
}

@test "gitlab : installation rerun → demo project not pushed again" {
    run bash "$GITLAB" install
    [ "$status" -eq 0 ]
    [ "$(grep -c " push " "$BATS_TEST_TMPDIR/git.log")" -eq 1 ]
    run bash "$GITLAB" install
    [ "$status" -eq 0 ]
    [ "$(grep -c " push " "$BATS_TEST_TMPDIR/git.log")" -eq 1 ]
}

@test "gitlab : seed failure → installation fails, clear message, no runner" {
    export FAKE_GROUP_FAIL=1
    run bash "$GITLAB" install
    [ "$status" -ne 0 ]
    [[ "$output" == *"devzone group"* ]] || false
    ! grep -q "upgrade --install gitlab-runner" "$BATS_TEST_TMPDIR/helm.log" || false
}

@test "gitlab : seed: runner-token present and verified 200 → token kept, no creation" {
    mkdir -p "$SECRETS"
    printf 'token-runner-secret' >"$SECRETS/runner-token"
    export FAKE_RUNNER_VERIFY_CODE=200
    run bash "$GITLAB" seed
    [ "$status" -eq 0 ]
    [ "$(cat "$SECRETS/runner-token")" = "token-runner-secret" ]
    ! grep -q "api/v4/user/runners" "$BATS_TEST_TMPDIR/curl.log" || false
    [[ "$output" != *"token-runner-secret"* ]] || false
}

@test "gitlab : seed: runner-token present and refused 403 → token recreated, file overwritten" {
    mkdir -p "$SECRETS"
    printf 'old-runner-token' >"$SECRETS/runner-token"
    export FAKE_RUNNER_VERIFY_CODE=403
    run bash "$GITLAB" seed
    [ "$status" -eq 0 ]
    [[ "$output" == *"refused: recreated"* ]] || false
    grep -q "api/v4/user/runners" "$BATS_TEST_TMPDIR/curl.log"
    [ "$(cat "$SECRETS/runner-token")" = "token-runner-secret" ]
}

@test "gitlab : seed: runner-token missing → token created" {
    rm -f "$SECRETS/runner-token"
    run bash "$GITLAB" seed
    [ "$status" -eq 0 ]
    [ -f "$SECRETS/runner-token" ]
    grep -q "api/v4/user/runners" "$BATS_TEST_TMPDIR/curl.log"
}

@test "gitlab : seed: runner token check unreachable → seed stopped" {
    mkdir -p "$SECRETS"
    printf 'token-runner-secret' >"$SECRETS/runner-token"
    export FAKE_RUNNER_UNREACHABLE=1
    run bash "$GITLAB" seed
    [ "$status" -ne 0 ]
    [[ "$output" == *"seed stopped"* ]] || false
}

@test "gitlab : seed: runner token never shown" {
    mkdir -p "$SECRETS"
    printf 'token-runner-secret' >"$SECRETS/runner-token"
    export FAKE_RUNNER_VERIFY_CODE=200
    run bash "$GITLAB" seed
    [ "$status" -eq 0 ]
    [[ "$output" != *"token-runner-secret"* ]] || false
    ! grep -q "token-runner-secret" "$BATS_TEST_TMPDIR/curl.log" || false
}

@test "gitlab : uninstall removes the releases, the namespace and the secrets" {
    run bash "$GITLAB" install
    [ "$status" -eq 0 ]
    run bash "$GITLAB" uninstall
    [ "$status" -eq 0 ]
    grep -Eq -- "helm --kubeconfig [^ ]+ uninstall gitlab --namespace devzone-gitlab" "$BATS_TEST_TMPDIR/helm.log"
    # Namespace deleted by the administrator, not by the limited account (#430)
    grep -q -- "--kubeconfig=.* delete namespace devzone-gitlab --ignore-not-found" "$BATS_TEST_TMPDIR/kubectl.log"
    ! grep -q -- "--context devzone delete namespace devzone-gitlab" "$BATS_TEST_TMPDIR/kubectl.log" || false
    [ -f "$SECRETS/rails-secret.yaml" ]
    [ ! -e "$SECRETS/root-password" ] || false
    [ ! -e "$SECRETS/root-token" ] || false
    [ ! -f "$BATS_TEST_TMPDIR/namespace" ] || false
    [ ! -s "$KIND_CLUSTERS" ] || false
}

@test "gitlab : status disabled, ready (runner online or not), failed" {
    run bash "$GITLAB" status
    [ "$output" = "désactivé" ]
    touch "$BATS_TEST_TMPDIR/namespace"
    mkdir -p "$SECRETS" && echo token >"$SECRETS/root-token"
    run bash "$GITLAB" status
    [ "$output" = "prêt : http://gitlab.localhost:8929, runner hors ligne" ]
    FAKE_RUNNERS='[{"id":1}]' run bash "$GITLAB" status
    [ "$output" = "prêt : http://gitlab.localhost:8929, runner en ligne" ]
    FAKE_GITLAB_FAIL=1 run bash "$GITLAB" status
    [ "$output" = "en échec : devzone apply" ]
}

@test "gitlab : status no longer reports a node published on 0.0.0.0" {
    touch "$BATS_TEST_TMPDIR/namespace"
    FAKE_DOCKER_PORT_EXPOSED=1 run bash "$GITLAB" status
    [ "$status" -eq 0 ]
    [[ "$output" != *"GitLab exposed to the local network"* ]] || false
}

@test "gitlab : status without exposure warning for a local node" {
    touch "$BATS_TEST_TMPDIR/namespace"
    FAKE_DOCKER_PORT_LOCAL=1 run bash "$GITLAB" status
    [ "$status" -eq 0 ]
    [[ "$output" != *"GitLab exposed to the local network"* ]] || false
}

@test "devzone : enabling gitlab skips the installation if ready and runner online" {
    touch "$BATS_TEST_TMPDIR/namespace"
    mkdir -p "$SECRETS" && echo token >"$SECRETS/root-token"
    FAKE_RUNNERS='[{"id":1}]' run bash "$DEVZONE" enable gitlab
    [ "$status" -eq 0 ]
    [[ "$output" == *"already active, nothing to do"* ]] || false
    ! grep -q "upgrade --install" "$BATS_TEST_TMPDIR/helm.log" || false
}

@test "devzone : enable gitlab: ready without runner online → install (seed, runner)" {
    touch "$BATS_TEST_TMPDIR/namespace"
    mkdir -p "$SECRETS" && echo token >"$SECRETS/root-token"
    run bash "$DEVZONE" enable gitlab
    [ "$status" -eq 0 ]
    [[ "$output" != *"already active, nothing to do"* ]] || false
    grep -Eq -- "helm --kubeconfig [^ ]+ upgrade --install gitlab [^ ]*charts/devzone-gitlab --namespace devzone-gitlab" "$BATS_TEST_TMPDIR/helm.log"
}

@test "devzone apply: gitlab active, ready without runner online → install" {
    printf 'gitlab=on\n' >"$DEVZONE_ETAT"
    touch "$BATS_TEST_TMPDIR/namespace"
    mkdir -p "$SECRETS" && echo token >"$SECRETS/root-token"
    run bash "$DEVZONE" apply
    [ "$status" -eq 0 ]
    grep -Eq -- "helm --kubeconfig [^ ]+ upgrade --install gitlab [^ ]*charts/devzone-gitlab --namespace devzone-gitlab" "$BATS_TEST_TMPDIR/helm.log"
}

@test "devzone apply: gitlab active, ready with runner online → no install" {
    printf 'gitlab=on\n' >"$DEVZONE_ETAT"
    touch "$BATS_TEST_TMPDIR/namespace"
    mkdir -p "$SECRETS" && echo token >"$SECRETS/root-token"
    FAKE_RUNNERS='[{"id":1}]' run bash "$DEVZONE" apply
    [ "$status" -eq 0 ]
    [[ "$output" == *"already active, nothing to do"* ]] || false
    [ ! -e "$BATS_TEST_TMPDIR/helm.log" ]
}

@test "devzone apply: gitlab disabled → nothing" {
    printf 'gitlab=off\n' >"$DEVZONE_ETAT"
    run bash "$DEVZONE" apply
    [ "$status" -eq 0 ]
    [ ! -e "$BATS_TEST_TMPDIR/helm.log" ]
    [ ! -e "$BATS_TEST_TMPDIR/kind.log" ]
}

@test "gitlab : hote-poser sets gitlab.localhost once, keeps localhost" {
    run bash "$GITLAB" hote-poser
    [ "$status" -eq 0 ]
    run bash "$GITLAB" hote-poser
    [ "$status" -eq 0 ]
    [ "$(grep -c 'devzone:gitlab' "$DEVZONE_HOSTS")" -eq 1 ]
    grep -q '^127\.0\.0\.1 localhost$' "$DEVZONE_HOSTS"
    grep -q $'^127\.0\.0\.1\tgitlab\.localhost # devzone:gitlab$' "$DEVZONE_HOSTS"
}

@test "gitlab : hote-poser replaces an IPv6 line already set by 127.0.0.1" {
    printf '127.0.0.1 localhost\nfdc4:f303:9324::254\tgitlab.localhost # devzone:gitlab\n' >"$DEVZONE_HOSTS"
    run bash "$GITLAB" hote-poser
    [ "$status" -eq 0 ]
    [ "$(grep -c 'devzone:gitlab' "$DEVZONE_HOSTS")" -eq 1 ]
    grep -q $'^127\.0\.0\.1\tgitlab\.localhost # devzone:gitlab$' "$DEVZONE_HOSTS"
    ! grep -q 'fdc4:f303' "$DEVZONE_HOSTS" || false
    grep -q '^127\.0\.0\.1 localhost$' "$DEVZONE_HOSTS"
}

@test "gitlab : web and SSH relays port-forward to the namespace services" {
    run bash "$GITLAB" relay-start
    [ "$status" -eq 0 ] || false
    grep -q "devzone devzone-gitlab svc/gitlab-webservice-default 8929:8181" "$BATS_TEST_TMPDIR/setsid.log" || false
    grep -q "devzone devzone-gitlab svc/gitlab-gitlab-shell 2224:22" "$BATS_TEST_TMPDIR/setsid.log" || false
    ! grep -q "gitlab-control-plane" "$BATS_TEST_TMPDIR/setsid.log" || false
}

@test "gitlab : relays without kind network nor socat" {
    run bash "$GITLAB" relay-start
    [ "$status" -eq 0 ] || false
    [ ! -e "$BATS_TEST_TMPDIR/docker.log" ] || false
    [ ! -e "$BATS_TEST_TMPDIR/socat.log" ] || false
}

@test "gitlab : old kind target 32022 is no longer used" {
    run bash "$GITLAB" relay-start
    [ "$status" -eq 0 ] || false
    ! grep -q "32022" "$BATS_TEST_TMPDIR/setsid.log" || false
    ! grep -q "TCP-LISTEN" "$BATS_TEST_TMPDIR/setsid.log" || false
}

@test "gitlab : relay-stop stops both relays" {
    mkdir -p "$DEVZONE_RACINE/workspace/.gitlab-web" "$DEVZONE_RACINE/workspace/.gitlab-ssh"
    echo "999999" >"$DEVZONE_RACINE/workspace/.gitlab-web/relais.pid"
    echo "999998" >"$DEVZONE_RACINE/workspace/.gitlab-ssh/relais.pid"
    run bash "$GITLAB" relay-stop
    [ "$status" -eq 0 ] || false
    grep -q "pgrep -P 999999" "$BATS_TEST_TMPDIR/pgrep.log" || false
    grep -q "pgrep -P 999998" "$BATS_TEST_TMPDIR/pgrep.log" || false
    [ ! -e "$DEVZONE_RACINE/workspace/.gitlab-web/relais.pid" ] || false
    [ ! -e "$DEVZONE_RACINE/workspace/.gitlab-ssh/relais.pid" ] || false
}

@test "gitlab : uninstall stops the web and SSH relays" {
    local pid
    { true; } &
    pid=$!
    wait "$pid" || true
    mkdir -p "$DEVZONE_RACINE/workspace/.gitlab-web" "$DEVZONE_RACINE/workspace/.gitlab-ssh"
    echo "$pid" >"$DEVZONE_RACINE/workspace/.gitlab-web/relais.pid"
    echo "$pid" >"$DEVZONE_RACINE/workspace/.gitlab-ssh/relais.pid"
    run bash "$GITLAB" uninstall
    [ "$status" -eq 0 ]
    grep -q "pgrep -P $pid" "$BATS_TEST_TMPDIR/pgrep.log"
    [ ! -e "$DEVZONE_RACINE/workspace/.gitlab-web" ]
    [ ! -e "$DEVZONE_RACINE/workspace/.gitlab-ssh" ]
}

@test "gitlab : hote-retirer removes the line, keeps localhost; without line → nothing, code 0" {
    run bash "$GITLAB" hote-poser
    [ "$status" -eq 0 ]
    run bash "$GITLAB" hote-retirer
    [ "$status" -eq 0 ]
    ! grep -q 'devzone:gitlab' "$DEVZONE_HOSTS" || false
    grep -q '^127\.0\.0\.1 localhost$' "$DEVZONE_HOSTS"
    # No line to remove: file unchanged, code 0
    local before
    before="$(cat "$DEVZONE_HOSTS")"
    run bash "$GITLAB" hote-retirer
    [ "$status" -eq 0 ]
    [ "$(cat "$DEVZONE_HOSTS")" = "$before" ]
}

@test "gitlab : hote-poser without rights nor usable sudo → warning, code 0" {
    chmod 444 "$DEVZONE_HOSTS"
    cat >"$BATS_TEST_TMPDIR/bin/sudo" <<'SUDO'
#!/usr/bin/env bash
echo "sudo $*" >>"$BATS_TEST_TMPDIR/sudo.log"
exit 1
SUDO
    chmod +x "$BATS_TEST_TMPDIR/bin/sudo"
    run bash "$GITLAB" hote-poser
    [ "$status" -eq 0 ]
    [[ "$output" == *"gitlab.localhost name not set"* ]] || false
    ! grep -q 'devzone:gitlab' "$DEVZONE_HOSTS" || false
    # Rerun: same failure, same code 0 (never breaks the installation)
    run bash "$GITLAB" hote-poser
    [ "$status" -eq 0 ]
    [[ "$output" == *"gitlab.localhost name not set"* ]] || false
}

@test "gitlab : install sets the line, uninstall removes it" {
    run bash "$GITLAB" install
    [ "$status" -eq 0 ]
    grep -q 'devzone:gitlab' "$DEVZONE_HOSTS"
    run bash "$GITLAB" uninstall
    [ "$status" -eq 0 ]
    ! grep -q 'devzone:gitlab' "$DEVZONE_HOSTS" || false
    grep -q '^127\.0\.0\.1 localhost$' "$DEVZONE_HOSTS"
}

@test "devzone apply: gitlab active, ready → gitlab.localhost line set" {
    printf 'gitlab=on\n' >"$DEVZONE_ETAT"
    touch "$BATS_TEST_TMPDIR/namespace"
    mkdir -p "$SECRETS" && echo token >"$SECRETS/root-token"
    FAKE_RUNNERS='[{"id":1}]' run bash "$DEVZONE" apply
    [ "$status" -eq 0 ]
    [[ "$output" == *"already active, nothing to do"* ]] || false
    grep -q 'devzone:gitlab' "$DEVZONE_HOSTS"
}

real_mark() {
    stat -c %Y /tmp/devzone-relais-docker.echec 2>/dev/null ||
        stat -f %m /tmp/devzone-relais-docker.echec 2>/dev/null ||
        echo absent
}

@test "startup: gitlab active → line set, inactive → nothing" {
    # Isolation (#346): the Docker relay runs under $BATS_TEST_TMPDIR, the
    # real mark of the workstation is never touched (unchanged, not absent:
    # it may exist if the workstation relay really failed)
    [[ "$DEVZONE_RELAIS_MARQUE" == "$BATS_TEST_TMPDIR"/* ]] || false
    local before
    before="$(real_mark)"
    # Module inactive: nothing is set
    printf 'gitlab=off\n' >"$DEVZONE_ETAT"
    run bash "$DEMARRAGE"
    [ "$status" -eq 0 ]
    ! grep -q 'devzone:gitlab' "$DEVZONE_HOSTS" || false
    # Module active: the name is set at startup
    printf 'gitlab=on\n' >"$DEVZONE_ETAT"
    run bash "$DEMARRAGE"
    [ "$status" -eq 0 ]
    grep -q 'devzone:gitlab' "$DEVZONE_HOSTS"
    grep -q $'^127\.0\.0\.1\tgitlab\.localhost # devzone:gitlab$' "$DEVZONE_HOSTS"
    wait_log "$BATS_TEST_TMPDIR/setsid.log" 'devzone devzone-gitlab svc/gitlab-webservice-default 8929:8181'
    grep -q 'devzone devzone-gitlab svc/gitlab-webservice-default 8929:8181' "$BATS_TEST_TMPDIR/setsid.log"
    wait_log "$BATS_TEST_TMPDIR/setsid.log" 'devzone devzone-gitlab svc/gitlab-gitlab-shell 2224:22'
    grep -q 'devzone devzone-gitlab svc/gitlab-gitlab-shell 2224:22' "$BATS_TEST_TMPDIR/setsid.log"
    # Isolation (#346): the real mark of the workstation is unchanged after the
    # startup (read before the first launch of startup.sh)
    [[ "$DEVZONE_RELAIS_MARQUE" == "$BATS_TEST_TMPDIR"/* ]] || false
    [ "$(real_mark)" = "$before" ]
}

@test "gitlab : values — host without port, external port via GITLAB_PORT" {
    local values="$BATS_TEST_DIRNAME/../../charts/devzone-gitlab/values.yaml"
    grep -Eq 'name: gitlab\.localhost([[:space:]]|$)' "$values"
    grep -q 'GITLAB_PORT: "8929"' "$values"
    ! grep -q "hostnameOverride" "$values" || false
    ! grep -Eq 'gitlab-shell:[[:space:]]*2224' "$values" || false
}

@test "gitlab : helm values — host without port, external port via GITLAB_PORT" {
    [ -n "${DEVZONE_GITLAB_CHART:-}" ] || skip "DEVZONE_GITLAB_CHART missing"
    local helm_bin
    helm_bin="$(PATH=/usr/local/bin:/usr/bin:/bin command -v helm 2>/dev/null || true)"
    [ -n "$helm_bin" ] || skip "helm missing"
    local chart="$DEVZONE_GITLAB_CHART"
    [ -d "$chart" ] || skip "chart missing"
    run "$helm_bin" template gitlab "$chart" --namespace gitlab
    [ "$status" -eq 0 ]
    local rendered="$output"
    printf '%s\n' "$rendered" | grep -qE '^[[:space:]]*host: gitlab\.localhost$' || false
    local webservice
    webservice="$(printf '%s\n' "$rendered" | awk '
        /^kind: Deployment$/ { inside = 1; name = 0; block = "" }
        inside { block = block $0 "\n" }
        inside && /^  name: gitlab-webservice-default$/ { name = 1 }
        inside && /^---$/ { if (name) printf "%s", block; inside = 0; name = 0 }
        END { if (inside && name) printf "%s", block }
    ')"
    [[ "$webservice" == *"name: GITLAB_PORT"* ]] || false
    [[ "$webservice" == *'value: "8929"'* ]] || false
    ! printf '%s\n' "$rendered" | grep -q "nodePort: 2224" || false
}

# ---- Former French names (#557): same result as the English name, with a warning ----

@test "gitlab : English names give no warning" {
    mkdir -p "$SECRETS"
    printf '{}\n' >"$SECRETS/rails-secret.yaml"
    run --separate-stderr bash "$GITLAB" status
    [ "$status" -eq 0 ] || false
    [[ "$stderr" != *"deprecated"* ]] || false
    run --separate-stderr bash "$GITLAB" relay-start
    [ "$status" -eq 0 ] || false
    [[ "$stderr" != *"deprecated"* ]] || false
    run --separate-stderr bash "$GITLAB" uninstall --yes
    [ "$status" -eq 0 ] || false
    [[ "$stderr" != *"deprecated"* ]] || false
}
