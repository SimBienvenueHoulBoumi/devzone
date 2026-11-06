#!/usr/bin/env bats
# Sortie machine devzone agent etat --json (#308)

setup() {
    load commun
    relais_docker_isole
    kube_isole
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

# Faux agent.sh qui dort tant que son marqueur de vie existe (un vrai
# lancement est interdit dans les tests) : met PID_FAUX_AGENT.
agent_faux_process() {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    printf '#!/usr/bin/env bash\nwhile [ -e "${AGENT_FAUX_VIE:?}" ]; do sleep 0.1; done\n' >"$BATS_TEST_TMPDIR/bin/agent.sh"
    chmod +x "$BATS_TEST_TMPDIR/bin/agent.sh"
    : >"$BATS_TEST_TMPDIR/agent.vie"
    AGENT_FAUX_VIE="$BATS_TEST_TMPDIR/agent.vie" "$BATS_TEST_TMPDIR/bin/agent.sh" "$1" >/dev/null 2>&1 &
    PID_FAUX_AGENT=$!
}

# Arrête le faux agent.sh de agent_faux_process : retire le marqueur de vie
# puis attend la sortie du processus, sans kill.
agent_faux_stop() {
    rm -f "$BATS_TEST_TMPDIR/agent.vie"
    wait "$PID_FAUX_AGENT"
}

@test "agent-etat-json : agent.sh sur dz-308 -> dz-308.log en cours" {
    mkdir -p "$DEVZONE_RACINE/workspace/.agents" "$BATS_TEST_TMPDIR/dz-308"
    : >"$DEVZONE_RACINE/workspace/.agents/dz-308.log"
    agent_faux_process "$BATS_TEST_TMPDIR/dz-308"
    run bash "$DEVZONE" agent etat --json
    agent_faux_stop
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | jq -r '.sessions[] | select(.journal=="dz-308.log") | .en_cours')" = "true" ]
}

@test "agent-etat-json : agent.sh sur dz-30 -> ni dz-308 ni d en cours" {
    mkdir -p "$DEVZONE_RACINE/workspace/.agents"
    : >"$DEVZONE_RACINE/workspace/.agents/dz-308.log"
    : >"$DEVZONE_RACINE/workspace/.agents/d.log"
    # Un vrai agent.sh pourrait tourner sur dz-308 pendant le test (session du
    # dossier même) : dz-308.log serait alors justement en cours, sans lien
    # avec le faux processus du test ; ce cas est couvert plus haut.
    run bash "$DEVZONE" agent etat --json
    [ "$status" -eq 0 ]
    avant="$(printf '%s\n' "$output" | jq -r '.sessions[] | select(.journal=="dz-308.log") | .en_cours')"
    agent_faux_process "$BATS_TEST_TMPDIR/dz-30"
    run bash "$DEVZONE" agent etat --json
    agent_faux_stop
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | jq -r '.sessions[] | select(.journal=="d.log") | .en_cours')" = "false" ]
    if [ "$avant" = "false" ]; then
        [ "$(printf '%s\n' "$output" | jq -r '.sessions[] | select(.journal=="dz-308.log") | .en_cours')" = "false" ]
    else
        echo "vrai agent.sh sur dz-308 : dz-308.log en cours est légitime"
        true
    fi
}

@test "agent-etat-json : modèle lu sur la ligne « === modèle opencode/ début »" {
    mkdir -p "$DEVZONE_RACINE/workspace/.agents"
    printf '%s\n' \
        'texte du modèle : opencode/agent.json est lu' \
        '=== modèle opencode/beam-free début 2026-11-06T00:00:00Z' \
        'encore du texte : opencode/agent.json' \
        >"$DEVZONE_RACINE/workspace/.agents/dz-328.log"
    run bash "$DEVZONE" agent etat --json
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | jq -r '.sessions[0].modele')" = "beam-free" ]
}

@test "agent-etat : le texte lit le même modèle que le JSON" {
    mkdir -p "$DEVZONE_RACINE/workspace/.agents"
    printf '%s\n' \
        'texte du modèle : opencode/agent.json est lu' \
        '=== modèle opencode/beam-free début 2026-11-06T00:00:00Z' \
        >"$DEVZONE_RACINE/workspace/.agents/dz-328.log"
    run bash "$DEVZONE" agent etat
    [ "$status" -eq 0 ]
    [[ "$output" == *"session dz-328.log : modèle opencode/beam-free, depuis 2026-11-06T00:00:00Z"* ]] || false
}
