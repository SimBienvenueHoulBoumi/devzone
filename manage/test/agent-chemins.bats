#!/usr/bin/env bats
# Commande devzone agent : chemins relatifs résolus, absents refusés (#287).
# Faux opencode piloté par agent_isole : état et journal sous $BATS_TEST_TMPDIR.

setup() {
    load commun
    relais_docker_isole
    kube_isole
    agent_isole
}

@test "agent : dossier et consigne relatifs -> consigne lue depuis le dossier parent" {
    agent_consigne
    run bash "$DEVZONE" agent "racine/workspace/projet" "racine/workspace/consigne.txt"
    [ "$status" -eq 0 ]
    grep -q "construis la feature" "$FAKE_OP_CONSIGNE_LOG" || false
}

@test "agent : consigne introuvable -> refuse code 2, chemin dans le message, pas d opencode, pas d etat" {
    agent_consigne
    run bash "$DEVZONE" agent "$DEVZONE_RACINE/workspace/projet" "$DEVZONE_RACINE/workspace/consigne-absente.txt"
    [ "$status" -eq 2 ]
    [[ "$output" == *"consigne introuvable : $DEVZONE_RACINE/workspace/consigne-absente.txt"* ]] || false
    [ ! -s "$FAKE_OP_LOG" ]
    [ ! -e "$DEVZONE_AGENT_ETAT" ]
}

@test "agent : dossier introuvable -> refuse code 2, chemin dans le message, pas d opencode, pas d etat" {
    agent_consigne
    run bash "$DEVZONE" agent "$DEVZONE_RACINE/workspace/projet-absent" "$DEVZONE_RACINE/workspace/consigne.txt"
    [ "$status" -eq 2 ]
    [[ "$output" == *"dossier introuvable : $DEVZONE_RACINE/workspace/projet-absent"* ]] || false
    [ ! -s "$FAKE_OP_LOG" ]
    [ ! -e "$DEVZONE_AGENT_ETAT" ]
}
