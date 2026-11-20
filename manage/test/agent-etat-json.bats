#!/usr/bin/env bats
# Machine output devzone agent etat --json (#308)

setup() {
    load commun
    relais_docker_isole
    kube_isole
    agent_isole
}

@test "agent-etat-json : schema 1 and valid JSON" {
    run bash "$DEVZONE" agent etat --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | jq -e . >/dev/null
    [ "$(printf '%s\n' "$output" | jq -r '.schema')" = "1" ]
}

@test "agent-etat-json : session listed" {
    agent_consigne
    agent_lance
    [ "$status" -eq 0 ]
    run bash "$DEVZONE" agent etat --json
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | jq -r '.sessions[0].journal')" = "projet.log" ]
    [ "$(printf '%s\n' "$output" | jq -r '.sessions[0].modele')" = "big-pickle" ]
}

@test "agent-etat-json : exclusions listed" {
    mkdir -p "$DEVZONE_AGENT_ETAT"
    echo "$(date +%s) pays 604800" >"$DEVZONE_AGENT_ETAT/ecart-big-pickle"
    run bash "$DEVZONE" agent etat --json
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | jq -r '.ecarts[0].modele')" = "big-pickle" ]
    [ "$(printf '%s\n' "$output" | jq -r '.ecarts[0].cause')" = "pays" ]
}

@test "agent-etat-json : rights alerts" {
    mkdir -p "$DEVZONE_AGENT_ETAT"
    : >"$DEVZONE_AGENT_ETAT/droits-dz-361.alerte"
    run bash "$DEVZONE" agent etat --json
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | jq -r '.alertes_droits[0]')" = "dz-361" ]
}

@test "agent-etat-json : text output unchanged in structure" {
    run bash "$DEVZONE" agent etat
    [ "$status" -eq 0 ]
    [[ "$output" == *"devzone agent: state"* ]] || false
}

# Fake agent.sh that sleeps while its life marker exists (a real launch is forbidden
# in the tests): sets PID_FAUX_AGENT.
agent_fake_process() {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    printf '#!/usr/bin/env bash\nwhile [ -e "${AGENT_FAKE_LIFE:?}" ]; do sleep 0.1; done\n' >"$BATS_TEST_TMPDIR/bin/agent.sh"
    chmod +x "$BATS_TEST_TMPDIR/bin/agent.sh"
    : >"$BATS_TEST_TMPDIR/agent.life"
    AGENT_FAKE_LIFE="$BATS_TEST_TMPDIR/agent.life" "$BATS_TEST_TMPDIR/bin/agent.sh" "$1" >/dev/null 2>&1 &
    PID_FAUX_AGENT=$!
}

# Stops the fake agent.sh of agent_fake_process: removes the life marker, then waits
# for the process to exit, without kill.
agent_fake_stop() {
    rm -f "$BATS_TEST_TMPDIR/agent.life"
    wait "$PID_FAUX_AGENT"
}

@test "agent-etat-json : agent.sh on dz-308 -> dz-308.log running" {
    mkdir -p "$DEVZONE_RACINE/workspace/.agents" "$BATS_TEST_TMPDIR/dz-308"
    : >"$DEVZONE_RACINE/workspace/.agents/dz-308.log"
    agent_fake_process "$BATS_TEST_TMPDIR/dz-308"
    run bash "$DEVZONE" agent etat --json
    agent_fake_stop
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | jq -r '.sessions[] | select(.journal=="dz-308.log") | .en_cours')" = "true" ]
}

@test "agent-etat-json : agent.sh on dz-30 -> neither dz-308 nor d running" {
    mkdir -p "$DEVZONE_RACINE/workspace/.agents"
    : >"$DEVZONE_RACINE/workspace/.agents/dz-308.log"
    : >"$DEVZONE_RACINE/workspace/.agents/d.log"
    # A real agent.sh could run on dz-308 during the test (the session of the folder
    # itself): dz-308.log would then really be running, unrelated to the fake process
    # of the test; that case is covered above.
    run bash "$DEVZONE" agent etat --json
    [ "$status" -eq 0 ]
    before="$(printf '%s\n' "$output" | jq -r '.sessions[] | select(.journal=="dz-308.log") | .en_cours')"
    agent_fake_process "$BATS_TEST_TMPDIR/dz-30"
    run bash "$DEVZONE" agent etat --json
    agent_fake_stop
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | jq -r '.sessions[] | select(.journal=="d.log") | .en_cours')" = "false" ]
    if [ "$before" = "false" ]; then
        [ "$(printf '%s\n' "$output" | jq -r '.sessions[] | select(.journal=="dz-308.log") | .en_cours')" = "false" ]
    else
        echo "real agent.sh on dz-308: dz-308.log running is legitimate"
        true
    fi
}

@test "agent-etat-json : model read on the '=== model opencode/ start' line" {
    mkdir -p "$DEVZONE_RACINE/workspace/.agents"
    printf '%s\n' \
        'model text: opencode/agent.json is read' \
        '=== model opencode/beam-free start 2026-11-06T00:00:00Z' \
        'more text: opencode/agent.json' \
        >"$DEVZONE_RACINE/workspace/.agents/dz-328.log"
    run bash "$DEVZONE" agent etat --json
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | jq -r '.sessions[0].modele')" = "beam-free" ]
}

@test "agent-etat : the text reads the same model as the JSON" {
    mkdir -p "$DEVZONE_RACINE/workspace/.agents"
    printf '%s\n' \
        'model text: opencode/agent.json is read' \
        '=== model opencode/beam-free start 2026-11-06T00:00:00Z' \
        >"$DEVZONE_RACINE/workspace/.agents/dz-328.log"
    run bash "$DEVZONE" agent etat
    [ "$status" -eq 0 ]
    [[ "$output" == *"session dz-328.log: model opencode/beam-free, since 2026-11-06T00:00:00Z"* ]] || false
}
