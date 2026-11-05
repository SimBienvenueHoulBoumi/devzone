#!/usr/bin/env bats
# Commande devzone agent : écarts selon la cause, attente du réseau, état et
# liberer (#328). Les lancements, la rotation et la reprise sont dans agent.bats.

setup() {
    load commun
    agent_isole
}

@test "agent : quota epuisee -> modele ecarte 1 h (quota), modele suivant" {
    agent_consigne
    export FAKE_OP_ECHEC_MODELS="big-pickle"
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(grep -c . "$FAKE_OP_LOG")" -eq 2 ]
    [ "$(sed -n '1p' "$FAKE_OP_LOG")" = "big-pickle" ]
    [ "$(sed -n '2p' "$FAKE_OP_LOG")" = "deepseek-v4.1-flash-free" ]
    grep -q "^[0-9]* quota 3600$" "$DEVZONE_AGENT_ETAT/ecart-big-pickle" || false
    grep -q "Free usage limit" "$(agent_journal)" || false
}

@test "agent : pays non disponible -> modele ecarte 7 jours, modele suivant" {
    agent_consigne
    export FAKE_OP_ECHEC_MODELS="big-pickle"
    export FAKE_OP_MESSAGE="not available in your country"
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(grep -c . "$FAKE_OP_LOG")" -eq 2 ]
    [ "$(sed -n '2p' "$FAKE_OP_LOG")" = "deepseek-v4.1-flash-free" ]
    grep -q "^[0-9]* pays 604800$" "$DEVZONE_AGENT_ETAT/ecart-big-pickle" || false
    grep -q "écarté (pays, 7 j)" "$(agent_journal)" || false
}

@test "agent : filtre de contenu -> modele ecarte 1 h (filtre), modele suivant" {
    agent_consigne
    export FAKE_OP_ECHEC_MODELS="big-pickle"
    export FAKE_OP_MESSAGE="content filter"
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(sed -n '2p' "$FAKE_OP_LOG")" = "deepseek-v4.1-flash-free" ]
    grep -q "^[0-9]* filtre 3600$" "$DEVZONE_AGENT_ETAT/ecart-big-pickle" || false
}

@test "agent : erreur sans cause connue -> modele suivant, sans ecart" {
    agent_consigne
    export FAKE_OP_ECHEC_MODELS="big-pickle"
    export FAKE_OP_MESSAGE="Model is unavailable"
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(sed -n '2p' "$FAKE_OP_LOG")" = "deepseek-v4.1-flash-free" ]
    [ ! -f "$DEVZONE_AGENT_ETAT/ecart-big-pickle" ]
    grep -q "sans écart" "$(agent_journal)" || false
}

@test "agent : mot network mais reseau joignable -> traite comme autre, pas de boucle" {
    agent_consigne
    export FAKE_OP_ECHEC_MODELS="big-pickle"
    export FAKE_OP_MESSAGE="network down"
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(grep -c . "$FAKE_OP_LOG")" -eq 2 ]
    [ "$(sed -n '2p' "$FAKE_OP_LOG")" = "deepseek-v4.1-flash-free" ]
    grep -q "réseau joignable : traité comme autre" "$(agent_journal)" || false
    [ ! -f "$DEVZONE_AGENT_ETAT/ecart-big-pickle" ]
}

@test "agent : ENOTFOUND puis reseau revenu -> meme modele relance, aucun ecart" {
    agent_consigne
    export FAKE_OP_RESEAU_MODELS="big-pickle"
    echo 2 >"$RESEAU_COUPE"
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(grep -c . "$FAKE_OP_LOG")" -eq 2 ]
    [ "$(sed -n '1p' "$FAKE_OP_LOG")" = "big-pickle" ]
    [ "$(sed -n '2p' "$FAKE_OP_LOG")" = "big-pickle" ]
    grep -q "réseau coupé, attente" "$(agent_journal)" || false
    grep -q "réseau revenu" "$(agent_journal)" || false
    grep -q "fin avec opencode/big-pickle" "$(agent_journal)" || false
    grep -q "REPRISE" "$FAKE_OP_CONSIGNE_LOG" || false
    [ ! -f "$DEVZONE_AGENT_ETAT/ecart-big-pickle" ]
}

@test "agent : ENOTFOUND repete 4 fois, reseau revenu chaque fois -> 3 relances puis modele suivant" {
    agent_consigne
    export FAKE_OP_RESEAU_CHAQUE="big-pickle"
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(grep -c '^big-pickle$' "$FAKE_OP_LOG")" -eq 4 ]
    [ "$(sed -n '5p' "$FAKE_OP_LOG")" = "deepseek-v4.1-flash-free" ]
    grep -q "réseau coupé 3 fois : modèle suivant, sans écart" "$(agent_journal)" || false
    [ ! -f "$DEVZONE_AGENT_ETAT/ecart-big-pickle" ]
}

@test "agent : reseau jamais revenu -> code 4 reseau indisponible, sans ecart" {
    agent_consigne
    export FAKE_OP_RESEAU_MODELS="big-pickle"
    echo 1000000 >"$RESEAU_COUPE"
    export DEVZONE_AGENT_RESEAU_MAX=2
    agent_lance
    [ "$status" -eq 4 ]
    grep -q "réseau indisponible" "$(agent_journal)" || false
    ! grep -q "aucun modèle gratuit" "$(agent_journal)" || false
    [ "$(grep -c . "$FAKE_OP_LOG")" -eq 1 ]
    [ ! -f "$DEVZONE_AGENT_ETAT/ecart-big-pickle" ]
}

@test "agent : silence au depart -> modele ecarte une heure (mute), modele suivant" {
    agent_consigne
    export FAKE_OP_MUET_MODELS="big-pickle"
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(grep -c . "$FAKE_OP_LOG")" -eq 2 ]
    grep -q "^[0-9]* mute 3600$" "$DEVZONE_AGENT_ETAT/ecart-big-pickle" || false
    grep -q "muet au départ" "$(agent_journal)" || false
}

@test "agent : ancien fichier muet- encore pris en compte pendant 1 h" {
    agent_consigne
    mkdir -p "$DEVZONE_AGENT_ETAT"
    date +%s >"$DEVZONE_AGENT_ETAT/muet-big-pickle"
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(sed -n '1p' "$FAKE_OP_LOG")" = "deepseek-v4.1-flash-free" ]
}

@test "agent : etat liste la session, le modele ecarte et sa cause" {
    agent_consigne
    agent_lance
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

@test "agent : erreur_cause classe pays, quota, filtre, reseau et autre" {
    run bash -c '. "$1"; for t in "not available in your country" "Free usage limit" "content filter" ECONNREFUSED ENOTFOUND ETIMEDOUT "Model is unavailable"; do erreur_cause "$t"; done' _ "$BATS_TEST_DIRNAME/../../.devcontainer/agent-erreurs.sh"
    [ "$output" = $'pays\nquota\nfiltre\nreseau\nreseau\nreseau\nautre' ]
}
