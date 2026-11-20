#!/usr/bin/env bats
# devzone agent in the Kubernetes workspace (#431): project and journal of the pod,
# otherwise local launch; --local forces the container. Fake kubectl and opencode
# under $BATS_TEST_TMPDIR/bin: no cluster is touched.

setup() {
    load commun
    agent_isole
    unset DEVZONE_WORKSPACE
    fake_kubectl
}

# Fake kubectl: logs its arguments; get pod returns FAKE_KC_PHASE, test -d and
# devzone agent return a configurable code, cat returns a fake journal.
fake_kubectl() {
    export FAKE_KC_LOG="$BATS_TEST_TMPDIR/kubectl.log"
    export FAKE_KC_PHASE="Running" FAKE_KC_GET_CODE=0 FAKE_KC_TEST_CODE=0
    export FAKE_KC_AGENT_CODE=0 FAKE_KC_CAT_CODE=0
    : >"$FAKE_KC_LOG"
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
echo "$*" >>"${FAKE_KC_LOG:?}"
case "$*" in
    "config get-contexts -o name") printf 'devzone\n' ;;
    *"get pod devzone-workspace-0 "*)
        printf '%s\n' "${FAKE_KC_PHASE:-Running}"
        exit "${FAKE_KC_GET_CODE:-0}"
        ;;
    *"exec devzone-workspace-0"*"test -d"*) exit "${FAKE_KC_TEST_CODE:-0}" ;;
    *"exec devzone-workspace-0"*"devzone agent"*) exit "${FAKE_KC_AGENT_CODE:-0}" ;;
    *"exec devzone-workspace-0"*"cat "*".agents/"*)
        printf '=== pod session\n'
        exit "${FAKE_KC_CAT_CODE:-0}"
        ;;
    *"cp "*) exit 0 ;;
esac
exit 0
KUBECTL
    chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
}

@test "agent-workspace : pod Running and project present -> brief copied, then devzone agent in the pod" {
    agent_consigne
    agent_lance
    [ "$status" -eq 0 ]
    grep -q -- "cp .*consigne.txt devzone-workspace-0:/tmp/devzone-agent-projet.md" "$FAKE_KC_LOG" || false
    grep -q -- "exec devzone-workspace-0 -c workspace -- env DEVZONE_RACINE=/home/vscode/.local/share/devzone" "$FAKE_KC_LOG" || false
    grep -q -- "/workspaces/projets/projet /tmp/devzone-agent-projet.md" "$FAKE_KC_LOG" || false
    [[ "$output" == *"Kubernetes workspace"* ]] || false
    [ ! -s "$FAKE_OP_LOG" ] || false
    grep -q "pod session" "$(agent_journal)" || false
}

@test "agent-workspace : return code of the launch in the pod is relayed" {
    agent_consigne
    export FAKE_KC_AGENT_CODE=7
    agent_lance
    [ "$status" -eq 7 ]
    grep -q "pod session" "$(agent_journal)" || false
}

@test "agent-workspace : project absent from the pod -> code 2, copy-to message, nothing launched" {
    agent_consigne
    export FAKE_KC_TEST_CODE=1
    agent_lance
    [ "$status" -eq 2 ]
    [[ "$output" == *"copy-to"* ]] || false
    ! grep -q -- " cp " "$FAKE_KC_LOG" || false
    ! grep -q -- "devzone agent" "$FAKE_KC_LOG" || false
}

@test "agent-workspace : folder absent -> code 2, folder not found message" {
    agent_consigne
    run bash "$DEVZONE" agent "$DEVZONE_RACINE/workspace/absent" "$DEVZONE_RACINE/workspace/consigne.txt"
    [ "$status" -eq 2 ]
    [[ "$output" == *"folder not found"* ]] || false
    ! grep -q -- " cp " "$FAKE_KC_LOG" || false
    ! grep -q -- "devzone agent" "$FAKE_KC_LOG" || false
}

@test "agent-workspace : pod absent -> local launch" {
    agent_consigne
    export FAKE_KC_PHASE=Pending
    agent_lance
    [ "$status" -eq 0 ]
    [ -s "$FAKE_OP_LOG" ] || false
    ! grep -q -- " cp " "$FAKE_KC_LOG" || false
}

@test "agent-workspace : --local -> local launch even if the pod runs" {
    agent_consigne
    run bash "$DEVZONE" agent --local "$DEVZONE_RACINE/workspace/projet" "$DEVZONE_RACINE/workspace/consigne.txt"
    [ "$status" -eq 0 ]
    [ -s "$FAKE_OP_LOG" ] || false
    ! grep -q -- "get pod devzone-workspace-0" "$FAKE_KC_LOG" || false
}

@test "agent-workspace : in the pod -> never kubectl get pod, opencode without KUBECONFIG" {
    agent_consigne
    export DEVZONE_WORKSPACE=kubernetes
    agent_lance
    [ "$status" -eq 0 ]
    [ -s "$FAKE_OP_LOG" ] || false
    [ ! -s "$FAKE_KC_LOG" ] || false
    [ -z "$(cat "$FAKE_OP_KUBECONFIG_LOG")" ] || false
    [[ "$output" != *"Kubernetes workspace"* ]] || false
}

@test "agent-workspace : pod path absent from the workstation -> launched in the pod, without project copy" {
    agent_consigne
    run bash "$DEVZONE" agent /workspaces/projets/devzone-wt/dz-4242 "$DEVZONE_RACINE/workspace/consigne.txt"
    [ "$status" -eq 0 ]
    grep -q -- "test -d /workspaces/projets/devzone-wt/dz-4242" "$FAKE_KC_LOG" || false
    grep -q -- "cp .*consigne.txt devzone-workspace-0:/tmp/devzone-agent-dz-4242.md" "$FAKE_KC_LOG" || false
    grep -q -- "_ /workspaces/projets/devzone-wt/dz-4242 /tmp/devzone-agent-dz-4242.md" "$FAKE_KC_LOG" || false
    [ ! -s "$FAKE_OP_LOG" ] || false
}

@test "agent-workspace : pod path not found in the pod -> code 2, nothing launched" {
    agent_consigne
    export FAKE_KC_TEST_CODE=1
    run bash "$DEVZONE" agent /workspaces/projets/devzone-wt/dz-999 "$DEVZONE_RACINE/workspace/consigne.txt"
    [ "$status" -eq 2 ]
    [[ "$output" == *"not found in the pod"* ]] || false
    ! grep -q -- "devzone agent" "$FAKE_KC_LOG" || false
}
