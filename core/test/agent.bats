#!/usr/bin/env bats
# Commande devzone agent : supervise opencode diriger une consigne (ticket #221).
# Faux opencode dans le PATH : succès, quota (Free usage limit), silence au
# départ (processus vivant sans écrire), session figée (écrit puis se tait).
# Les délais sont réduits par les variables DEVZONE_AGENT_*.

setup() {
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin"
    cd "$BATS_TEST_TMPDIR" || return 1
    export GIT_CONFIG_NOSYSTEM=1
    export DEVZONE_RACINE="$BATS_TEST_TMPDIR/racine"
    mkdir -p "$DEVZONE_RACINE/workspace"
    export FAKE_OP_LOG="$BATS_TEST_TMPDIR/opencode.log"
    export FAKE_OP_CONSIGNE_LOG="$BATS_TEST_TMPDIR/consignes.log"
    export FAKE_OP_CONFIG_LOG="$BATS_TEST_TMPDIR/config.log"
    export FAKE_OP_ECHEC_MODELS=""
    export FAKE_OP_MUET_MODELS=""
    export FAKE_OP_FIGEE_MODELS=""
    export FAKE_OP_DUREE=30
    export DEVZONE_AGENT_SILENCE=1
    export DEVZONE_AGENT_FIGEE=2
    : >"$FAKE_OP_LOG"
    : >"$FAKE_OP_CONSIGNE_LOG"
    cat >"$BATS_TEST_TMPDIR/bin/opencode" <<'OPCODEFAKE'
#!/usr/bin/env bash
case "${1:-}" in
    models)
        printf '%s\n' \
            'opencode/big-pickle' \
            'opencode/deepseek-v4.1-flash-free' \
            'opencode/glm-5.3-flash-free' \
            'opencode/nemotron-3.5-super-vl-free' \
            'opencode/nemotron-3.5-lightning-free' \
            'opencode/mimo-v2.6-flash-free' \
            'opencode/beam-free' \
            'opencode/flint-40b-free' \
            'opencode/nemotron-3-ultra-free'
        ;;
    run)
        modele="${4#opencode/}"
        consigne="${5:-}"
        echo "$modele" >>"${FAKE_OP_LOG:?}"
        printf '%s\n---\n' "$consigne" >>"${FAKE_OP_CONSIGNE_LOG:?}"
        printf '%s\n' "${OPENCODE_CONFIG_CONTENT:-}" >"${FAKE_OP_CONFIG_LOG:?}"
        case " ${FAKE_OP_ECHEC_MODELS:-} " in
            *" $modele "*)
                echo "Free usage limit" >&2
                exit 1
                ;;
        esac
        case " ${FAKE_OP_MUET_MODELS:-} " in
            *" $modele "*)
                sleep "${FAKE_OP_DUREE:-30}"
                exit 0
                ;;
        esac
        echo "session $modele : consigne lue, travail commence"
        echo "le modele $modele a traite la consigne, les tests correspondants passent"
        echo "fin de session $modele : aucune erreur, aucun refus de permission"
        case " ${FAKE_OP_FIGEE_MODELS:-} " in
            *" $modele "*) sleep "${FAKE_OP_DUREE:-30}" ;;
        esac
        exit 0
        ;;
esac
OPCODEFAKE
    chmod +x "$BATS_TEST_TMPDIR/bin/opencode"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

consigne() {
    printf 'construis la feature\n' >"$DEVZONE_RACINE/workspace/consigne.txt"
    mkdir -p "$DEVZONE_RACINE/workspace/projet"
}

@test "agent : sans git push interdit dans la configuration -> refuse de lancer" {
    consigne
    export OPENCODE_CONFIG_CONTENT='{"permission":{"bash":{"*":"ask"}}}'
    run bash "$DEVZONE" agent "$DEVZONE_RACINE/workspace/projet" "$DEVZONE_RACINE/workspace/consigne.txt"
    [ "$status" -eq 2 ]
    [[ "$output" == *"git push non interdit"* ]] || false
    [ ! -s "$FAKE_OP_LOG" ]
}

@test "agent : lance opencode sur la consigne, journal ecrit, fin de session" {
    consigne
    run bash "$DEVZONE" agent "$DEVZONE_RACINE/workspace/projet" "$DEVZONE_RACINE/workspace/consigne.txt"
    [ "$status" -eq 0 ]
    [ -f "$DEVZONE_RACINE/workspace/.agents/projet.log" ]
    grep -q "fin avec opencode/" "$DEVZONE_RACINE/workspace/.agents/projet.log" || false
    grep -qx "big-pickle" "$FAKE_OP_LOG" || false
    grep -q "construis la feature" "$FAKE_OP_CONSIGNE_LOG" || false
}

@test "agent : quota epuisee sur le modele courant -> bascule au modele suivant" {
    consigne
    export FAKE_OP_ECHEC_MODELS="big-pickle"
    run bash "$DEVZONE" agent "$DEVZONE_RACINE/workspace/projet" "$DEVZONE_RACINE/workspace/consigne.txt"
    [ "$status" -eq 0 ]
    [ "$(grep -c . "$FAKE_OP_LOG")" -eq 2 ]
    [ "$(sed -n '1p' "$FAKE_OP_LOG")" = "big-pickle" ]
    [ "$(sed -n '2p' "$FAKE_OP_LOG")" = "deepseek-v4.1-flash-free" ]
    [ ! -f "$HOME/.local/state/oc-lancer/muet-big-pickle" ]
    grep -q "Free usage limit" "$DEVZONE_RACINE/workspace/.agents/projet.log" || false
}

@test "agent : silence au depart -> modele ecarte une heure, modele suivant" {
    consigne
    export FAKE_OP_MUET_MODELS="big-pickle"
    run bash "$DEVZONE" agent "$DEVZONE_RACINE/workspace/projet" "$DEVZONE_RACINE/workspace/consigne.txt"
    [ "$status" -eq 0 ]
    [ "$(grep -c . "$FAKE_OP_LOG")" -eq 2 ]
    [ -f "$HOME/.local/state/oc-lancer/muet-big-pickle" ]
    grep -q "muet au depart" "$DEVZONE_RACINE/workspace/.agents/projet.log" || false
}

@test "agent : session figee -> relancee, consigne de reprise" {
    consigne
    export FAKE_OP_FIGEE_MODELS="big-pickle"
    run bash "$DEVZONE" agent "$DEVZONE_RACINE/workspace/projet" "$DEVZONE_RACINE/workspace/consigne.txt"
    [ "$status" -eq 0 ]
    [ "$(grep -c . "$FAKE_OP_LOG")" -eq 2 ]
    [ "$(sed -n '2p' "$FAKE_OP_LOG")" = "deepseek-v4.1-flash-free" ]
    grep -q "REPRISE" "$FAKE_OP_CONSIGNE_LOG" || false
    grep -q "git log" "$FAKE_OP_CONSIGNE_LOG" || false
    grep -q "fige" "$DEVZONE_RACINE/workspace/.agents/projet.log" || false
}

@test "agent : tous les modeles ecartes -> code 3" {
    consigne
    export FAKE_OP_ECHEC_MODELS="big-pickle deepseek-v4.1-flash-free glm-5.3-flash-free nemotron-3.5-super-vl-free nemotron-3.5-lightning-free mimo-v2.6-flash-free beam-free flint-40b-free nemotron-3-ultra-free"
    run bash "$DEVZONE" agent "$DEVZONE_RACINE/workspace/projet" "$DEVZONE_RACINE/workspace/consigne.txt"
    [ "$status" -eq 3 ]
    grep -q "aucun modele gratuit disponible" "$DEVZONE_RACINE/workspace/.agents/projet.log" || false
}

@test "agent : deux lancements -> deux modeles differents" {
    consigne
    run bash "$DEVZONE" agent "$DEVZONE_RACINE/workspace/projet" "$DEVZONE_RACINE/workspace/consigne.txt"
    [ "$status" -eq 0 ]
    run bash "$DEVZONE" agent "$DEVZONE_RACINE/workspace/projet" "$DEVZONE_RACINE/workspace/consigne.txt"
    [ "$status" -eq 0 ]
    [ "$(grep -c . "$FAKE_OP_LOG")" -eq 2 ]
    [ "$(sed -n '1p' "$FAKE_OP_LOG")" != "$(sed -n '2p' "$FAKE_OP_LOG")" ]
}

@test "agent : configuration fournie completee (git commit permis, bash32 protege)" {
    consigne
    export OPENCODE_CONFIG_CONTENT='{"permission":{"bash":{"*":"ask","git push*":"deny"}}}'
    run bash "$DEVZONE" agent "$DEVZONE_RACINE/workspace/projet" "$DEVZONE_RACINE/workspace/consigne.txt"
    [ "$status" -eq 0 ]
    grep -q '"git commit\*":"allow"' "$FAKE_OP_CONFIG_LOG" || false
    grep -q '"ln \*bash32\*":"deny"' "$FAKE_OP_CONFIG_LOG" || false
    grep -q '"git push\*":"deny"' "$FAKE_OP_CONFIG_LOG" || false
}

@test "agent : etat liste la session et le modele ecarte" {
    consigne
    run bash "$DEVZONE" agent "$DEVZONE_RACINE/workspace/projet" "$DEVZONE_RACINE/workspace/consigne.txt"
    [ "$status" -eq 0 ]
    date +%s >"$HOME/.local/state/oc-lancer/muet-glm-5.3-flash-free"
    run bash "$DEVZONE" agent etat
    [ "$status" -eq 0 ]
    [[ "$output" == *"projet.log"* ]] || false
    [[ "$output" == *"opencode/big-pickle"* ]] || false
    [[ "$output" == *"modele glm-5.3-flash-free ecarte jusqu a"* ]] || false
}
