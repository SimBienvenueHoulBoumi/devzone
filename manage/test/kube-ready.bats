#!/usr/bin/env bats
# Shared cluster check (#497): kube_ready_reason in manage/scripts/kube-ready.sh.
# Fake kubectl and helm under $BATS_TEST_TMPDIR/bin; PATH holds only those and
# a folder of links to bash and grep (outils_isoles), never /usr/bin or /bin:
# the real kubectl or helm of the machine is not reachable. No real cluster.

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
    *"current-context"*) echo kind-poste ;;
    *"jsonpath"*) echo https://127.0.0.1:6443 ;;
esac
KUBECTL
    cat >"$T/bin/helm" <<'HELM'
#!/usr/bin/env bash
echo "helm $*" >>"$FAKE_LOG"
HELM
    chmod +x "$T/bin/kubectl" "$T/bin/helm"
    outils_isoles "$T/outils"
    export PATH="$T/bin:$T/outils"
    : >"$FAKE_LOG"
    unset FAKE_KUBE_CLUSTER_INFO FAKE_CONTEXTS
}

# Runs kube_ready_reason from the shared file, in a fresh shell.
reason() {
    run bash -c '. "$1"; kube_ready_reason' _ "$KR"
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

@test "cluster unreachable with devzone context: one reason line, status 1" {
    FAKE_KUBE_CLUSTER_INFO=fail
    export FAKE_KUBE_CLUSTER_INFO
    reason
    [ "$status" -eq 1 ]
    [ "$output" = "cluster devzone unreachable (https://127.0.0.1:6443)" ]
}

@test "cluster unreachable without devzone context: current context named" {
    FAKE_KUBE_CLUSTER_INFO=fail
    FAKE_CONTEXTS=""
    export FAKE_KUBE_CLUSTER_INFO FAKE_CONTEXTS
    reason
    [ "$status" -eq 1 ]
    [ "$output" = "cluster kind-poste unreachable (https://127.0.0.1:6443)" ]
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

@test "shared file is sourced by poste.sh: kube_ready_reason defined there" {
    run grep -c 'kube_ready_reason' "$RACINE/manage/scripts/poste.sh"
    [ "$output" -ge 1 ] || false
    ! grep -q '^kube_ready()' "$RACINE/manage/scripts/poste.sh" || false
}
