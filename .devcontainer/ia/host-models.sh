#!/usr/bin/env bash
# Detection of the models served by Ollama on the host (#665, #668).
# devzone hosts no model: models live on the host (Ollama) and are detected here.
#   host-models.sh            list the detected model names, one per line
#   host-models.sh first      the model to use: DEVZONE_HOST_MODEL, else the best
#                             measured model, else a deterministic rule
#   host-models.sh set        merge the devzone-host provider into ~/.config/opencode/config.json
#   host-models.sh unset      remove the devzone-host provider from that file
#   host-models.sh check      update check of each model (delegates to host-check.sh)
#   host-models.sh rapport    report (delegates to host-check.sh)
# Default URL: http://host.docker.internal:11434, overridable with DEVZONE_OLLAMA_URL.
# Measurements: DEVZONE_IA_MESURES, else ~/.config/devzone/ia-mesures.json
# ({"<model>": {"reussite": 0..1, "tok_s": n, "date": "..."}}).
# Short timeout; exits 0 and writes nothing when Ollama does not answer.
# bash 3.2 (macOS). Code and comments in English.
set -euo pipefail

URL="${DEVZONE_OLLAMA_URL:-http://host.docker.internal:11434}"
URL="${URL%/}"
FILE="$HOME/.config/opencode/config.json"
MESURES="${DEVZONE_IA_MESURES:-$HOME/.config/devzone/ia-mesures.json}"

# True when a model is an embedding model (Ollama details.type, or a name
# containing "embed", case-insensitive).
is_embedding() {
    local low
    low="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$low" in
        *embed*) return 0 ;;
        *) return 1 ;;
    esac
}

# Raw /api/tags payload, empty when Ollama does not answer.
json_tags() {
    curl -fsS --max-time 3 "${URL}/api/tags" 2>/dev/null || return 0
}

# Prints the detected model names, one per line. Exits 0 and prints nothing
# when Ollama does not answer or the payload is not usable.
modeles() {
    local data
    data="$(json_tags)" || return 0
    [ -n "$data" ] || return 0
    # Ignore embedding models (Ollama details.type, or a name containing "embed").
    printf '%s' "$data" | jq -r '.models[] | select((.details.type // "") != "embedding") | .name' 2>/dev/null |
        while IFS= read -r name; do
            is_embedding "$name" || printf '%s\n' "$name"
        done || true
    return 0
}

# Prints the detected models as "name<TAB>size" (bytes), one per line.
tailles() {
    local data line name
    data="$(json_tags)" || return 0
    [ -n "$data" ] || return 0
    printf '%s' "$data" | jq -r '.models[] | select((.details.type // "") != "embedding") | "\(.name)\t\(.size // 0)"' 2>/dev/null |
        while IFS= read -r line; do
            name="${line%%$'\t'*}"
            is_embedding "$name" || printf '%s\n' "$line"
        done || true
    return 0
}

# Prints the detected models as "name<TAB>size<TAB>digest", one per line.
infos() {
    local data line name
    data="$(json_tags)" || return 0
    [ -n "$data" ] || return 0
    printf '%s' "$data" | jq -r '.models[] | select((.details.type // "") != "embedding") | "\(.name)\t\(.size // 0)\t\(.digest // "")"' 2>/dev/null |
        while IFS= read -r line; do
            name="${line%%$'\t'*}"
            is_embedding "$name" || printf '%s\n' "$line"
        done || true
    return 0
}

# Best measured model among the detected names ($1, one per line): highest
# reussite, then highest tok_s. Prints nothing when the file is absent, invalid
# or no detected model is measured.
mesure_choix() {
    local liste="$1" data
    [ -f "$MESURES" ] || return 0
    data="$(cat "$MESURES" 2>/dev/null)" || return 0
    [ -n "$data" ] || return 0
    printf '%s' "$data" | jq -r --arg liste "$liste" '
        ($liste | split("\n") | map(select(length > 0))) as $d
        | [to_entries[] | select(.key as $k | $d | index($k))]
        | sort_by([-(.value.reussite // 0), -(.value.tok_s // 0)])
        | .[0].key // empty
    ' 2>/dev/null || return 0
}

# Deterministic fallback: a name containing "coder" first, then the smallest
# size, then the name order.
regle_choix() {
    tailles | LC_ALL=C awk -F'\t' '
        {
            low = tolower($1)
            coder = (index(low, "coder") > 0) ? 0 : 1
            size = ($2 + 0)
            if (best == "" || coder < bc || (coder == bc && size < bs) || (coder == bc && size == bs && $1 < bn)) {
                best = $1
                bc = coder
                bs = size
                bn = $1
            }
        }
        END { if (best != "") print best }
    '
}

# The model to use among the detected names: DEVZONE_HOST_MODEL when set, else
# the best measured model, else the deterministic rule.
choix() {
    local liste="$1" nom mesure
    [ -n "$liste" ] || return 0
    nom="${DEVZONE_HOST_MODEL:-}"
    if [ -n "$nom" ]; then
        printf '%s\n' "$nom"
        return 0
    fi
    mesure="$(mesure_choix "$liste")" || true
    if [ -n "$mesure" ]; then
        printf '%s\n' "$mesure"
        return 0
    fi
    regle_choix
}

# The model to use. Empty when Ollama did not answer or no model was detected.
premier() {
    local liste
    liste="$(modeles)" || true
    [ -n "$liste" ] || return 0
    choix "$liste"
}

# jq program $1 applied to the file (or {}), written back atomically.
# The file is removed when nothing remains but the schema.
rewrite() {
    local current="{}" out
    [ ! -f "$FILE" ] || current="$(cat "$FILE")"
    mkdir -p "$(dirname "$FILE")"
    out="$(printf '%s' "$current" | jq "$1")" || {
        echo "devzone: host: $FILE is not valid JSON: provider not touched" >&2
        return 1
    }
    if [ "$(printf '%s' "$out" | jq -c 'del(."$schema") | length')" = 0 ]; then
        rm -f "$FILE"
    else
        printf '%s\n' "$out" >"$FILE.tmp" && mv "$FILE.tmp" "$FILE"
    fi
}

# Merges the devzone-host provider (the detected models) into the opencode
# configuration file, keeping everything else. Does nothing when no model was
# detected. baseURL = URL + /v1.
set_provider() {
    local liste current="{}" out models baseurl
    liste="$(modeles)" || return 0
    [ -n "$liste" ] || return 0
    baseurl="${URL%/}/v1"
    models="$(printf '%s\n' "$liste" | jq -R -n '([inputs | select(length > 0)] | map({(.): {name: .}})) | add // {}')" || return 1
    [ ! -f "$FILE" ] || current="$(cat "$FILE")"
    mkdir -p "$(dirname "$FILE")"
    out="$(printf '%s' "$current" | jq --arg baseurl "$baseurl" --argjson models "$models" '
        ."$schema" = (."$schema" // "https://opencode.ai/config.json")
        | .provider["devzone-host"] = {npm: "@ai-sdk/openai-compatible", name: "devzone host models (Ollama)", options: {baseURL: $baseurl}, models: $models}
    ')" || {
        echo "devzone: host: $FILE is not valid JSON: provider not touched" >&2
        return 1
    }
    if [ "$(printf '%s' "$out" | jq -c 'del(."$schema") | length')" = 0 ]; then
        rm -f "$FILE"
    else
        printf '%s\n' "$out" >"$FILE.tmp" && mv "$FILE.tmp" "$FILE"
    fi
}

# Removes the devzone-host provider from the opencode configuration file,
# keeping everything else. No error when the file is absent.
unset_provider() {
    [ ! -f "$FILE" ] && return 0
    rewrite 'if .provider then del(.provider["devzone-host"]) | (if .provider == {} then del(.provider) else . end) else . end'
}

# When run directly (not sourced): dispatch the subcommands.
if [ "${0##*/}" = "host-models.sh" ]; then
    case "${1:-}" in
        first) premier ;;
        set) set_provider ;;
        unset) unset_provider ;;
        check | rapport)
            exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/host-check.sh" "$@"
            ;;
        *) modeles ;;
    esac
fi
