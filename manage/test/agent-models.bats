#!/usr/bin/env bats
# Static check for the free-model fallback list and the opencode defaults (#643).
# Reads files only: no network and no cluster.

setup() {
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    AGENT="$RACINE/.devcontainer/agent.sh"
    CONFIG="$RACINE/.devcontainer/opencode.jsonc"
}

# Tokens of the FREE_MODELS array, one name per line, duplicates kept.
raw_fallback_models() {
    sed -n '/^FREE_MODELS=(/,/)/p' "$AGENT" |
        tr -d '()' |
        tr '[:space:]' '\n' |
        grep -v '^$'
}

fallback_models() {
    raw_fallback_models | sort -u
}

# Every opencode model referenced anywhere in the config.
config_models() {
    grep -oE '"opencode/[A-Za-z0-9._-]+"' "$CONFIG" |
        tr -d '"' |
        sed 's#^opencode/##' |
        sort -u
}

# Top-level model and small_model values: devzone defaults, not rotation picks.
default_models() {
    grep -E '^[[:space:]]*"(model|small_model)": "opencode/' "$CONFIG" |
        cut -d '"' -f 4 |
        sed 's#^opencode/##' |
        sort -u
}

@test "agent.sh: FREE_MODELS has no duplicate name" {
    [ "$(raw_fallback_models | grep -c . || true)" -eq "$(fallback_models | grep -c . || true)" ]
}

@test "retired models are absent from opencode.jsonc and agent.sh" {
    for model in glm-5.3-flash-free nemotron-3-ultra-free; do
        run grep -F "$model" "$CONFIG" "$AGENT"
        [ "$status" -eq 1 ] || { printf 'still referenced: %s\n' "$model" >&2; false; }
    done
}

@test "every config model is in the fallback list or a top-level default" {
    [ -n "$(config_models)" ]
    [ -n "$(fallback_models)" ]
    defaults="$(default_models)"
    available="$(fallback_models)"
    # Agent models are checked as well: the #643 regression was agent.plan.
    for model in $(config_models); do
        if printf '%s\n' "$defaults" | grep -qxF "$model"; then continue; fi
        printf '%s\n' "$available" | grep -qxF "$model" || { printf 'model missing from fallback list: %s\n' "$model" >&2; false; }
    done
}
