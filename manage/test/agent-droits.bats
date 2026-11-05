#!/usr/bin/env bats
# devzone agent : fichiers de droits des agents protégés pendant la session (#361).
# Faux opencode piloté par FAKE_OP_ACTION (commande lancée dans le dossier du projet).

setup() {
    load commun
    relais_docker_isole
    kube_isole
    agent_isole
    agent_consigne
    P="$DEVZONE_RACINE/workspace/projet"
    mkdir -p "$P/.devcontainer/opencode"
    printf '{"permission":{}}\n' >"$P/.devcontainer/opencode/agent.json"
    printf 'defaut\n' >"$P/.devcontainer/opencode.jsonc"
    git -C "$P" init -q
    git -C "$P" add -A
    git -C "$P" -c user.name=t -c user.email=t@t commit -qm depart
    # Le faux opencode d'agent_isole devient .reel ; le nouveau note l'environnement
    # et exécute FAKE_OP_ACTION avant de lui déléguer.
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

@test "droits : agent.json modifie sans commit -> remis, alerte au journal et dans etat" {
    export FAKE_OP_ACTION='echo pirate >>.devcontainer/opencode/agent.json'
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(cat "$P/.devcontainer/opencode/agent.json")" = '{"permission":{}}' ]
    grep -q "=== ⚠ droits modifiés : .devcontainer/opencode/agent.json : changement annulé" "$(agent_journal)" || false
    [ -f "$DEVZONE_AGENT_ETAT/droits-projet.alerte" ]
    run bash "$DEVZONE" agent etat
    [ "$status" -eq 0 ]
    [[ "$output" == *"⚠ droits modifiés (projet) : voir le journal"* ]] || false
}

@test "droits : .repowarden.conf cree par l'agent alors qu'il n'existait pas -> supprime" {
    export FAKE_OP_ACTION='echo "{}" >.repowarden.conf'
    agent_lance
    [ "$status" -eq 0 ]
    [ ! -e "$P/.repowarden.conf" ]
    grep -q "droits modifiés : .repowarden.conf : changement annulé" "$(agent_journal)" || false
}

@test "droits : fichier de droits supprime par l'agent -> restaure" {
    export FAKE_OP_ACTION='rm .devcontainer/opencode.jsonc'
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(cat "$P/.devcontainer/opencode.jsonc")" = "defaut" ]
    grep -q "droits modifiés : .devcontainer/opencode.jsonc" "$(agent_journal)" || false
}

@test "droits : modification commitee -> contenu remis dans l'arbre, historique intact, commit nomme" {
    export FAKE_OP_ACTION='echo pirate >>.devcontainer/opencode/agent.json; git add -A; git -c user.name=t -c user.email=t@t commit -qm modif'
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(cat "$P/.devcontainer/opencode/agent.json")" = '{"permission":{}}' ]
    [ "$(git -C "$P" rev-list --count HEAD)" -eq 2 ]
    sha="$(git -C "$P" log -1 --format=%h)"
    grep -q "droits modifiés : .devcontainer/opencode/agent.json : .*commité dans $sha" "$(agent_journal)" || false
    [ -f "$DEVZONE_AGENT_ETAT/droits-projet.alerte" ]
}

@test "droits : session qui ne touche a rien -> aucune alerte" {
    agent_lance
    [ "$status" -eq 0 ]
    ! grep -q "droits modifiés" "$(agent_journal)" || false
    [ ! -f "$DEVZONE_AGENT_ETAT/droits-projet.alerte" ]
    run bash "$DEVZONE" agent etat
    [[ "$output" != *"droits modifiés"* ]] || false
}

@test "droits : verification aussi apres une session figee" {
    export FAKE_OP_ACTION='echo pirate >>.devcontainer/opencode.jsonc'
    export FAKE_OP_FIGEE_MODELS="big-pickle"
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(cat "$P/.devcontainer/opencode.jsonc")" = "defaut" ]
    grep -q "figé" "$(agent_journal)" || false
    grep -q "droits modifiés : .devcontainer/opencode.jsonc" "$(agent_journal)" || false
}

@test "droits : alerte effacee au lancement suivant sur le projet" {
    export FAKE_OP_ACTION='echo pirate >>.devcontainer/opencode.jsonc'
    agent_lance
    [ -f "$DEVZONE_AGENT_ETAT/droits-projet.alerte" ]
    export FAKE_OP_ACTION=':'
    agent_lance
    [ ! -f "$DEVZONE_AGENT_ETAT/droits-projet.alerte" ]
}

@test "droits : permission.edit a les deny en dernier, meme si l'env pose edit allow" {
    export OPENCODE_CONFIG_CONTENT='{"permission":{"edit":"allow"}}'
    agent_lance
    [ "$status" -eq 0 ]
    jq -e '.permission.edit | to_entries | (.[0] | .key == "*" and .value == "allow") and (.[-8:] | all(.value == "deny")) and (map(select(.value == "deny")) | length) == 8' "$FAKE_OP_CONFIG_LOG" >/dev/null
    jq -e '.permission.edit | has(".repowarden.conf") and has("**/.devcontainer/agent-droits.sh") and has(".devcontainer/opencode/agent.json") and has(".devcontainer/opencode.jsonc")' "$FAKE_OP_CONFIG_LOG" >/dev/null
}

@test "droits : un allow de l'env sur un fichier de droits est repasse en deny, en dernier" {
    export OPENCODE_CONFIG_CONTENT='{"permission":{"edit":{".repowarden.conf":"allow","src/*":"allow"}}}'
    agent_lance
    [ "$status" -eq 0 ]
    jq -e '.permission.edit | .[".repowarden.conf"] == "deny" and .["src/*"] == "allow" and (to_entries | .[-8:] | all(.value == "deny"))' "$FAKE_OP_CONFIG_LOG" >/dev/null
}

@test "droits : sans OPENCODE_CONFIG_CONTENT, edit garde son allow general et les deny" {
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
