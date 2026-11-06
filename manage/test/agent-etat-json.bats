#!/usr/bin/env bats
# Sortie machine devzone agent etat --json (#308)

setup() {
    load commun
    agent_isole
}

@test "agent-etat-json : schema 1 et JSON valide" {
    run bash "$DEVZONE" agent etat --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | jq -e . >/dev/null
    [ "$(printf '%s\n' "$output" | jq -r '.schema')" = "1" ]
}

@test "agent-etat-json : session listée" {
    agent_consigne
    agent_lance
    [ "$status" -eq 0 ]
    run bash "$DEVZONE" agent etat --json
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | jq -r '.sessions[0].journal')" = "projet.log" ]
    [ "$(printf '%s\n' "$output" | jq -r '.sessions[0].modele')" = "big-pickle" ]
}

@test "agent-etat-json : ecarts listés" {
    mkdir -p "$DEVZONE_AGENT_ETAT"
    echo "$(date +%s) pays 604800" >"$DEVZONE_AGENT_ETAT/ecart-big-pickle"
    run bash "$DEVZONE" agent etat --json
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | jq -r '.ecarts[0].modele')" = "big-pickle" ]
    [ "$(printf '%s\n' "$output" | jq -r '.ecarts[0].cause')" = "pays" ]
}

@test "agent-etat-json : alertes droits" {
    mkdir -p "$DEVZONE_AGENT_ETAT"
    : >"$DEVZONE_AGENT_ETAT/droits-dz-361.alerte"
    run bash "$DEVZONE" agent etat --json
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | jq -r '.alertes_droits[0]')" = "dz-361" ]
}

@test "agent-etat-json : texte non modifié" {
    run bash "$DEVZONE" agent etat
    [ "$status" -eq 0 ]
    [[ "$output" == *"devzone agent : état"* ]] || false
}
