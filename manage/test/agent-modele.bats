#!/usr/bin/env bats
# devzone agent --modele (#420): the models asked go first, then the usual rotation.
# Fake opencode from commun.bash (FAKE_OP_*): no model, no network.

setup() {
    load commun
    agent_isole
    agent_consigne
    # Journal texts of agent-modele.messages: the tests compare the journal exactly.
    . "$BATS_TEST_DIRNAME/../../.devcontainer/agent-modele.messages"
    mkdir -p "$DEVZONE_AGENT_ETAT"
}

# Runs devzone agent with --modele $1 on the test consigne ($status, $output).
lance_modele() {
    run bash "$DEVZONE" agent --modele "$1" "$DEVZONE_RACINE/workspace/projet" "$DEVZONE_RACINE/workspace/consigne.txt"
}

# Writes an exclusion of model $1 for cause $2, lasting one hour.
ecarte() {
    echo "$(date +%s) $2 3600" >"$DEVZONE_AGENT_ETAT/ecart-$1"
}

# Model of the first and of the second opencode run.
premier_run() { sed -n 1p "$FAKE_OP_LOG"; }
second_run() { sed -n 2p "$FAKE_OP_LOG"; }

@test "agent --modele : the model asked starts first, the choice is logged" {
    lance_modele hy4-flash-free
    [ "$status" -eq 0 ]
    [ "$(premier_run)" = hy4-flash-free ]
    grep -qxF "$(printf "$MSG_CHOISI" hy4-flash-free)" "$(agent_journal)" || false
}

@test "agent --modele : first model asked excluded -> the second one asked starts" {
    ecarte hy4-flash-free quota
    lance_modele hy4-flash-free,beam-free
    [ "$status" -eq 0 ]
    [ "$(premier_run)" = beam-free ]
    grep -qxF "$(printf "$MSG_ECARTE" hy4-flash-free quota)" "$(agent_journal)" || false
}

@test "agent --modele : every model asked excluded -> rotation from the shared rank" {
    ecarte hy4-flash-free quota
    lance_modele hy4-flash-free
    [ "$status" -eq 0 ]
    [ "$(premier_run)" = big-pickle ]
    [ "$(cat "$DEVZONE_AGENT_ETAT/rang")" = 1 ]
    ! grep -q choisi "$(agent_journal)" || false
}

@test "agent --modele : unknown name refused with the free models, nothing launched" {
    lance_modele inconnu-free
    [ "$status" -eq 2 ]
    printf '%s\n' "$output" | grep -q big-pickle || false
    [ ! -s "$FAKE_OP_LOG" ]
}

@test "agent --modele : refused with --pod, nothing launched" {
    run bash "$DEVZONE" agent --modele big-pickle --pod "$DEVZONE_RACINE/workspace/projet" "$DEVZONE_RACINE/workspace/consigne.txt"
    [ "$status" -eq 2 ]
    [ ! -s "$FAKE_OP_LOG" ]
}

@test "agent --modele : without the option, rotation and rank are unchanged" {
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(premier_run)" = big-pickle ]
    grep -qxF "=== --modele : none" "$(agent_journal)" || false
    [ "$(cat "$DEVZONE_AGENT_ETAT/rang")" = 1 ]
    [ "$(bash "$DEVZONE" agent etat --json | jq -r '.sessions[0].demande')" = null ]
}

@test "agent --modele : a requested model that starts does not advance the shared rank" {
    lance_modele hy4-flash-free
    [ "$status" -eq 0 ]
    [ ! -e "$DEVZONE_AGENT_ETAT/rang" ]
}

@test "agent --modele : requested model failing -> rotation, without a second try of it" {
    export FAKE_OP_ECHEC_MODELS=big-pickle
    lance_modele big-pickle
    [ "$status" -eq 0 ]
    [ "$(premier_run)" = big-pickle ]
    [ "$(second_run)" = deepseek-v4.1-flash-free ]
    [ "$(grep -c '^big-pickle$' "$FAKE_OP_LOG")" -eq 1 ]
    grep -qxF "$(printf "$MSG_ECARTE" big-pickle quota)" "$(agent_journal)" || false
}

@test "agent --modele : agent etat shows the model asked and the model used" {
    lance_modele hy4-flash-free
    [ "$status" -eq 0 ]
    run bash "$DEVZONE" agent etat --json
    [ "$(printf '%s\n' "$output" | jq -r '.sessions[0].demande')" = hy4-flash-free ]
    [ "$(printf '%s\n' "$output" | jq -r '.sessions[0].modele')" = hy4-flash-free ]
    run bash "$DEVZONE" agent etat
    [ "$status" -eq 0 ]
    [[ "$output" == *"opencode/hy4-flash-free"* ]] || false
    [[ "$output" == *"(requested: hy4-flash-free)"* ]] || false
}
