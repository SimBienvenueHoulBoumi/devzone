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
    # npm simulé minimal pour l'activation du module ia (assistant requis par devzone agent)
    export NPM_LOG="$BATS_TEST_TMPDIR/npm.log"
    : >"$NPM_LOG"
    cat >"$BATS_TEST_TMPDIR/bin/npm" <<'NPM'
#!/usr/bin/env bash
echo "npm $*" >>"$NPM_LOG"
if [ "${1:-}" = install ]; then
    printf '#!/usr/bin/env bash\necho 1.0.0\n' >"$BATS_TEST_TMPDIR/bin/claude"
    printf '#!/usr/bin/env bash\necho 1.0.0\n' >"$BATS_TEST_TMPDIR/bin/opencode"
    chmod +x "$BATS_TEST_TMPDIR/bin/claude" "$BATS_TEST_TMPDIR/bin/opencode"
fi
NPM
    chmod +x "$BATS_TEST_TMPDIR/bin/npm"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    bash "$DEVZONE" activer ia >/dev/null 2>&1 || true
    export FAKE_OP_LOG="$BATS_TEST_TMPDIR/opencode.log"
    export FAKE_OP_CONSIGNE_LOG="$BATS_TEST_TMPDIR/consignes.log"
    export FAKE_OP_CONFIG_LOG="$BATS_TEST_TMPDIR/config.log"
    export FAKE_OP_ECHEC_MODELS=""
    export FAKE_OP_MUET_MODELS=""
    export FAKE_OP_FIGEE_MODELS=""
    export FAKE_OP_TEXTE_MODELS=""
    export FAKE_OP_ANCIEN_ERREUR_MODELS=""
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
        case " ${FAKE_OP_ANCIEN_ERREUR_MODELS:-} " in
            *" $modele "*)
                echo "Free usage limit"
                for _ in $(seq 1 40); do echo "ligne de sortie sans erreur"; done
                exit 1
                ;;
        esac
        case " ${FAKE_OP_ECHEC_MODELS:-} " in
            *" $modele "*)
                echo "Error: Free usage limit" >&2
                exit 1
                ;;
        esac
        case " ${FAKE_OP_MUET_MODELS:-} " in
            *" $modele "*)
                sleep "${FAKE_OP_DUREE:-30}"
                exit 0
                ;;
        esac
        case " ${FAKE_OP_TEXTE_MODELS:-} " in
            *" $modele "*) echo "extrait de code : Free usage limit (exemple)" ;;
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

@test "agent : appelant sans git push -> accepté, deny fourni par devzone" {
    consigne
    export OPENCODE_CONFIG_CONTENT='{"permission":{"bash":{"*":"ask"}}}'
    run bash "$DEVZONE" agent "$DEVZONE_RACINE/workspace/projet" "$DEVZONE_RACINE/workspace/consigne.txt"
    [ "$status" -eq 0 ]
    [ -s "$FAKE_OP_LOG" ]
    jq -e '.permission.bash["git push*"] == "deny"' "$FAKE_OP_CONFIG_LOG"
}

@test "agent : appelant avec * allow -> les deny de devzone restent et gagnent" {
    consigne
    export OPENCODE_CONFIG_CONTENT='{"permission":{"bash":{"*":"allow"}}}'
    run bash "$DEVZONE" agent "$DEVZONE_RACINE/workspace/projet" "$DEVZONE_RACINE/workspace/consigne.txt"
    [ "$status" -eq 0 ]
    for r in 'git push*' 'gh api*' 'repowarden ticket nouveau*' 'git checkout*' 'git reset*' 'git restore*' 'git stash*' 'git clean*' 'git branch -D*' 'repowarden proteger*' 'repowarden run*'; do
        jq -e --arg r "$r" '.permission.bash[$r] == "deny"' "$FAKE_OP_CONFIG_LOG" || { echo "deny perdu : $r"; false; }
    done
    jq -e '.permission.bash["*"] == "allow"' "$FAKE_OP_CONFIG_LOG"
    jq -e '(.permission.bash | keys_unsorted | index("*")) < (.permission.bash | keys_unsorted | index("git push*"))' "$FAKE_OP_CONFIG_LOG"
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

@test "agent : Free usage limit dans le code affiche, fin normale -> fin avec" {
    consigne
    export FAKE_OP_TEXTE_MODELS="big-pickle"
    run bash "$DEVZONE" agent "$DEVZONE_RACINE/workspace/projet" "$DEVZONE_RACINE/workspace/consigne.txt"
    [ "$status" -eq 0 ]
    [ "$(grep -c . "$FAKE_OP_LOG")" -eq 1 ]
    grep -q "fin avec opencode/big-pickle" "$DEVZONE_RACINE/workspace/.agents/projet.log" || false
    ! grep -q "refusé" "$DEVZONE_RACINE/workspace/.agents/projet.log" || false
}

@test "agent : erreur ancienne hors des 30 dernieres lignes -> arrete en erreur, pas refus" {
    consigne
    export FAKE_OP_ANCIEN_ERREUR_MODELS="big-pickle"
    run bash "$DEVZONE" agent "$DEVZONE_RACINE/workspace/projet" "$DEVZONE_RACINE/workspace/consigne.txt"
    [ "$status" -eq 0 ]
    [ "$(grep -c . "$FAKE_OP_LOG")" -eq 2 ]
    grep -q "arrêté en erreur (code 1)" "$DEVZONE_RACINE/workspace/.agents/projet.log" || false
    ! grep -q "refusé" "$DEVZONE_RACINE/workspace/.agents/projet.log" || false
}

@test "agent : silence au depart -> modele ecarte une heure, modele suivant" {
    consigne
    export FAKE_OP_MUET_MODELS="big-pickle"
    run bash "$DEVZONE" agent "$DEVZONE_RACINE/workspace/projet" "$DEVZONE_RACINE/workspace/consigne.txt"
    [ "$status" -eq 0 ]
    [ "$(grep -c . "$FAKE_OP_LOG")" -eq 2 ]
    [ -f "$HOME/.local/state/oc-lancer/muet-big-pickle" ]
    grep -q "muet au départ" "$DEVZONE_RACINE/workspace/.agents/projet.log" || false
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
    grep -q "figé" "$DEVZONE_RACINE/workspace/.agents/projet.log" || false
}

@test "agent : tous les modeles ecartes -> code 3" {
    consigne
    export FAKE_OP_ECHEC_MODELS="big-pickle deepseek-v4.1-flash-free glm-5.3-flash-free nemotron-3.5-super-vl-free nemotron-3.5-lightning-free mimo-v2.6-flash-free beam-free flint-40b-free nemotron-3-ultra-free"
    run bash "$DEVZONE" agent "$DEVZONE_RACINE/workspace/projet" "$DEVZONE_RACINE/workspace/consigne.txt"
    [ "$status" -eq 3 ]
    grep -q "aucun modèle gratuit disponible" "$DEVZONE_RACINE/workspace/.agents/projet.log" || false
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
    [[ "$output" == *"modèle glm-5.3-flash-free écarté jusqu'à"* ]] || false
}

@test "agent : ia désactivé → refuse de lancer, code 2, message pour l'activer" {
    bash "$DEVZONE" desactiver ia
    run bash "$DEVZONE" agent "$DEVZONE_RACINE/workspace/projet" "$DEVZONE_RACINE/workspace/consigne.txt"
    [ "$status" -eq 2 ]
    [[ "$output" == *"devzone activer ia"* ]] || false
}

@test "agent : etat n'affiche que les écarts en cours, avec leur heure de fin" {
    mkdir -p "$HOME/.local/state/oc-lancer"
    maintenant="$(date +%s)"
    echo $(( maintenant - 600 )) >"$HOME/.local/state/oc-lancer/muet-big-pickle"
    echo $(( maintenant - 7200 )) >"$HOME/.local/state/oc-lancer/muet-deepseek-v4.1-flash-free"
    run bash "$DEVZONE" agent etat
    [ "$status" -eq 0 ]
    [[ "$output" == *"modèle big-pickle écarté jusqu'à"* ]] || false
    [[ "$output" != *"deepseek-v4.1-flash-free"* ]] || false
}
