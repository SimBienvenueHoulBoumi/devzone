#!/usr/bin/env bats
# Shared cluster check (#497, #565): kube_ready_reason in manage/scripts/kube-ready.sh.
# Fake kubectl, helm and docker under $BATS_TEST_TMPDIR/bin; PATH holds only those and
# a folder of links to bash and grep (outils_isoles), never /usr/bin or /bin:
# the real kubectl, helm or Docker of the machine is not reachable. No real cluster.

setup() {
    load commun
    kube_isole
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    KR="$RACINE/manage/scripts/kube-ready.sh"
    T="$BATS_TEST_TMPDIR"
    FAKE_LOG="$T/tools.log"
    export FAKE_LOG
    mkdir -p "$T/bin"
    cat >"$T/bin/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
echo "kubectl $*" >>"$FAKE_LOG"
case "$*" in
    *"get-contexts"*) [ "${FAKE_CONTEXTS-devzone}" = devzone ] && echo devzone ;;
    *"cluster-info"*) [ "${FAKE_KUBE_CLUSTER_INFO:-ok}" = ok ] ;;
    *"current-context"*) echo "${FAKE_CURRENT-kind-poste}" ;;
    *"clusters[0].name"*) echo "${FAKE_CLUSTER-kind-poste}" ;;
    *"clusters[0].cluster.server"*) echo "${FAKE_SERVER-https://127.0.0.1:6443}" ;;
esac
KUBECTL
    cat >"$T/bin/helm" <<'HELM'
#!/usr/bin/env bash
echo "helm $*" >>"$FAKE_LOG"
HELM
    cat >"$T/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
echo "docker $*" >>"$FAKE_LOG"
[ "${FAKE_DOCKER:-up}" = up ]
DOCKER
    chmod +x "$T/bin/kubectl" "$T/bin/helm" "$T/bin/docker"
    outils_isoles "$T/outils"
    export PATH="$T/bin:$T/outils"
    : >"$FAKE_LOG"
    unset FAKE_KUBE_CLUSTER_INFO FAKE_CONTEXTS FAKE_CURRENT FAKE_CLUSTER FAKE_SERVER FAKE_DOCKER
}

# Runs kube_ready_reason from the shared file, in a fresh shell.
reason() {
    run bash -c '. "$1"; kube_ready_reason' _ "$KR"
}

# Same with --hint: the messages of the user (#565).
hint() {
    run bash -c '. "$1"; kube_ready_reason --hint' _ "$KR"
}

@test "cluster ready with devzone context: status 0, nothing printed" {
    reason
    [ "$status" -eq 0 ]
    [ -z "$output" ] || false
    [[ "$(cat "$FAKE_LOG")" == *"cluster-info --request-timeout=5s --context devzone"* ]] || false
}

@test "no devzone context: cluster-info on the current context, status 0" {
    FAKE_CONTEXTS=""
    export FAKE_CONTEXTS
    reason
    [ "$status" -eq 0 ]
    [[ "$(cat "$FAKE_LOG")" == *"kubectl cluster-info --request-timeout=5s"* ]] || false
    [[ "$(cat "$FAKE_LOG")" != *"--context devzone"* ]] || false
}

@test "kubectl missing: reason kubectl missing, status 1" {
    run env PATH="$T/outils" bash -c '. "$1"; kube_ready_reason' _ "$KR"
    [ "$status" -eq 1 ]
    [ "$output" = "kubectl missing" ]
}

@test "helm missing: reason helm missing, status 1, cluster not asked" {
    rm "$T/bin/helm"
    reason
    [ "$status" -eq 1 ]
    [ "$output" = "helm missing" ]
    [[ "$(cat "$FAKE_LOG")" != *"cluster-info"* ]] || false
}

@test "default output: one short line, Docker not asked (create-mode contract)" {
    FAKE_KUBE_CLUSTER_INFO=fail FAKE_CLUSTER=docker-desktop FAKE_DOCKER=down
    export FAKE_KUBE_CLUSTER_INFO FAKE_CLUSTER FAKE_DOCKER
    reason
    [ "$status" -eq 1 ]
    [ "$output" = "cluster devzone unreachable (https://127.0.0.1:6443)" ]
    [[ "$(cat "$FAKE_LOG")" != *"docker info"* ]] || false
}

@test "hint: kubectl missing as a ✖ line" {
    run env PATH="$T/outils" bash -c '. "$1"; kube_ready_reason --hint' _ "$KR"
    [ "$status" -eq 1 ]
    [ "$output" = "✖ kubectl missing" ]
}

@test "Docker Desktop stopped (cluster docker-desktop, docker info fails): one ✖ line and the tip" {
    FAKE_KUBE_CLUSTER_INFO=fail FAKE_CLUSTER=docker-desktop FAKE_DOCKER=down
    export FAKE_KUBE_CLUSTER_INFO FAKE_CLUSTER FAKE_DOCKER
    hint
    [ "$status" -eq 1 ]
    [[ "$output" == *"✖ Docker Desktop is stopped: the Kubernetes cluster of this machine runs inside it. Start Docker Desktop, then: devzone workspace start"* ]] || false
    [[ "$output" == *"Settings → General → Start Docker Desktop when you sign in"* ]] || false
    [ "$(grep -c '^✖' <<<"$output")" -eq 1 ]
    grep -q '^docker info' "$FAKE_LOG" || false
}

@test "Docker Desktop stopped with context docker-desktop: same message" {
    FAKE_KUBE_CLUSTER_INFO=fail FAKE_CONTEXTS="" FAKE_CURRENT=docker-desktop FAKE_DOCKER=down
    export FAKE_KUBE_CLUSTER_INFO FAKE_CONTEXTS FAKE_CURRENT FAKE_DOCKER
    hint
    [ "$status" -eq 1 ]
    [[ "$output" == *"✖ Docker Desktop is stopped"* ]] || false
}

@test "Docker answers, Kubernetes off in Docker Desktop: enable it in Docker Desktop" {
    FAKE_KUBE_CLUSTER_INFO=fail FAKE_CLUSTER=docker-desktop FAKE_DOCKER=up
    export FAKE_KUBE_CLUSTER_INFO FAKE_CLUSTER FAKE_DOCKER
    hint
    [ "$status" -eq 1 ]
    [ "$output" = "✖ Kubernetes cluster devzone unreachable (https://127.0.0.1:6443): enable Kubernetes in Docker Desktop (Settings → Kubernetes) or check kubectl config get-contexts" ]
}

@test "Docker Desktop cluster on a remote server: generic message, Docker not asked" {
    FAKE_KUBE_CLUSTER_INFO=fail FAKE_CLUSTER=docker-desktop FAKE_SERVER=https://10.0.0.5:6443 FAKE_DOCKER=down
    export FAKE_KUBE_CLUSTER_INFO FAKE_CLUSTER FAKE_SERVER FAKE_DOCKER
    hint
    [ "$status" -eq 1 ]
    [ "$output" = "$(printf '✖ Kubernetes cluster devzone unreachable (https://10.0.0.5:6443)\n  Check the contexts: kubectl config get-contexts')" ]
    [[ "$(cat "$FAKE_LOG")" != *"docker info"* ]] || false
}

@test "other cluster unreachable with devzone context: generic message and check command" {
    FAKE_KUBE_CLUSTER_INFO=fail FAKE_CLUSTER=kind-gitlab FAKE_DOCKER=down
    export FAKE_KUBE_CLUSTER_INFO FAKE_CLUSTER FAKE_DOCKER
    hint
    [ "$status" -eq 1 ]
    [ "$output" = "$(printf '✖ Kubernetes cluster devzone unreachable (https://127.0.0.1:6443)\n  Check the contexts: kubectl config get-contexts')" ]
    [[ "$output" != *"Docker"* ]] || false
}

@test "cluster unreachable without devzone context: current context named" {
    FAKE_KUBE_CLUSTER_INFO=fail FAKE_CONTEXTS=""
    export FAKE_KUBE_CLUSTER_INFO FAKE_CONTEXTS
    reason
    [ "$status" -eq 1 ]
    [ "$output" = "cluster kind-poste unreachable (https://127.0.0.1:6443)" ]
}

