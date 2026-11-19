#!/usr/bin/env bash
# Detection of the models served by Ollama on the host (#665).
# devzone hosts no model: models live on the host (Ollama) and are detected here.
#   host-models.sh            list the detected model names, one per line
#   host-models.sh first      the model to use (DEVZONE_HOST_MODEL or first detected)
#   host-models.sh set        merge the devzone-host provider into ~/.config/opencode/config.json
#   host-models.sh unset      remove the devzone-host provider from that file
# Default URL: http://host.docker.internal:11434, overridable with DEVZONE_OLLAMA_URL.
# Short timeout; exits 0 and writes nothing when Ollama does not answer.
# bash 3.2 (macOS). Code and comments in English.
set -euo pipefail

URL="${DEVZONE_OLLAMA_URL:-http://host.docker.internal:11434}"
URL="${URL%/}"
FILE="$HOME/.config/opencode/config.json"

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

# Prints the detected model names, one per line. Exits 0 and prints nothing
# when Ollama does not answer or the payload is not usable.
modeles() {
    local data
    data="$(curl -fsS --max-time 3 "${URL}/api/tags" 2>/dev/null)" || return 0
    [ -n "$data" ] || return 0
    # Ignore embedding models (Ollama details.type, or a name containing "embed").
    printf '%s' "$data" | jq -r '.models[] | select((.details.type // "") != "embedding") | .name' 2>/dev/null |
        while IFS= read -r name; do
            is_embedding "$name" || printf '%s\n' "$name"
        done || true
    return 0
}

# The model to use: DEVZONE_HOST_MODEL when set, else the first detected.
# Empty when Ollama did not answer or no model was detected.
premier() {
    local liste nom="${DEVZONE_HOST_MODEL:-}"
    liste="$(modeles)" || true
    [ -n "$liste" ] || return 0
    if [ -n "$nom" ]; then
        printf '%s\n' "$nom"
    else
        printf '%s\n' "${liste%%$'\n'*}"
    fi
    return 0
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
        *) modeles ;;
    esac
fi
