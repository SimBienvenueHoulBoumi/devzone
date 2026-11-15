#!/usr/bin/env bash
# opencode provider of the local model (#586), in a file apart managed by devzone:
#   opencode.sh set      provider devzone-llm (model local) put in the config
#   opencode.sh unset    provider removed (the rest of the file is kept)
#   opencode.sh url      base URL of the model seen from here
# File: ~/.config/opencode/config.json. opencode (1.19) reads it on its own, for
# the interactive session and for `opencode run`, with no environment variable,
# before opencode.json(c) (devzone enable ia) and OPENCODE_CONFIG_CONTENT (devzone
# agent), which keep the priority; providers merge, nothing of ia is replaced.
# URL: cluster DNS in the Kubernetes workspace pod, the relay of the container
# (127.0.0.1:LLM_PORT) elsewhere. bash 3.2 (macOS).
set -euo pipefail

FILE="$HOME/.config/opencode/config.json"

base_url() {
    if [ "${DEVZONE_WORKSPACE:-}" = kubernetes ]; then
        echo "http://llm.devzone-llm.svc.cluster.local:8080/v1"
    else
        echo "http://127.0.0.1:${LLM_PORT:-8089}/v1"
    fi
}

# jq program $1 applied to the file (or {}), written back atomically
rewrite() {
    local current="{}" out
    [ ! -f "$FILE" ] || current="$(cat "$FILE")"
    mkdir -p "$(dirname "$FILE")"
    out="$(printf '%s' "$current" | jq --arg url "$(base_url)" "$1")" || {
        echo "devzone: llm: $FILE is not valid JSON: provider not touched" >&2
        return 1
    }
    # Nothing left but the schema: the file was ours, it goes
    if [ "$(printf '%s' "$out" | jq -c 'del(."$schema") | length')" = 0 ] && [ "$1" != "$SET" ]; then
        rm -f "$FILE"
    else
        printf '%s\n' "$out" >"$FILE.tmp" && mv "$FILE.tmp" "$FILE"
    fi
}

# shellcheck disable=SC2016 # jq programs, $url is a jq variable
SET='."$schema" = (."$schema" // "https://opencode.ai/config.json")
    | .provider["devzone-llm"] = {npm: "@ai-sdk/openai-compatible", name: "devzone local model",
        options: {baseURL: $url}, models: {local: {name: "Local code model"}}}'
# shellcheck disable=SC2016
UNSET='if .provider then del(.provider["devzone-llm"]) | (if .provider == {} then del(.provider) else . end) else . end'

case "${1:-}" in
    set) rewrite "$SET" ;;
    unset) [ ! -f "$FILE" ] || rewrite "$UNSET" ;;
    url) base_url ;;
    *)
        echo "usage: opencode.sh set|unset|url" >&2
        exit 1
        ;;
esac
