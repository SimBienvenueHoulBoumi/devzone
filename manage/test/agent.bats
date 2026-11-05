#!/usr/bin/env bats
# Commande devzone agent : supervise opencode diriger une consigne (tickets #221, #328).
# Faux opencode dans le PATH : succès, erreurs (quota, pays, filtre, réseau),
# silence au départ, session figée. Faux getent et curl : réseau coupé puis revenu.
# Les délais sont réduits par les variables DEVZONE_AGENT_*.

setup() {
    load commun
    relais_docker_isole
    kube_isole
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin"
    cd "$BATS_TEST_TMPDIR" || return 1
    export GIT_CONFIG_NOSYSTEM=1
    export DEVZONE_RACINE="$BATS_TEST_TMPDIR/racine"
    mkdir -p "$DEVZONE_RACINE/workspace"
    export DEVZONE_AGENT_ETAT="$BATS_TEST_TMPDIR/etat"
    export RESEAU_COUPE="$BATS_TEST_TMPDIR/reseau.coupe"
    export DEVZONE_AGENT_RESEAU_PAS=1
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
    # Faux getent : échoue tant que $RESEAU_COUPE existe, son nombre donnant les essais ratés
    cat >"$BATS_TEST_TMPDIR/bin/getent" <<'GETENT'
#!/usr/bin/env bash
f="${RESEAU_COUPE:?}"
[ -f "$f" ] || exit 0
n="$(cat "$f")"
if [ "$n" -le 1 ]; then rm -f "$f"; else echo $(( n - 1 )) >"$f"; fi
exit 2
GETENT
    printf '#!/usr/bin/env bash\nexit 0\n' >"$BATS_TEST_TMPDIR/bin/curl"
    chmod +x "$BATS_TEST_TMPDIR/bin/npm" "$BATS_TEST_TMPDIR/bin/getent" "$BATS_TEST_TMPDIR/bin/curl"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    bash "$DEVZONE" activer ia >/dev/null 2>&1 || true
    export FAKE_OP_LOG="$BATS_TEST_TMPDIR/opencode.log"
    export FAKE_OP_CONSIGNE_LOG="$BATS_TEST_TMPDIR/consignes.log"
    export FAKE_OP_CONFIG_LOG="$BATS_TEST_TMPDIR/config.log"
    export FAKE_OP_ECHEC_MODELS=""
    export FAKE_OP_MESSAGE=""
    export FAKE_OP_RESEAU_MODELS=""
    export FAKE_OP_MUET_MODELS=""
    export FAKE_OP_FIGEE_MODELS=""
    export FAKE_OP_TEXTE_MODELS=""
    export FAKE_OP_ANCIEN_ERREUR_MODELS=""
    export FAKE_OP_DUREE=30
    export DEVZONE_AGENT_SILENCE=3
    export DEVZONE_AGENT_FIGEE=5
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
                echo "Error: ${FAKE_OP_MESSAGE:-Free usage limit}" >&2
                exit 1
                ;;
        esac
        case " ${FAKE_OP_RESEAU_MODELS:-} " in
            *" $modele "*)
                if [ -f "${RESEAU_COUPE:?}" ]; then
                    echo "Error: ENOTFOUND opencode.ai" >&2
                    exit 1
                fi
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

agent() {
    run bash "$DEVZONE" agent "$DEVZONE_RACINE/workspace/projet" "$DEVZONE_RACINE/workspace/consigne.txt"
}

journal() {
    echo "$DEVZONE_RACINE/workspace/.agents/projet.log"
}

@test "agent : appelant sans git push -> accepté, deny fourni par devzone" {
    consigne
    export OPENCODE_CONFIG_CONTENT='{"permission":{"bash":{"*":"ask"}}}'
    agent
    [ "$status" -eq 0 ]
    [ -s "$FAKE_OP_LOG" ]
    jq -e '.permission.bash["git push*"] == "deny"' "$FAKE_OP_CONFIG_LOG"
}

@test "agent : appelant avec * allow -> les deny de devzone restent et gagnent" {
    consigne
    export OPENCODE_CONFIG_CONTENT='{"permission":{"bash":{"*":"allow"}}}'
    agent
    [ "$status" -eq 0 ]
    for r in 'git push*' 'gh api*' 'repowarden ticket nouveau*' 'git checkout*' 'git reset*' 'git restore*' 'git stash*' 'git clean*' 'git branch -D*' 'repowarden proteger*' 'repowarden run*'; do
        jq -e --arg r "$r" '.permission.bash[$r] == "deny"' "$FAKE_OP_CONFIG_LOG" || { echo "deny perdu : $r"; false; }
    done
    jq -e '.permission.bash["*"] == "allow"' "$FAKE_OP_CONFIG_LOG"
    jq -e '(.permission.bash | keys_unsorted | index("*")) < (.permission.bash | keys_unsorted | index("git push*"))' "$FAKE_OP_CONFIG_LOG"
}

@test "agent : lance opencode sur la consigne, journal ecrit, fin de session" {
    consigne
    agent
    [ "$status" -eq 0 ]
    [ -f "$(journal)" ]
    grep -q "fin avec opencode/" "$(journal)" || false
    grep -qx "big-pickle" "$FAKE_OP_LOG" || false
    grep -q "construis la feature" "$FAKE_OP_CONSIGNE_LOG" || false
}

@test "agent : quota epuisee -> modele ecarte 1 h (quota), modele suivant" {
    consigne
    export FAKE_OP_ECHEC_MODELS="big-pickle"
    agent
    [ "$status" -eq 0 ]
    [ "$(grep -c . "$FAKE_OP_LOG")" -eq 2 ]
    [ "$(sed -n '1p' "$FAKE_OP_LOG")" = "big-pickle" ]
    [ "$(sed -n '2p' "$FAKE_OP_LOG")" = "deepseek-v4.1-flash-free" ]
    grep -q "^[0-9]* quota 3600$" "$DEVZONE_AGENT_ETAT/ecart-big-pickle" || false
    grep -q "Free usage limit" "$(journal)" || false
}

@test "agent : pays non disponible -> modele ecarte 7 jours, modele suivant" {
    consigne
    export FAKE_OP_ECHEC_MODELS="big-pickle"
    export FAKE_OP_MESSAGE="not available in your country"
    agent
    [ "$status" -eq 0 ]
    [ "$(grep -c . "$FAKE_OP_LOG")" -eq 2 ]
    [ "$(sed -n '2p' "$FAKE_OP_LOG")" = "deepseek-v4.1-flash-free" ]
    grep -q "^[0-9]* pays 604800$" "$DEVZONE_AGENT_ETAT/ecart-big-pickle" || false
    grep -q "écarté (pays, 7 j)" "$(journal)" || false
}

@test "agent : filtre de contenu -> modele ecarte 1 h (filtre), modele suivant" {
    consigne
    export FAKE_OP_ECHEC_MODELS="big-pickle"
    export FAKE_OP_MESSAGE="content filter"
    agent
    [ "$status" -eq 0 ]
    [ "$(sed -n '2p' "$FAKE_OP_LOG")" = "deepseek-v4.1-flash-free" ]
    grep -q "^[0-9]* filtre 3600$" "$DEVZONE_AGENT_ETAT/ecart-big-pickle" || false
}

@test "agent : erreur sans cause connue -> modele suivant, sans ecart" {
    consigne
    export FAKE_OP_ECHEC_MODELS="big-pickle"
    export FAKE_OP_MESSAGE="Model is unavailable"
    agent
    [ "$status" -eq 0 ]
    [ "$(sed -n '2p' "$FAKE_OP_LOG")" = "deepseek-v4.1-flash-free" ]
    [ ! -f "$DEVZONE_AGENT_ETAT/ecart-big-pickle" ]
    grep -q "sans écart" "$(journal)" || false
}

@test "agent : ENOTFOUND puis reseau revenu -> meme modele relance, aucun ecart" {
    consigne
    export FAKE_OP_RESEAU_MODELS="big-pickle"
    echo 2 >"$RESEAU_COUPE"
    agent
    [ "$status" -eq 0 ]
    [ "$(grep -c . "$FAKE_OP_LOG")" -eq 2 ]
    [ "$(sed -n '1p' "$FAKE_OP_LOG")" = "big-pickle" ]
    [ "$(sed -n '2p' "$FAKE_OP_LOG")" = "big-pickle" ]
    grep -q "réseau coupé, attente" "$(journal)" || false
    grep -q "réseau revenu" "$(journal)" || false
    grep -q "fin avec opencode/big-pickle" "$(journal)" || false
    grep -q "REPRISE" "$FAKE_OP_CONSIGNE_LOG" || false
    [ ! -f "$DEVZONE_AGENT_ETAT/ecart-big-pickle" ]
}

@test "agent : reseau jamais revenu -> code 4 reseau indisponible, sans ecart" {
    consigne
    export FAKE_OP_RESEAU_MODELS="big-pickle"
    echo 1000000 >"$RESEAU_COUPE"
    export DEVZONE_AGENT_RESEAU_MAX=2
    agent
    [ "$status" -eq 4 ]
    grep -q "réseau indisponible" "$(journal)" || false
    ! grep -q "aucun modèle gratuit" "$(journal)" || false
    [ "$(grep -c . "$FAKE_OP_LOG")" -eq 1 ]
    [ ! -f "$DEVZONE_AGENT_ETAT/ecart-big-pickle" ]
}

@test "agent : erreur ancienne hors des 30 dernieres lignes -> arrete en erreur, pas refus" {
    consigne
    export FAKE_OP_ANCIEN_ERREUR_MODELS="big-pickle"
    agent
    [ "$status" -eq 0 ]
    [ "$(grep -c . "$FAKE_OP_LOG")" -eq 2 ]
    grep -q "arrêté en erreur (code 1)" "$(journal)" || false
    ! grep -q "écarté" "$(journal)" || false
}

@test "agent : Free usage limit dans le code affiche, fin normale -> fin avec" {
    consigne
    export FAKE_OP_TEXTE_MODELS="big-pickle"
    agent
    [ "$status" -eq 0 ]
    [ "$(grep -c . "$FAKE_OP_LOG")" -eq 1 ]
    grep -q "fin avec opencode/big-pickle" "$(journal)" || false
    ! grep -q "écarté" "$(journal)" || false
}

@test "agent : silence au depart -> modele ecarte une heure (mute), modele suivant" {
    consigne
    export FAKE_OP_MUET_MODELS="big-pickle"
    agent
    [ "$status" -eq 0 ]
    [ "$(grep -c . "$FAKE_OP_LOG")" -eq 2 ]
    grep -q "^[0-9]* mute 3600$" "$DEVZONE_AGENT_ETAT/ecart-big-pickle" || false
    grep -q "muet au départ" "$(journal)" || false
}

@test "agent : ancien fichier muet- encore pris en compte pendant 1 h" {
    consigne
    mkdir -p "$DEVZONE_AGENT_ETAT"
    date +%s >"$DEVZONE_AGENT_ETAT/muet-big-pickle"
    agent
    [ "$status" -eq 0 ]
    [ "$(sed -n '1p' "$FAKE_OP_LOG")" = "deepseek-v4.1-flash-free" ]
}

@test "agent : session figee -> relancee, consigne de reprise" {
    consigne
    export FAKE_OP_FIGEE_MODELS="big-pickle"
    agent
    [ "$status" -eq 0 ]
    [ "$(grep -c . "$FAKE_OP_LOG")" -eq 2 ]
    [ "$(sed -n '2p' "$FAKE_OP_LOG")" = "deepseek-v4.1-flash-free" ]
    grep -q "REPRISE" "$FAKE_OP_CONSIGNE_LOG" || false
    grep -q "git log" "$FAKE_OP_CONSIGNE_LOG" || false
    grep -q "figé" "$(journal)" || false
}

@test "agent : tous les modeles ecartes -> code 3" {
    consigne
    export FAKE_OP_ECHEC_MODELS="big-pickle deepseek-v4.1-flash-free glm-5.3-flash-free nemotron-3.5-super-vl-free nemotron-3.5-lightning-free mimo-v2.6-flash-free beam-free flint-40b-free nemotron-3-ultra-free"
    agent
    [ "$status" -eq 3 ]
    grep -q "aucun modèle gratuit disponible" "$(journal)" || false
}

@test "agent : deux lancements -> deux modeles differents" {
    consigne
    agent
    [ "$status" -eq 0 ]
    agent
    [ "$status" -eq 0 ]
    [ "$(grep -c . "$FAKE_OP_LOG")" -eq 2 ]
    [ "$(sed -n '1p' "$FAKE_OP_LOG")" != "$(sed -n '2p' "$FAKE_OP_LOG")" ]
}

@test "agent : configuration fournie completee (git commit permis, bash32 protege)" {
    consigne
    export OPENCODE_CONFIG_CONTENT='{"permission":{"bash":{"*":"ask","git push*":"deny"}}}'
    agent
    [ "$status" -eq 0 ]
    grep -q '"git commit\*":"allow"' "$FAKE_OP_CONFIG_LOG" || false
    grep -q '"ln \*bash32\*":"deny"' "$FAKE_OP_CONFIG_LOG" || false
    grep -q '"git push\*":"deny"' "$FAKE_OP_CONFIG_LOG" || false
}

@test "agent : etat liste la session, le modele ecarte et sa cause" {
    consigne
    agent
    [ "$status" -eq 0 ]
    echo "$(date +%s) pays 604800" >"$DEVZONE_AGENT_ETAT/ecart-big-pickle"
    echo "$(date +%s) quota 3600" >"$DEVZONE_AGENT_ETAT/ecart-glm-5.3-flash-free"
    run bash "$DEVZONE" agent etat
    [ "$status" -eq 0 ]
    [[ "$output" == *"projet.log"* ]] || false
    [[ "$output" == *"opencode/big-pickle"* ]] || false
    [[ "$output" == *"modèle big-pickle écarté (pays) jusqu'à"* ]] || false
    [[ "$output" == *"modèle glm-5.3-flash-free écarté (quota) jusqu'à"* ]] || false
}

@test "agent : liberer leve l'ecart d'un modele, --tous leve tout, sans argument refuse" {
    mkdir -p "$DEVZONE_AGENT_ETAT"
    echo "$(date +%s) pays 604800" >"$DEVZONE_AGENT_ETAT/ecart-big-pickle"
    echo "$(date +%s) quota 3600" >"$DEVZONE_AGENT_ETAT/ecart-glm-5.3-flash-free"
    run bash "$DEVZONE" agent liberer
    [ "$status" -eq 2 ]
    run bash "$DEVZONE" agent liberer big-pickle
    [ "$status" -eq 0 ]
    [ ! -f "$DEVZONE_AGENT_ETAT/ecart-big-pickle" ]
    [ -f "$DEVZONE_AGENT_ETAT/ecart-glm-5.3-flash-free" ]
    run bash "$DEVZONE" agent liberer --tous
    [ "$status" -eq 0 ]
    [ ! -f "$DEVZONE_AGENT_ETAT/ecart-glm-5.3-flash-free" ]
}

@test "agent : ia désactivé → refuse de lancer, code 2, message pour l'activer" {
    bash "$DEVZONE" desactiver ia
    agent
    [ "$status" -eq 2 ]
    [[ "$output" == *"devzone activer ia"* ]] || false
}

@test "agent : etat n'affiche que les écarts en cours, avec leur heure de fin" {
    mkdir -p "$DEVZONE_AGENT_ETAT"
    maintenant="$(date +%s)"
    echo $(( maintenant - 600 )) >"$DEVZONE_AGENT_ETAT/muet-big-pickle"
    echo $(( maintenant - 7200 )) >"$DEVZONE_AGENT_ETAT/muet-deepseek-v4.1-flash-free"
    run bash "$DEVZONE" agent etat
    [ "$status" -eq 0 ]
    [[ "$output" == *"modèle big-pickle écarté (muet) jusqu'à"* ]] || false
    [[ "$output" != *"deepseek-v4.1-flash-free"* ]] || false
}

@test "agent : erreur_cause classe pays, quota, filtre, reseau et autre" {
    run bash -c '. "$1"; for t in "not available in your country" "Free usage limit" "content filter" ECONNREFUSED ENOTFOUND ETIMEDOUT "Model is unavailable"; do erreur_cause "$t"; done' _ "$BATS_TEST_DIRNAME/../../.devcontainer/agent-erreurs.sh"
    [ "$output" = $'pays\nquota\nfiltre\nreseau\nreseau\nreseau\nautre' ]
}
