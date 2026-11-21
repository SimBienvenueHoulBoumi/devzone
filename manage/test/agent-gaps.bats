#!/usr/bin/env bats
# devzone agent command: exclusions by cause, network wait, state and liberer (#328).
# Launches, rotation and resume are in agent.bats.

setup() {
    load commun
    agent_isole
}

@test "agent : quota exhausted -> model excluded 1 h (quota), next model" {
    agent_consigne
    export FAKE_OP_ECHEC_MODELS="big-pickle"
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(grep -c . "$FAKE_OP_LOG")" -eq 2 ]
    [ "$(sed -n '1p' "$FAKE_OP_LOG")" = "big-pickle" ]
    [ "$(sed -n '2p' "$FAKE_OP_LOG")" = "deepseek-v4.1-flash-free" ]
    grep -q "^[0-9]* quota 3600$" "$DEVZONE_AGENT_STATE/ecart-big-pickle" || false
    grep -q "Free usage limit" "$(agent_journal)" || false
}

@test "agent : country not available -> model excluded 7 days (country), next model" {
    agent_consigne
    export FAKE_OP_ECHEC_MODELS="big-pickle"
    export FAKE_OP_MESSAGE="not available in your country"
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(grep -c . "$FAKE_OP_LOG")" -eq 2 ]
    [ "$(sed -n '2p' "$FAKE_OP_LOG")" = "deepseek-v4.1-flash-free" ]
    grep -q "^[0-9]* pays 604800$" "$DEVZONE_AGENT_STATE/ecart-big-pickle" || false
    grep -q "excluded (country, 7 d)" "$(agent_journal)" || false
}

@test "agent : content filter -> model excluded 1 h (filter), next model" {
    agent_consigne
    export FAKE_OP_ECHEC_MODELS="big-pickle"
    export FAKE_OP_MESSAGE="content filter"
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(sed -n '2p' "$FAKE_OP_LOG")" = "deepseek-v4.1-flash-free" ]
    grep -q "^[0-9]* filtre 3600$" "$DEVZONE_AGENT_STATE/ecart-big-pickle" || false
}

@test "agent : error without known cause -> next model, no exclusion" {
    agent_consigne
    export FAKE_OP_ECHEC_MODELS="big-pickle"
    export FAKE_OP_MESSAGE="Model is unavailable"
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(sed -n '2p' "$FAKE_OP_LOG")" = "deepseek-v4.1-flash-free" ]
    [ ! -f "$DEVZONE_AGENT_STATE/ecart-big-pickle" ]
    grep -q "no exclusion" "$(agent_journal)" || false
}

@test "agent : network word but network reachable -> treated as other, no loop" {
    agent_consigne
    export FAKE_OP_ECHEC_MODELS="big-pickle"
    export FAKE_OP_MESSAGE="network down"
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(grep -c . "$FAKE_OP_LOG")" -eq 2 ]
    [ "$(sed -n '2p' "$FAKE_OP_LOG")" = "deepseek-v4.1-flash-free" ]
    grep -q "network reachable: treated as other" "$(agent_journal)" || false
    [ ! -f "$DEVZONE_AGENT_STATE/ecart-big-pickle" ]
}

@test "agent : ENOTFOUND then network back -> same model relaunched, no exclusion" {
    agent_consigne
    export FAKE_OP_RESEAU_MODELS="big-pickle"
    echo 2 >"$RESEAU_COUPE"
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(grep -c . "$FAKE_OP_LOG")" -eq 2 ]
    [ "$(sed -n '1p' "$FAKE_OP_LOG")" = "big-pickle" ]
    [ "$(sed -n '2p' "$FAKE_OP_LOG")" = "big-pickle" ]
    grep -q "network down, waiting" "$(agent_journal)" || false
    grep -q "network back" "$(agent_journal)" || false
    grep -q "end with opencode/big-pickle" "$(agent_journal)" || false
    grep -q "RESUME" "$FAKE_OP_CONSIGNE_LOG" || false
    [ ! -f "$DEVZONE_AGENT_STATE/ecart-big-pickle" ]
}

@test "agent : ENOTFOUND repeated 4 times, network back each time -> 3 retries then next model" {
    agent_consigne
    export FAKE_OP_RESEAU_CHAQUE="big-pickle"
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(grep -c '^big-pickle$' "$FAKE_OP_LOG")" -eq 4 ]
    [ "$(sed -n '5p' "$FAKE_OP_LOG")" = "deepseek-v4.1-flash-free" ]
    grep -q "network down 3 times: next model, no exclusion" "$(agent_journal)" || false
    [ ! -f "$DEVZONE_AGENT_STATE/ecart-big-pickle" ]
}

@test "agent : network never back -> code 4 network unavailable, no exclusion" {
    agent_consigne
    export FAKE_OP_RESEAU_MODELS="big-pickle"
    echo 1000000 >"$RESEAU_COUPE"
    export DEVZONE_AGENT_NETWORK_MAX=2
    agent_lance
    [ "$status" -eq 4 ]
    grep -q "network unavailable" "$(agent_journal)" || false
    ! grep -q "no free model available" "$(agent_journal)" || false
    [ "$(grep -c . "$FAKE_OP_LOG")" -eq 1 ]
    [ ! -f "$DEVZONE_AGENT_STATE/ecart-big-pickle" ]
}

@test "agent : silence at start -> model excluded one hour (silent), next model" {
    agent_consigne
    export FAKE_OP_MUET_MODELS="big-pickle"
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(grep -c . "$FAKE_OP_LOG")" -eq 2 ]
    grep -q "^[0-9]* mute 3600$" "$DEVZONE_AGENT_STATE/ecart-big-pickle" || false
    grep -q "silent at start" "$(agent_journal)" || false
}

@test "agent : old muet- file still counted for 1 h" {
    agent_consigne
    mkdir -p "$DEVZONE_AGENT_STATE"
    date +%s >"$DEVZONE_AGENT_STATE/muet-big-pickle"
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(sed -n '1p' "$FAKE_OP_LOG")" = "deepseek-v4.1-flash-free" ]
}

@test "agent : state lists the session, the excluded model and its cause" {
    agent_consigne
    agent_lance
    [ "$status" -eq 0 ]
    echo "$(date +%s) pays 604800" >"$DEVZONE_AGENT_STATE/ecart-big-pickle"
    echo "$(date +%s) quota 3600" >"$DEVZONE_AGENT_STATE/ecart-glm-5.3-flash-free"
    run bash "$DEVZONE" agent etat
    [ "$status" -eq 0 ]
    [[ "$output" == *"projet.log"* ]] || false
    [[ "$output" == *"opencode/big-pickle"* ]] || false
    [[ "$output" == *"model big-pickle excluded (country) until"* ]] || false
    [[ "$output" == *"model glm-5.3-flash-free excluded (quota) until"* ]] || false
}

@test "agent : state only lists current exclusions, with their end time" {
    mkdir -p "$DEVZONE_AGENT_STATE"
    now="$(date +%s)"
    echo $(( now - 600 )) >"$DEVZONE_AGENT_STATE/muet-big-pickle"
    echo $(( now - 7200 )) >"$DEVZONE_AGENT_STATE/muet-deepseek-v4.1-flash-free"
    run bash "$DEVZONE" agent etat
    [ "$status" -eq 0 ]
    [[ "$output" == *"model big-pickle excluded (silent) until"* ]] || false
    [[ "$output" != *"deepseek-v4.1-flash-free"* ]] || false
}

@test "agent : liberer lifts one model's exclusion, --tous lifts all, without argument refused" {
    mkdir -p "$DEVZONE_AGENT_STATE"
    echo "$(date +%s) pays 604800" >"$DEVZONE_AGENT_STATE/ecart-big-pickle"
    echo "$(date +%s) quota 3600" >"$DEVZONE_AGENT_STATE/ecart-glm-5.3-flash-free"
    run bash "$DEVZONE" agent liberer
    [ "$status" -eq 2 ]
    run bash "$DEVZONE" agent liberer big-pickle
    [ "$status" -eq 0 ]
    [ ! -f "$DEVZONE_AGENT_STATE/ecart-big-pickle" ]
    [ -f "$DEVZONE_AGENT_STATE/ecart-glm-5.3-flash-free" ]
    run bash "$DEVZONE" agent liberer --tous
    [ "$status" -eq 0 ]
    [ ! -f "$DEVZONE_AGENT_STATE/ecart-glm-5.3-flash-free" ]
}

@test "agent : error_cause classifies country, quota, filter, network and other" {
    run bash -c '. "$1"; for t in "not available in your country" "Free usage limit" "content filter" ECONNREFUSED ENOTFOUND ETIMEDOUT "Model is unavailable"; do error_cause "$t"; done' _ "$BATS_TEST_DIRNAME/../../.devcontainer/agent-errors.sh"
    [ "$output" = $'pays\nquota\nfiltre\nreseau\nreseau\nreseau\nautre' ]
}
