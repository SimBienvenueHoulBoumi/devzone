#!/usr/bin/env bash
# shellcheck disable=SC2034
# Écarts de modèles et attente du réseau du superviseur d'agent (#328).
# Bibliothèque sourcée par agent.sh : aucune commande n'est lancée ici.

# Textes d'erreur opencode reconnus (grep -E) ; erreur_cause en tire la cause.
ERREURS='not available in your country|Free usage limit|content filter|Model is unavailable|Upstream request failed|ProviderHeaderTimeout|ENOTFOUND|ECONNREFUSED|ETIMEDOUT|EAI_AGAIN|ECONNRESET|fetch failed|network'
LIGNE_ERREUR='(^|[[:space:]])(Error|ERROR|Erreur):'

# Cause d'un échec : pays (durable), quota, filtre, reseau (aucun écart) ou autre.
erreur_cause() {
    local t="$1"
    case "$t" in
        *"not available in your country"*) echo "pays" ;;
        *"Free usage limit"*) echo "quota" ;;
        *"content filter"*) echo "filtre" ;;
        *"ENOTFOUND"* | *"ECONNREFUSED"* | *"ETIMEDOUT"* | *"EAI_AGAIN"* | *"ECONNRESET"* | *"fetch failed"* | *"network"*)
            echo "reseau" ;;
        *) echo "autre" ;;
    esac
}

# Durée d'un écart en secondes : pays 7 jours (DEVZONE_AGENT_ECART_PAYS), les autres 1 h.
ecart_duree() {
    case "$1" in
        pays) echo "${DEVZONE_AGENT_ECART_PAYS:-604800}" ;;
        *) echo 3600 ;;
    esac
}

# Durée lisible d'un écart pour le journal : « 7 j », « 1 h » ou « 30 s ».
ecart_libelle() {
    local d
    d="$(ecart_duree "$1")"
    if [ "$d" -ge 86400 ]; then
        echo "$(( d / 86400 )) j"
    elif [ "$d" -ge 3600 ]; then
        echo "$(( d / 3600 )) h"
    else
        echo "${d} s"
    fi
}

# Écrit l'écart du modèle : « <début> <cause> <durée> » dans $AGENT_ETAT/ecart-<modèle>.
modele_ecarter() {
    printf '%s %s %s\n' "$(date +%s)" "$2" "$(ecart_duree "$2")" >"$AGENT_ETAT/ecart-$1"
}

# Vaut 0 si le modèle est écarté en ce moment. Lit aussi l'ancien format muet-<modèle>
# (horodatage seul, durée 1 h).
modele_ecarte() {
    local f e cause d
    f="$AGENT_ETAT/ecart-$1"
    if [ ! -f "$f" ]; then f="$AGENT_ETAT/muet-$1"; fi
    if [ ! -f "$f" ]; then return 1; fi
    read -r e cause d <<<"$(cat "$f")"
    [ "$(date +%s)" -lt $(( e + ${d:-3600} )) ]
}

# Vaut 0 si opencode.ai se résout et répond en HTTPS : un seul essai, sans attente.
reseau_joignable() {
    getent hosts opencode.ai >/dev/null 2>&1 && curl -sI --max-time 5 https://opencode.ai >/dev/null 2>&1
}

# Attend le retour du réseau : essai toutes les DEVZONE_AGENT_RESEAU_PAS s, pendant
# DEVZONE_AGENT_RESEAU_MAX s au plus. Rend 0 au retour.
reseau_attendre() {
    local fin
    fin=$(( $(date +%s) + ${DEVZONE_AGENT_RESEAU_MAX:-1800} ))
    echo "=== réseau coupé, attente" >>"$AGENT_JOURNAL"
    while [ "$(date +%s)" -lt "$fin" ]; do
        if reseau_joignable; then
            echo "=== réseau revenu" >>"$AGENT_JOURNAL"
            return 0
        fi
        sleep "${DEVZONE_AGENT_RESEAU_PAS:-30}"
    done
    return 1
}

# Liste les écarts en cours pour devzone agent etat (muet- aussi, sans cause).
agent_ecarts() {
    local f m e cause d fin maintenant
    maintenant="$(date +%s)"
    for f in "$AGENT_ETAT"/ecart-*; do
        [ -e "$f" ] || continue
        m="${f##*/ecart-}"
        read -r e cause d <<<"$(cat "$f")"
        fin=$(( e + ${d:-3600} ))
        [ "$maintenant" -lt "$fin" ] || continue
        echo "  modèle $m écarté ($cause) jusqu'à $(heure "$fin")"
    done
    for f in "$AGENT_ETAT"/muet-*; do
        [ -e "$f" ] || continue
        m="${f##*/muet-}"
        e="$(cat "$f" 2>/dev/null || true)"
        [ -n "$e" ] || continue
        fin=$(( e + 3600 ))
        [ "$maintenant" -lt "$fin" ] || continue
        echo "  modèle $m écarté (muet) jusqu'à $(heure "$fin")"
    done
}

# Lève l'écart d'un modèle, ou de tous (--tous) : devzone agent liberer.
ecart_liberer() {
    case "$1" in
        --tous) rm -f "$AGENT_ETAT"/ecart-* "$AGENT_ETAT"/muet-* ;;
        *) rm -f "$AGENT_ETAT/ecart-$1" "$AGENT_ETAT/muet-$1" ;;
    esac
}

# Arrête la session en cours si le journal contient quota, pays ou filtre depuis
# son début : le modèle est écarté et la session est tuée (processus et enfants).
session_erreur_fatale() {
    local pid="$1" journal="$2" offset="$3" m="$4" dossier="$5"
    local sortie cause
    sortie="$(tail -c "+$(( offset + 1 ))" "$journal" 2>/dev/null || true)"
    cause="$(erreur_cause "$sortie")"
    case "$cause" in
        quota | pays | filtre) ;;
        *) return 1 ;;
    esac
    pkill -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    droits_verifier "$dossier"
    modele_ecarter "$m" "$cause"
    printf '%s\n' "=== opencode/$m écarté ($cause) : modèle suivant" >>"$journal"
    return 0
}
