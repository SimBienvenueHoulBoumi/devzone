#!/usr/bin/env bats
# devzone agent: agent rights files protected during the session (#361).
# Fake opencode driven by FAKE_OP_ACTION (command run in the project folder).

setup() {
    load commun
    kube_isole
    agent_isole
    agent_consigne
    P="$DEVZONE_ROOT/workspace/projet"
    mkdir -p "$P/.devcontainer/opencode"
    printf '{"permission":{}}\n' >"$P/.devcontainer/opencode/agent.json"
    printf 'defaut\n' >"$P/.devcontainer/opencode.jsonc"
    git -C "$P" init -q
    git -C "$P" add -A
    git -C "$P" -c user.name=t -c user.email=t@t commit -qm depart
    # Le faux opencode d'agent_isole devient .reel ; le nouveau note l'environnement
    # and runs FAKE_OP_ACTION before delegating to it.
    mv "$BATS_TEST_TMPDIR/bin/opencode" "$BATS_TEST_TMPDIR/bin/opencode.reel"
    cat >"$BATS_TEST_TMPDIR/bin/opencode" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = run ]; then
    echo "SESSION=${DEVZONE_AGENT_SESSION:-}" >>"${BATS_TEST_TMPDIR:?}/session.log"
    eval "${FAKE_OP_ACTION:-:}"
fi
exec "$BATS_TEST_TMPDIR/bin/opencode.reel" "$@"
FAKE
    chmod +x "$BATS_TEST_TMPDIR/bin/opencode"
}

@test "rights: agent.json changed without a commit -> restored, alert in the journal and state" {
    export FAKE_OP_ACTION='echo pirate >>.devcontainer/opencode/agent.json'
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(cat "$P/.devcontainer/opencode/agent.json")" = '{"permission":{}}' ]
    grep -q "=== ⚠ rights changed: .devcontainer/opencode/agent.json : change reverted" "$(agent_journal)" || false
    [ -f "$DEVZONE_AGENT_STATE/droits-projet.alerte" ]
    run bash "$DEVZONE" agent state
    [ "$status" -eq 0 ]
    [[ "$output" == *"⚠ rights changed (projet): see the journal"* ]] || false
}

@test "droits : .repowarden.conf cree par l'agent alors qu'il n'existait pas -> supprime" {
    export FAKE_OP_ACTION='echo "{}" >.repowarden.conf'
    agent_lance
    [ "$status" -eq 0 ]
    [ ! -e "$P/.repowarden.conf" ]
    grep -q "rights changed: .repowarden.conf : change reverted" "$(agent_journal)" || false
}

@test "rights: rights file removed by the agent -> restored" {
    export FAKE_OP_ACTION='rm .devcontainer/opencode.jsonc'
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(cat "$P/.devcontainer/opencode.jsonc")" = "defaut" ]
    grep -q "rights changed: .devcontainer/opencode.jsonc" "$(agent_journal)" || false
}

@test "rights: committed change -> content restored in the tree, history intact, named commit" {
    export FAKE_OP_ACTION='echo pirate >>.devcontainer/opencode/agent.json; git add -A; git -c user.name=t -c user.email=t@t commit -qm modif'
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(cat "$P/.devcontainer/opencode/agent.json")" = '{"permission":{}}' ]
    [ "$(git -C "$P" rev-list --count HEAD)" -eq 2 ]
    sha="$(git -C "$P" log -1 --format=%h)"
    grep -q "rights changed: .devcontainer/opencode/agent.json : .*committed in $sha" "$(agent_journal)" || false
    [ -f "$DEVZONE_AGENT_STATE/droits-projet.alerte" ]
}

@test "droits : session qui ne touche a rien -> aucune alerte" {
    agent_lance
    [ "$status" -eq 0 ]
    ! grep -q "rights changed" "$(agent_journal)" || false
    [ ! -f "$DEVZONE_AGENT_STATE/droits-projet.alerte" ]
    run bash "$DEVZONE" agent state
    [[ "$output" != *"rights changed"* ]] || false
}

@test "rights: check also after a frozen session" {
    export FAKE_OP_ACTION='echo pirate >>.devcontainer/opencode.jsonc'
    export FAKE_OP_FIGEE_MODELS="big-pickle"
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(cat "$P/.devcontainer/opencode.jsonc")" = "defaut" ]
    grep -q "frozen" "$(agent_journal)" || false
    grep -q "rights changed: .devcontainer/opencode.jsonc" "$(agent_journal)" || false
}

@test "droits : alerte effacee au lancement suivant sur le projet" {
    export FAKE_OP_ACTION='echo pirate >>.devcontainer/opencode.jsonc'
    agent_lance
    [ -f "$DEVZONE_AGENT_STATE/droits-projet.alerte" ]
    export FAKE_OP_ACTION=':'
    agent_lance
    [ ! -f "$DEVZONE_AGENT_STATE/droits-projet.alerte" ]
}

@test "rights: permission.edit keeps deny last, even when the env sets edit allow" {
    export OPENCODE_CONFIG_CONTENT='{"permission":{"edit":"allow"}}'
    agent_lance
    [ "$status" -eq 0 ]
    jq -e '.permission.edit | to_entries | (.[0] | .key == "*" and .value == "allow") and (.[-8:] | all(.value == "deny")) and (map(select(.value == "deny")) | length) == 8' "$FAKE_OP_CONFIG_LOG" >/dev/null
    jq -e '.permission.edit | has(".repowarden.conf") and has("**/.devcontainer/agent-rights.sh") and has(".devcontainer/opencode/agent.json") and has(".devcontainer/opencode.jsonc")' "$FAKE_OP_CONFIG_LOG" >/dev/null
}

@test "rights: an env allow on a rights file is moved back to deny, last" {
    export OPENCODE_CONFIG_CONTENT='{"permission":{"edit":{".repowarden.conf":"allow","src/*":"allow"}}}'
    agent_lance
    [ "$status" -eq 0 ]
    jq -e '.permission.edit | .[".repowarden.conf"] == "deny" and .["src/*"] == "allow" and (to_entries | .[-8:] | all(.value == "deny"))' "$FAKE_OP_CONFIG_LOG" >/dev/null
}

@test "rights: without OPENCODE_CONFIG_CONTENT, edit keeps its general allow and the deny rules" {
    unset OPENCODE_CONFIG_CONTENT
    agent_lance
    [ "$status" -eq 0 ]
    jq -e '.permission.edit | .["*"] == "allow" and .[".repowarden.conf"] == "deny"' "$FAKE_OP_CONFIG_LOG" >/dev/null
}

@test "droits : l'environnement d'opencode contient DEVZONE_AGENT_SESSION=1" {
    agent_lance
    [ "$status" -eq 0 ]
    grep -qx "SESSION=1" "$BATS_TEST_TMPDIR/session.log" || false
}
