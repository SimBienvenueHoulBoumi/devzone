#!/usr/bin/env bash
# Machine output of devzone agent etat (--json): sessions, exclusions, rights alerts.
# Keys (schema, sessions, ecarts, fin, alertes_droits...) and values are a public
# format: they keep their French names.
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

# UTC ISO-8601 date of an epoch, GNU then BSD date: the fin field of the exclusions.
iso() {
    if date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' >/dev/null 2>&1; then
        date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'
    else
        date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ'
    fi
}

# Agent state in JSON: reuses the data of agent_state, agent_exclusions and
# droits_alertes, without copying their logic.
agent_state_json() {
    local sessions_json='[]' exclusions_json='[]' alerts_json='[]'
    local f journal model start last project running name
    local e cause d end end_iso now

    for f in "$RACINE"/workspace/.agents/*.log; do
        [ -e "$f" ] || continue
        journal="$(basename "$f")"
        session_model_start "$f"
        session_request "$f"
        model="$MODEL_SESSION"
        [ -n "$model" ] || model="inconnu"
        start="$START_SESSION"
        last="$(utc_time "$(mtime "$f")")"
        project="${journal%.log}"
        running=false
        if session_running "$project"; then running=true; fi
        sessions_json="$(jq -c \
            --arg journal "$journal" \
            --arg model "$model" \
            --arg start "$start" \
            --arg last "$last" \
            --arg request "$REQUEST_SESSION" \
            --argjson running "$running" \
            '. + [{journal:$journal,modele:$model,debut:(if $start=="" then null else $start end),dernier_ecrit:(if $last=="" then null else $last end),demande:(if $request=="" then null else $request end),en_cours:$running}]' \
            <<<"$sessions_json")"
    done

    now="$(date +%s)"
    for f in "$AGENT_ETAT"/ecart-*; do
        [ -e "$f" ] || continue
        model="${f##*/ecart-}"
        read -r e cause d <<<"$(cat "$f" 2>/dev/null || true)"
        [ -n "$e" ] || continue
        end=$(( e + ${d:-3600} ))
        [ "$now" -lt "$end" ] || continue
        end_iso="$(iso "$end")"
        exclusions_json="$(jq -c \
            --arg modele "$model" \
            --arg cause "${cause:-autre}" \
            --arg fin "$end_iso" \
            '. + [{modele:$modele,cause:$cause,fin:$fin}]' \
            <<<"$exclusions_json")"
    done
    for f in "$AGENT_ETAT"/muet-*; do
        [ -e "$f" ] || continue
        model="${f##*/muet-}"
        e="$(cat "$f" 2>/dev/null || true)"
        [ -n "$e" ] || continue
        end=$(( e + 3600 ))
        [ "$now" -lt "$end" ] || continue
        end_iso="$(iso "$end")"
        exclusions_json="$(jq -c \
            --arg modele "$model" \
            --arg cause "muet" \
            --arg fin "$end_iso" \
            '. + [{modele:$modele,cause:$cause,fin:$fin}]' \
            <<<"$exclusions_json")"
    done

    for f in "$AGENT_ETAT"/droits-*.alerte; do
        [ -e "$f" ] || continue
        name="${f##*/droits-}"
        name="${name%.alerte}"
        alerts_json="$(jq -c --arg n "$name" '. + [$n]' <<<"$alerts_json")"
    done

    jq -n \
        --argjson schema 1 \
        --argjson sessions "$sessions_json" \
        --argjson ecarts "$exclusions_json" \
        --argjson alertes "$alerts_json" \
        '{schema:$schema,sessions:$sessions,ecarts:$ecarts,alertes_droits:$alertes}'
}

agent_state_json
