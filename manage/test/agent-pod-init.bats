#!/usr/bin/env bats
# devzone agent --pod: logs of the init containers are fetched before the agent
# log (#637), and the init container that refused the session is named on stderr.
# Fake kubectl only, test projects root under BATS_TEST_TMPDIR: no cluster,
# no /workspaces, no network.

load commun
load agent-pod-racine

setup() {
    load commun
    agent_isole
    racine_test
    unset DEVZONE_WORKSPACE
    export DEVZONE_WORKSPACE=kubernetes
    export DEVZONE_AGENT_POD_TIMEOUT=1
    export DEVZONE_AGENT_POD_MODULES_FILE="$BATS_TEST_TMPDIR/modules"
    : >"$DEVZONE_AGENT_POD_MODULES_FILE"
    T="$BATS_TEST_TMPDIR"
    mkdir -p "$T/bin"
    : >"$T/kubectl.log"
    export FAKE_PHASE=Succeeded
    export FAKE_INIT=0
    export FAKE_INIT_FAIL=0
    export FAKE_INIT_STATUSES=""
    export FAKE_INIT_LOG_FAIL=0
    export FAKE_AGENT_STARTED=1

    cat >"$T/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"${BATS_TEST_TMPDIR:-/tmp}/kubectl.log"
case "$*" in
    "config get-contexts -o name") exit 0 ;;
    *"create configmap"*) exit 0 ;;
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
    *"initContainers[*].name"*)
        [ "${FAKE_INIT:-0}" = "1" ] && echo "wait-egress-restriction"
        ;;
    *"initContainerStatuses"*)
        if [ -n "${FAKE_INIT_STATUSES:-}" ]; then
            printf '%s\n' "$FAKE_INIT_STATUSES"
        else
            [ "${FAKE_INIT_FAIL:-0}" = "1" ] && echo "wait-egress-restriction 1"
        fi
        ;;
    *"logs "*"-c wait-egress-restriction"*)
        [ "${FAKE_INIT_LOG_FAIL:-0}" = "1" ] && exit 1
        echo "egress restriction never became effective: session refused"
        ;;
    *"logs "*)
        [ "${FAKE_AGENT_STARTED:-1}" = "1" ] || exit 1
        echo "=== logs of the session in the pod ===="
        ;;
    "delete pod "*) exit 0 ;;
    "delete configmap "*) exit 0 ;;
esac
exit 0
KUBE
    chmod +x "$T/bin/kubectl"
    export PATH="$T/bin:$PATH"
    printf 'build the feature\n' >"$T/consigne.txt"
    FOLDER="$(faux_worktree devzone dz-637)"
    export FOLDER
    export JOURNAL="$DEVZONE_AGENT_ETAT/dz-637.pod.log"
}

@test "agent-pod-init : failed init names the container on stderr and logs its message" {
    export FAKE_INIT=1 FAKE_INIT_FAIL=1 FAKE_PHASE=Failed FAKE_AGENT_STARTED=0
    run bash "$DEVZONE" agent --pod "$FOLDER" "$T/consigne.txt"
    [ "$status" -ne 0 ]
    [[ "$output" == *"init container wait-egress-restriction failed (exit 1)"* ]] || false
    [[ "$output" == *"egress restriction never became effective: session refused"* ]] || false
    grep -q "=== init container wait-egress-restriction ===" "$JOURNAL" || false
    grep -q "egress restriction never became effective: session refused" "$JOURNAL" || false
}

@test "agent-pod-init : init logs come before the agent log" {
    export FAKE_INIT=1 FAKE_PHASE=Succeeded
    run bash "$DEVZONE" agent --pod "$FOLDER" "$T/consigne.txt"
    [ "$status" -eq 0 ]
    grep -q "=== init container wait-egress-restriction ===" "$JOURNAL" || false
    grep -q "=== logs of the session in the pod ====" "$JOURNAL" || false
    init_line="$(grep -n "=== init container wait-egress-restriction ===" "$JOURNAL" | cut -d: -f1)"
    agent_line="$(grep -n "=== logs of the session in the pod ====" "$JOURNAL" | cut -d: -f1)"
    [ "$init_line" -lt "$agent_line" ]
}

@test "agent-pod-init : no init container keeps the journal unchanged" {
    export FAKE_INIT=0 FAKE_PHASE=Succeeded
    run bash "$DEVZONE" agent --pod "$FOLDER" "$T/consigne.txt"
    [ "$status" -eq 0 ]
    expected="$(printf '%s\n%s\n' \
        "=== logs of the session in the pod ====" \
        "=== end of agent session in pod (phase: Succeeded)")"
    [ "$(cat "$JOURNAL")" = "$expected" ]
}

@test "agent-pod-init : a failing kubectl logs -c does not block the session" {
    export FAKE_INIT=1 FAKE_INIT_LOG_FAIL=1 FAKE_PHASE=Succeeded
    run bash "$DEVZONE" agent --pod "$FOLDER" "$T/consigne.txt"
    [ "$status" -eq 0 ]
    grep -q "=== init container wait-egress-restriction ===" "$JOURNAL" || false
    grep -q "=== logs of the session in the pod ====" "$JOURNAL" || false
}

@test "agent-pod-init : init containers that succeeded are not named failed" {
    export FAKE_INIT_STATUSES=$'premier-ok 0\ngarde-en-echec 1'
    export FAKE_PHASE=Failed
    export FAKE_AGENT_STARTED=0
    run bash "$DEVZONE" agent --pod "$FOLDER" "$T/consigne.txt"
    [ "$status" -ne 0 ]
    [[ "$output" == *"init container garde-en-echec failed (exit 1)"* ]] || false
    [[ "$output" != *"init container premier-ok failed"* ]] || false
}

@test "agent-pod-init : failed agent with successful init names no init container" {
    export FAKE_INIT=1
    export FAKE_INIT_STATUSES="wait-egress-restriction 0"
    export FAKE_PHASE=Failed
    export FAKE_AGENT_STARTED=0
    run bash "$DEVZONE" agent --pod "$FOLDER" "$T/consigne.txt"
    [ "$status" -ne 0 ]
    [[ "$output" != *"init container wait-egress-restriction failed"* ]] || false
}

@test "agent-pod-init : successful session with successful init names no init container" {
    export FAKE_INIT=1
    export FAKE_INIT_STATUSES="wait-egress-restriction 0"
    export FAKE_PHASE=Succeeded
    export FAKE_AGENT_STARTED=1
    run bash "$DEVZONE" agent --pod "$FOLDER" "$T/consigne.txt"
    [ "$status" -eq 0 ]
    [[ "$output" != *"init container wait-egress-restriction failed"* ]] || false
}
