#!/usr/bin/env bats
# devzone agent dans le workspace Kubernetes (#431) : projet et journal du pod,
# sinon lancement local ; --local force le conteneur. Faux kubectl et opencode
# sous $BATS_TEST_TMPDIR/bin : aucun cluster n'est touche.

setup() {
    load commun
    agent_isole
    faux_kubectl
}

# Faux kubectl : journalise ses arguments ; get pod rend FAKE_KC_PHASE, test -d
# et devzone agent rendent leur code configurable, cat rend un journal factice.
faux_kubectl() {
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
        printf '=== session du pod\n'
        exit "${FAKE_KC_CAT_CODE:-0}"
        ;;
    *"cp "*) exit 0 ;;
esac
exit 0
KUBECTL
    chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
}

@test "agent-workspace : pod Running et projet present -> consigne copiee puis devzone agent dans le pod" {
    agent_consigne
    agent_lance
    [ "$status" -eq 0 ]
    grep -q -- "cp .*consigne.txt devzone-workspace-0:/tmp/devzone-agent-projet.md" "$FAKE_KC_LOG" || false
    grep -q -- "exec devzone-workspace-0 -c workspace -- env DEVZONE_RACINE=/home/vscode/.local/share/devzone" "$FAKE_KC_LOG" || false
    grep -q -- "/workspaces/projets/projet /tmp/devzone-agent-projet.md" "$FAKE_KC_LOG" || false
    [[ "$output" == *"workspace Kubernetes"* ]] || false
    [ ! -s "$FAKE_OP_LOG" ] || false
    grep -q "session du pod" "$(agent_journal)" || false
}

@test "agent-workspace : code de retour du lancement dans le pod relaye" {
    agent_consigne
    export FAKE_KC_AGENT_CODE=7
    agent_lance
    [ "$status" -eq 7 ]
    grep -q "session du pod" "$(agent_journal)" || false
}

@test "agent-workspace : projet absent du pod -> code 2, message copier-vers, rien lance" {
    agent_consigne
    export FAKE_KC_TEST_CODE=1
    agent_lance
    [ "$status" -eq 2 ]
    [[ "$output" == *"copier-vers"* ]] || false
    ! grep -q -- " cp " "$FAKE_KC_LOG" || false
    ! grep -q -- "devzone agent" "$FAKE_KC_LOG" || false
}

@test "agent-workspace : pod absent -> lancement local" {
    agent_consigne
    export FAKE_KC_PHASE=Pending
    agent_lance
    [ "$status" -eq 0 ]
    [ -s "$FAKE_OP_LOG" ] || false
    ! grep -q -- " cp " "$FAKE_KC_LOG" || false
}

@test "agent-workspace : --local -> lancement local meme si le pod tourne" {
    agent_consigne
    run bash "$DEVZONE" agent --local "$DEVZONE_RACINE/workspace/projet" "$DEVZONE_RACINE/workspace/consigne.txt"
    [ "$status" -eq 0 ]
    [ -s "$FAKE_OP_LOG" ] || false
    ! grep -q -- "get pod devzone-workspace-0" "$FAKE_KC_LOG" || false
}

@test "agent-workspace : dans le pod -> jamais de kubectl get pod, opencode sans KUBECONFIG" {
    agent_consigne
    export DEVZONE_WORKSPACE=kubernetes
    agent_lance
    [ "$status" -eq 0 ]
    [ -s "$FAKE_OP_LOG" ] || false
    [ ! -s "$FAKE_KC_LOG" ] || false
    [ -z "$(cat "$FAKE_OP_KUBECONFIG_LOG")" ] || false
    [[ "$output" != *"workspace Kubernetes"* ]] || false
}
