#!/usr/bin/env bash
# Sortie machine de devzone agent etat (--json) : sessions, écarts, alertes droits.
set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    case "$SOURCE" in
        /*) ;;
        *) SOURCE="$DIR/$SOURCE" ;;
    esac
done
ICI="$(cd -P "$(dirname "$SOURCE")" && pwd)"
RACINE="${DEVZONE_RACINE:-$(dirname "$ICI")}"

# shellcheck source=agent-erreurs.sh
# shellcheck disable=SC1091
. "$ICI/agent-erreurs.sh"
# shellcheck source=agent-droits.sh
# shellcheck disable=SC1091
. "$ICI/agent-droits.sh"
# shellcheck source=agent-session.sh
# shellcheck disable=SC1091
. "$ICI/agent-session.sh"

AGENT_ETAT="${DEVZONE_AGENT_ETAT:-$HOME/.local/state/oc-lancer}"

# Date UTC ISO-8601 d'une époque, GNU puis BSD date : champ `fin` des écarts.
iso() {
    if date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' >/dev/null 2>&1; then
        date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'
    else
        date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ'
    fi
}

# État des sessions d'agent en JSON : réutilise les données d'agent_etat,
# agent_ecarts et droits_alertes, sans recopier leur logique.
agent_etat_json() {
    local sessions_json='[]' ecarts_json='[]' alertes_json='[]'
    local f journal modele debut dernier project en_cours
    local e cause d fin fin_iso maintenant

    for f in "$RACINE"/workspace/.agents/*.log; do
        [ -e "$f" ] || continue
        journal="$(basename "$f")"
        session_modele_debut "$f"
        modele="$MODELE_SESSION"
        [ -n "$modele" ] || modele="inconnu"
        debut="$DEBUT_SESSION"
        dernier="$(heure "$(mtime "$f")")"
        project="${journal%.log}"
        en_cours=false
        if session_en_cours "$project"; then en_cours=true; fi
        sessions_json="$(jq -c \
            --arg journal "$journal" \
            --arg modele "$modele" \
            --arg debut "$debut" \
            --arg dernier "$dernier" \
            --argjson en_cours "$en_cours" \
            '. + [{journal:$journal,modele:$modele,debut:(if $debut=="" then null else $debut end),dernier_ecrit:(if $dernier=="" then null else $dernier end),en_cours:$en_cours}]' \
            <<<"$sessions_json")"
    done

    maintenant="$(date +%s)"
    for f in "$AGENT_ETAT"/ecart-*; do
        [ -e "$f" ] || continue
        modele="${f##*/ecart-}"
        read -r e cause d <<<"$(cat "$f" 2>/dev/null || true)"
        [ -n "$e" ] || continue
        fin=$(( e + ${d:-3600} ))
        [ "$maintenant" -lt "$fin" ] || continue
        fin_iso="$(iso "$fin")"
        ecarts_json="$(jq -c \
            --arg modele "$modele" \
            --arg cause "${cause:-autre}" \
            --arg fin "$fin_iso" \
            '. + [{modele:$modele,cause:$cause,fin:$fin}]' \
            <<<"$ecarts_json")"
    done
    for f in "$AGENT_ETAT"/muet-*; do
        [ -e "$f" ] || continue
        modele="${f##*/muet-}"
        e="$(cat "$f" 2>/dev/null || true)"
        [ -n "$e" ] || continue
        fin=$(( e + 3600 ))
        [ "$maintenant" -lt "$fin" ] || continue
        fin_iso="$(iso "$fin")"
        ecarts_json="$(jq -c \
            --arg modele "$modele" \
            --arg cause "muet" \
            --arg fin "$fin_iso" \
            '. + [{modele:$modele,cause:$cause,fin:$fin}]' \
            <<<"$ecarts_json")"
    done

    for f in "$AGENT_ETAT"/droits-*.alerte; do
        [ -e "$f" ] || continue
        name="${f##*/droits-}"
        name="${name%.alerte}"
        alertes_json="$(jq -c --arg n "$name" '. + [$n]' <<<"$alertes_json")"
    done

    jq -n \
        --argjson schema 1 \
        --argjson sessions "$sessions_json" \
        --argjson ecarts "$ecarts_json" \
        --argjson alertes "$alertes_json" \
        '{schema:$schema,sessions:$sessions,ecarts:$ecarts,alertes_droits:$alertes}'
}

agent_etat_json
