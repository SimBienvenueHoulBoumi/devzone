#!/usr/bin/env bats
# devzone agent command: relative paths resolved, missing ones refused (#287).
# Fake opencode driven by agent_isole: state and journal under $BATS_TEST_TMPDIR.

setup() {
    load commun
    relais_docker_isole
    kube_isole
    agent_isole
}

@test "agent : relative folder and brief -> brief read from the parent folder" {
    agent_consigne
    run bash "$DEVZONE" agent "racine/workspace/projet" "racine/workspace/consigne.txt"
    [ "$status" -eq 0 ]
    grep -q "construis la feature" "$FAKE_OP_CONSIGNE_LOG" || false
}

@test "agent : brief not found -> refused code 2, path in the message, no opencode, no state" {
    agent_consigne
    run bash "$DEVZONE" agent "$DEVZONE_RACINE/workspace/projet" "$DEVZONE_RACINE/workspace/consigne-absente.txt"
    [ "$status" -eq 2 ]
    [[ "$output" == *"brief not found: $DEVZONE_RACINE/workspace/consigne-absente.txt"* ]] || false
    [ ! -s "$FAKE_OP_LOG" ]
    [ ! -e "$DEVZONE_AGENT_ETAT" ]
}

@test "agent : folder not found -> refused code 2, path in the message, no opencode, no state" {
    agent_consigne
    run bash "$DEVZONE" agent "$DEVZONE_RACINE/workspace/projet-absent" "$DEVZONE_RACINE/workspace/consigne.txt"
    [ "$status" -eq 2 ]
    [[ "$output" == *"folder not found: $DEVZONE_RACINE/workspace/projet-absent"* ]] || false
    [ ! -s "$FAKE_OP_LOG" ]
    [ ! -e "$DEVZONE_AGENT_ETAT" ]
}
