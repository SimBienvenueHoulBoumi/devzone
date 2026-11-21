#!/usr/bin/env bats
# devzone agent --pod: one ephemeral pod per agent session (#222).
# Tests use a fake kubectl and a test projects root (DEVZONE_ROOT under
# BATS_TEST_TMPDIR): no real cluster is touched, /workspaces is never used.

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
    export FAKE_CREATE_FAIL=0
    export FAKE_PHASE=Succeeded

    cat >"$T/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"${BATS_TEST_TMPDIR:-/tmp}/kubectl.log"
case "$*" in
    "config get-contexts -o name") exit 0 ;;
    *"create configmap"*) exit 0 ;;
    *"create -f"*)
        [ "${FAKE_CREATE_FAIL:-0}" = "1" ] && exit 1
        exit 0 ;;
    *"get pod devzone-workspace-0 -o jsonpath="*)
        if printf '%s' "$*" | grep -q '\.image}'; then
            echo "ghcr.io/test/workspace:1.0"
        elif printf '%s' "$*" | grep -q 'PATH'; then
            echo "/test/path:/usr/bin:/bin"
        elif printf '%s' "$*" | grep -q 'name=="workspace"'; then
            echo "workspace-devzone-workspace-0"
        elif printf '%s' "$*" | grep -q 'name=="etat"'; then
            echo "etat-devzone-workspace-0"
        fi ;;
    *"{.status.phase}"*) echo "${FAKE_PHASE:-Succeeded}" ;;
    "logs "*) echo "=== logs of the session in the pod ====" ;;
    "delete pod "*) exit 0 ;;
    "delete configmap "*) exit 0 ;;
    "get pods"*)
        if printf '%s' "$*" | grep -q "devzone.io/agent-session"; then
            printf '{"items":[{"metadata":{"name":"agent-dz-222-folder-1"},"spec":{"containers":[{"resources":{"limits":{"cpu":"2","memory":"4Gi"}}}]}}]}'
        else
            printf '{"items":[]}'
        fi ;;
esac
exit 0
KUBE
    chmod +x "$T/bin/kubectl"

    printf 'build the feature\n' >"$T/consigne.txt"

    FOLDER="$(faux_worktree devzone dz-222)"
    export FOLDER
}

source_agent_pod() {
    source "$BATS_TEST_DIRNAME/../../.devcontainer/agent-pod.sh"
}

@test "agent-pod : folder under the projects root with .git is valid" {
    source_agent_pod
    agent_pod_validate_folder "$FOLDER"
    [ "$?" -eq 0 ]
    [ "$AGENT_POD_WORKTREE_SUBPATH" = "devzone-wt/dz-222" ]
    [ "$AGENT_POD_WORKTREE_MOUNTPATH" = "$FOLDER" ]
    [ "$AGENT_POD_GIT_SUBPATH" = "devzone/.git" ]
    [ "$AGENT_POD_GIT_MOUNTPATH" = "$DEVZONE_ROOT/devzone/.git" ]
    [ "$AGENT_POD_SESSION_LABEL" = "dz-222" ]
    [ "$AGENT_POD_TICKET" = "222" ]
}

@test "agent-pod : no subPath starts with /" {
    source_agent_pod
    agent_pod_validate_folder "$FOLDER" >/dev/null
    manifest="$(agent_pod_build_manifest "$FOLDER" "$T/consigne.txt" "agent-dz-222-test")"
    ! grep -E 'subPath: /' "$manifest" || false
    rm -f "$manifest"
}

@test "agent-pod : worktree subPath and mountPath" {
    source_agent_pod
    agent_pod_validate_folder "$FOLDER" >/dev/null
    manifest="$(agent_pod_build_manifest "$FOLDER" "$T/consigne.txt" "agent-dz-222-test")"
    grep -q "subPath: devzone-wt/dz-222" "$manifest" || false
    grep -qF "mountPath: $FOLDER" "$manifest" || false
    rm -f "$manifest"
}

@test "agent-pod : git depot subPath and mountPath" {
    source_agent_pod
    agent_pod_validate_folder "$FOLDER" >/dev/null
    manifest="$(agent_pod_build_manifest "$FOLDER" "$T/consigne.txt" "agent-dz-222-test")"
    grep -q "subPath: devzone/.git" "$manifest" || false
    grep -qF "mountPath: $DEVZONE_ROOT/devzone/.git" "$manifest" || false
    rm -f "$manifest"
}

@test "agent-pod : label, affinity, automount disabled, limits" {
    source_agent_pod
    agent_pod_validate_folder "$FOLDER" >/dev/null
    manifest="$(agent_pod_build_manifest "$FOLDER" "$T/consigne.txt" "agent-dz-222-test")"
    grep -q "devzone.io/agent-session: dz-222" "$manifest" || false
    grep -q 'devzone.io/agent-ticket: "222"' "$manifest" || false
    grep -q "statefulset.kubernetes.io/pod-name" "$manifest" || false
    grep -q "devzone-workspace-0" "$manifest" || false
    grep -q "topologyKey: kubernetes.io/hostname" "$manifest" || false
    grep -q "automountServiceAccountToken: false" "$manifest" || false
    grep -q "restartPolicy: Never" "$manifest" || false
    grep -q "activeDeadlineSeconds: 1800" "$manifest" || false
    grep -q "cpu: 2" "$manifest" || false
    grep -q "memory: 4Gi" "$manifest" || false
    grep -q "image: ghcr.io/test/workspace:1.0" "$manifest" || false
    rm -f "$manifest"
}

@test "agent-pod : no gh, claude, kubeconfig mounted" {
    source_agent_pod
    agent_pod_validate_folder "$FOLDER" >/dev/null
    manifest="$(agent_pod_build_manifest "$FOLDER" "$T/consigne.txt" "agent-dz-222-test")"
    ! grep -qE '(\.config/gh|/\.claude|kubeconfig)' "$manifest" || false
    rm -f "$manifest"
}

@test "agent-pod : volumes workspace and etat are the workspace PVCs" {
    source_agent_pod
    agent_pod_validate_folder "$FOLDER" >/dev/null
    manifest="$(agent_pod_build_manifest "$FOLDER" "$T/consigne.txt" "agent-dz-222-test")"
    grep -A2 -x "  - name: workspace" "$manifest" | grep -q "claimName: workspace-devzone-workspace-0" || false
    grep -A2 -x "  - name: etat" "$manifest" | grep -q "claimName: etat-devzone-workspace-0" || false
    rm -f "$manifest"
}

@test "agent-pod : configmap mount and args" {
    source_agent_pod
    agent_pod_validate_folder "$FOLDER" >/dev/null
    manifest="$(agent_pod_build_manifest "$FOLDER" "$T/consigne.txt" "agent-dz-222-test")"
    grep -q "configMap:" "$manifest" || false
    grep -q "name: agent-dz-222-test-consigne" "$manifest" || false
    grep -q "mountPath: /agent-consigne" "$manifest" || false
    grep -qF "devzone agent --local $FOLDER /agent-consigne/consigne.md" "$manifest" || false
    rm -f "$manifest"
}

@test "agent-pod : consigne content not in manifest" {
    source_agent_pod
    printf 'secret consigne with "quotes" and : colons\nline2\n' >"$T/consigne2.txt"
    agent_pod_validate_folder "$FOLDER" >/dev/null
    manifest="$(agent_pod_build_manifest "$FOLDER" "$T/consigne2.txt" "agent-dz-222-test")"
    ! grep -q "secret consigne" "$manifest" || false
    rm -f "$manifest"
}

@test "agent-pod --pod : runs the session and deletes the pod at the end" {
    run bash "$DEVZONE" agent --pod "$FOLDER" "$T/consigne.txt"
    [ "$status" -eq 0 ]
    grep -q "create configmap" "$T/kubectl.log" || false
    grep -q "create -f" "$T/kubectl.log" || false
    grep -q "delete pod" "$T/kubectl.log" || false
    grep -q "delete configmap" "$T/kubectl.log" || false
}

@test "agent-pod --pod : creation fails -> clear message, non-zero code, try without --pod" {
    export FAKE_CREATE_FAIL=1
    run bash "$DEVZONE" agent --pod "$FOLDER" "$T/consigne.txt"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unable to create the pod"* ]] || false
    [[ "$output" == *"try again without --pod"* ]] || false
    grep -q "delete pod" "$T/kubectl.log" || false
    grep -q "delete configmap" "$T/kubectl.log" || false
}

@test "agent-pod --pod : deletes the pod even when the session fails" {
    export FAKE_PHASE=Failed
    run bash "$DEVZONE" agent --pod "$FOLDER" "$T/consigne.txt"
    [ "$status" -ne 0 ]
    grep -q "delete pod" "$T/kubectl.log" || false
    grep -q "delete configmap" "$T/kubectl.log" || false
}

@test "agent-pod status : lists session pods with their limits" {
    run bash "$DEVZONE" agent status
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "2" || false
    echo "$output" | grep -q "4Gi" || false
}

@test "agent-pod : without --pod, behavior unchanged (local)" {
    unset DEVZONE_WORKSPACE
    printf 'ia=on\n' >"$DEVZONE_ROOT/.devzone.modules"
    run bash "$DEVZONE" agent --local "$FOLDER" "$T/consigne.txt"
    [ "$status" -eq 0 ]
    ! grep -q "create -f" "$T/kubectl.log" || false
}

@test "agent-pod : manifest is a valid Pod (yaml_valid, no cluster)" {
    source_agent_pod
    agent_pod_validate_folder "$FOLDER" >/dev/null
    manifest="$(agent_pod_build_manifest "$FOLDER" "$T/consigne.txt" "agent-dz-222-test")"
    run yaml_valid "$manifest"
    [ "$status" -ne 3 ] || skip "neither ruby nor PyYAML : YAML not checked"
    [ "$status" -eq 0 ]
    # Control only: the real kubectl dry-run runs when a cluster answers.
    if kubectl_dry_run_ok; then
        run "$REAL_KUBECTL" create --dry-run=client --validate=false -f "$manifest" -o name
        [ "$status" -eq 0 ]
    fi
    rm -f "$manifest"
}
