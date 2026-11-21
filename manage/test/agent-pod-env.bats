#!/usr/bin/env bats
# devzone agent --pod: environment, modules file, log, signals (#222).
# Second file, so agent-pod.bats stays at 250 lines. Fake kubectl only, and a
# test projects root under BATS_TEST_TMPDIR (no /workspaces).

load commun
load agent-pod-racine

setup() {
    load commun
    agent_isole
    racine_test
    unset DEVZONE_WORKSPACE
    export DEVZONE_WORKSPACE=kubernetes
    export DEVZONE_AGENT_POD_TIMEOUT=1
    T="$BATS_TEST_TMPDIR"
    mkdir -p "$T/bin"
    : >"$T/kubectl.log"
    export FAKE_PHASE=Succeeded
    export FAKE_SIGNAL=""
    export DEVZONE_AGENT_POD_MODULES_FILE="$T/modules"
    : >"$DEVZONE_AGENT_POD_MODULES_FILE"

    cat >"$T/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"${BATS_TEST_TMPDIR:-/tmp}/kubectl.log"
case "$*" in
    "config get-contexts -o name") exit 0 ;;
    *"create configmap"*)
        # Simulate an interrupt right after the ConfigMap is created.
        if [ -n "${FAKE_SIGNAL:-}" ]; then kill -"$FAKE_SIGNAL" "$PPID"; fi
        exit 0 ;;
    *"create -f"*) exit 0 ;;
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
    *"{.status.phase}"*) echo "${FAKE_PHASE:-Succeeded}" ;;
    "logs "*)
        printf 'log line %s\n' {1..20}
        echo "last log line" ;;
    "delete "*) exit 0 ;;
esac
exit 0
KUBE
    chmod +x "$T/bin/kubectl"
    printf 'build the feature\n' >"$T/consigne.txt"
    FOLDER="$(faux_worktree devzone dz-222)"
    export FOLDER
    export SEMI_FOLDER="$DEVZONE_ROOT/devzone-wt/dz;222"
    export PATH="$T/bin:$PATH"
}

source_agent_pod() {
    source "$BATS_TEST_DIRNAME/../../.devcontainer/agent-pod.sh"
}

@test "agent-pod-env : manifest sets DEVZONE_WORKSPACE and DEVZONE_ROOT" {
    source_agent_pod
    agent_pod_validate_folder "$FOLDER" >/dev/null
    manifest="$(agent_pod_build_manifest "$FOLDER" "$T/consigne.txt" "agent-dz-222-test")"
    grep -A1 "name: DEVZONE_WORKSPACE" "$manifest" | grep -q 'value: "kubernetes"' || false
    grep -A1 "name: DEVZONE_ROOT" "$manifest" | grep -q 'value: "/workspaces/projets"' || false
    rm -f "$manifest"
}

@test "agent-pod-env : modules file mounted read-only with a relative subPath" {
    source_agent_pod
    agent_pod_validate_folder "$FOLDER" >/dev/null
    manifest="$(agent_pod_build_manifest "$FOLDER" "$T/consigne.txt" "agent-dz-222-test")"
    grep -A3 "mountPath: /workspaces/projets/.devzone.modules" "$manifest" | grep -q "subPath: .devzone.modules" || false
    grep -A3 "mountPath: /workspaces/projets/.devzone.modules" "$manifest" | grep -q "readOnly: true" || false
    grep -B1 "mountPath: /workspaces/projets/.devzone.modules" "$manifest" | grep -q "name: workspace" || false
    rm -f "$manifest"
}

@test "agent-pod-env : session workspace is a 256Mi emptyDir mounted rw on /workspaces/projets/workspace" {
    source_agent_pod
    agent_pod_validate_folder "$FOLDER" >/dev/null
    manifest="$(agent_pod_build_manifest "$FOLDER" "$T/consigne.txt" "agent-dz-222-test")"
    # The volume is an emptyDir with a size limit and no medium.
    grep -A2 '^  - name: session-workspace$' "$manifest" | grep -q "emptyDir:" || false
    grep -A3 '^  - name: session-workspace$' "$manifest" | grep -q "sizeLimit: 256Mi" || false
    if grep -A3 '^  - name: session-workspace$' "$manifest" | grep -q "medium"; then false; fi
    # Mounted on the path, read-write (no readOnly line after the mount).
    grep -B1 "mountPath: /workspaces/projets/workspace\$" "$manifest" | grep -q "name: session-workspace" || false
    if grep -A1 "mountPath: /workspaces/projets/workspace\$" "$manifest" | grep -q "readOnly"; then false; fi
    # No workspace PVC volume is mounted on that path.
    if grep -B1 "mountPath: /workspaces/projets/workspace\$" "$manifest" | grep -q -- "- name: workspace\$"; then false; fi
    rm -f "$manifest"
}

@test "agent-pod-env : missing modules file refused before any object is created" {
    rm -f "$DEVZONE_AGENT_POD_MODULES_FILE"
    run bash "$DEVZONE" agent --pod "$FOLDER" "$T/consigne.txt"
    [ "$status" -ne 0 ]
    [[ "$output" == *"modules file missing"* ]] || false
    ! grep -q "create" "$T/kubectl.log" || false
}

@test "agent-pod-env : path with semicolon creates nothing" {
    run bash "$DEVZONE" agent --pod "$SEMI_FOLDER" "$T/consigne.txt"
    [ "$status" -ne 0 ]
    ! grep -q "create" "$T/kubectl.log" || false
}

@test "agent-pod-env : default wait is activeDeadlineSeconds + 120" {
    unset DEVZONE_AGENT_POD_TIMEOUT DEVZONE_AGENT_POD_ACTIVE_DEADLINE_SECONDS
    source_agent_pod
    [ "$DEVZONE_AGENT_POD_TIMEOUT" -eq 1920 ]
}

@test "agent-pod-env : two folders give two pod names, pod name is lowercase" {
    source_agent_pod
    first="$(agent_pod_name "$FOLDER")"
    second="$(agent_pod_name "$DEVZONE_ROOT/devzone-wt/dz-223")"
    [[ "$first" == agent-dz-222-* ]] || false
    [[ "$second" == agent-dz-223-* ]] || false
    name="$(agent_pod_name "$DEVZONE_ROOT/Dz-Foo")"
    [[ "$name" == agent-dz-foo-* ]] || false
}

@test "agent-pod-env : log tail on stderr and log kept in the state directory" {
    run bash "$DEVZONE" agent --pod "$FOLDER" "$T/consigne.txt"
    [ "$status" -eq 0 ]
    [[ "$output" == *"last log line"* ]] || false
    [[ "$output" != *"log line 1"$'\n'* ]] || false
    grep -q "last log line" "$DEVZONE_AGENT_STATE/dz-222.pod.log" || false
}

@test "agent-pod-env : failure shows the cause on stderr and keeps the log" {
    export FAKE_PHASE=Failed
    run bash "$DEVZONE" agent --pod "$FOLDER" "$T/consigne.txt"
    [ "$status" -ne 0 ]
    [[ "$output" == *"last log line"* ]] || false
    grep -q "last log line" "$DEVZONE_AGENT_STATE/dz-222.pod.log" || false
    grep -q "delete pod" "$T/kubectl.log" || false
}

@test "agent-pod-env : timeout shows the log tail and deletes the pod" {
    export FAKE_PHASE=Running
    run bash "$DEVZONE" agent --pod "$FOLDER" "$T/consigne.txt"
    [ "$status" -ne 0 ]
    [[ "$output" == *"did not finish in time"* ]] || false
    [[ "$output" == *"last log line"* ]] || false
    grep -q "delete pod" "$T/kubectl.log" || false
}

@test "agent-pod-env : pod command prints the session journal" {
    source_agent_pod
    agent_pod_validate_folder "$FOLDER" >/dev/null
    manifest="$(agent_pod_build_manifest "$FOLDER" "$T/consigne.txt" "agent-dz-222-test")"
    grep -q 'exit \$code' "$manifest" || false
    grep -q '\.agents/dz-222\.log' "$manifest" || false
    rm -f "$manifest"
}

@test "agent-pod-env : interrupt (INT) deletes pod and ConfigMap, exit 130" {
    export FAKE_SIGNAL=INT
    run bash "$DEVZONE" agent --pod "$FOLDER" "$T/consigne.txt"
    [ "$status" -eq 130 ]
    grep -q "delete pod" "$T/kubectl.log" || false
    grep -q "delete configmap" "$T/kubectl.log" || false
}

@test "agent-pod-env : terminate (TERM) deletes pod and ConfigMap, exit 143" {
    export FAKE_SIGNAL=TERM
    run bash "$DEVZONE" agent --pod "$FOLDER" "$T/consigne.txt"
    [ "$status" -eq 143 ]
    grep -q "delete pod" "$T/kubectl.log" || false
    grep -q "delete configmap" "$T/kubectl.log" || false
}

@test "agent-pod-env : manifest with quotes, colons and newlines in the consigne is valid" {
    printf 'say "hi" : it'\''s\nline2: "x"\n' >"$T/consigne3.txt"
    source_agent_pod
    agent_pod_validate_folder "$FOLDER" >/dev/null
    manifest="$(agent_pod_build_manifest "$FOLDER" "$T/consigne3.txt" "agent-dz-222-test")"
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
