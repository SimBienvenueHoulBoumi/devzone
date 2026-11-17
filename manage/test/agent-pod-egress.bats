#!/usr/bin/env bats
# devzone agent --pod: egress proxy for session pods (#220).
# Fake kubectl only, test root under BATS_TEST_TMPDIR: no cluster, no /workspaces.

load commun
load agent-pod-racine

setup() {
    load commun
    agent_isole
    racine_test
    unset DEVZONE_WORKSPACE
    export DEVZONE_WORKSPACE=kubernetes
    export DEVZONE_AGENT_POD_TIMEOUT=1
    export DEVZONE_AGENT_POD_MODULES_FILE="$BATS_TEST_TMPDIR/modules"; : >"$DEVZONE_AGENT_POD_MODULES_FILE"
    T="$BATS_TEST_TMPDIR"
    mkdir -p "$T/bin"
    : >"$T/kubectl.log"
    export FAKE_EGRESS_MODE=""

    cat >"$T/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"${BATS_TEST_TMPDIR:-/tmp}/kubectl.log"
case "$*" in
    *"get service -l app.kubernetes.io/component=egress-proxy"*)
        if printf '%s' "$*" | grep -q 'egress-mode'; then
            printf '%s' "${FAKE_EGRESS_MODE:-}"
        fi ;;
    *"get pod devzone-workspace-0 -o jsonpath="*)
        if printf '%s' "$*" | grep -q '\.image}'; then
            echo "ghcr.io/test/workspace:1.0"
        elif printf '%s' "$*" | grep -q 'PATH'; then
            echo "/usr/bin:/bin"
        elif printf '%s' "$*" | grep -q 'name=="workspace"'; then
            echo "workspace-devzone-workspace-0"
        elif printf '%s' "$*" | grep -q 'name=="etat"'; then
            echo "etat-devzone-workspace-0"
        fi ;;
esac
exit 0
KUBE
    chmod +x "$T/bin/kubectl"
    export PATH="$T/bin:$PATH"
    printf 'build the feature\n' >"$T/consigne.txt"
    FOLDER="$(faux_worktree devzone dz-220)"
    export FOLDER
}

source_agent_pod() {
    source "$BATS_TEST_DIRNAME/../../.devcontainer/agent-pod.sh"
}

@test "agent-pod-egress : no proxy means manifest unchanged (no proxy env, no initContainers)" {
    source_agent_pod
    agent_pod_validate_folder "$FOLDER" >/dev/null
    manifest="$(agent_pod_build_manifest "$FOLDER" "$T/consigne.txt" "agent-dz-220-test")"
    if grep -q "HTTP_PROXY" "$manifest"; then false; fi
    if grep -q "HTTPS_PROXY" "$manifest"; then false; fi
    if grep -q "NO_PROXY" "$manifest"; then false; fi
    if grep -q "initContainers" "$manifest"; then false; fi
    if grep -q "wait-egress-restriction" "$manifest"; then false; fi
    rm -f "$manifest"
}

@test "agent-pod-egress : observation adds proxy env without guard initContainer" {
    export FAKE_EGRESS_MODE=observation
    source_agent_pod
    agent_pod_validate_folder "$FOLDER" >/dev/null
    manifest="$(agent_pod_build_manifest "$FOLDER" "$T/consigne.txt" "agent-dz-220-test")"
    grep -A1 "name: HTTP_PROXY" "$manifest" | grep -q 'value: "http://egress-proxy:3128"' || false
    grep -A1 "name: HTTPS_PROXY" "$manifest" | grep -q 'value: "http://egress-proxy:3128"' || false
    grep -A1 "name: NO_PROXY" "$manifest" | grep -q 'value: "localhost,127.0.0.1,.svc,.cluster.local"' || false
    if grep -q "wait-egress-restriction" "$manifest"; then false; fi
    if grep -q "initContainers" "$manifest"; then false; fi
    rm -f "$manifest"
}

@test "agent-pod-egress : strict adds proxy env and guard initContainer" {
    export FAKE_EGRESS_MODE=strict
    source_agent_pod
    agent_pod_validate_folder "$FOLDER" >/dev/null
    manifest="$(agent_pod_build_manifest "$FOLDER" "$T/consigne.txt" "agent-dz-220-test")"
    grep -A1 "name: HTTP_PROXY" "$manifest" | grep -q 'value: "http://egress-proxy:3128"' || false
    grep -A1 "name: HTTPS_PROXY" "$manifest" | grep -q 'value: "http://egress-proxy:3128"' || false
    grep -A1 "name: NO_PROXY" "$manifest" | grep -q 'value: "localhost,127.0.0.1,.svc,.cluster.local"' || false
    grep -q "initContainers" "$manifest" || false
    grep -q "name: wait-egress-restriction" "$manifest" || false
    rm -f "$manifest"
}

@test "agent-pod-egress : guard command checks direct access and fails closed" {
    export FAKE_EGRESS_MODE=strict
    source_agent_pod
    agent_pod_validate_folder "$FOLDER" >/dev/null
    manifest="$(agent_pod_build_manifest "$FOLDER" "$T/consigne.txt" "agent-dz-220-test")"
    grep -q 'curl --noproxy "\*" -m 3' "$manifest" || false
    grep -q 'https://opencode.ai' "$manifest" || false
    grep -q 'egress restriction never became effective: session refused' "$manifest" || false
    grep -q 'exit 1' "$manifest" || false
    rm -f "$manifest"
}

@test "agent-pod-egress : detects proxy by listing services with label, not get" {
    export FAKE_EGRESS_MODE=observation
    source_agent_pod
    agent_pod_validate_folder "$FOLDER" >/dev/null
    manifest="$(agent_pod_build_manifest "$FOLDER" "$T/consigne.txt" "agent-dz-220-test")"
    grep -q "get service -l app.kubernetes.io/component=egress-proxy" "$T/kubectl.log" || false
    if grep -q "get service egress-proxy" "$T/kubectl.log"; then false; fi
    rm -f "$manifest"
}
