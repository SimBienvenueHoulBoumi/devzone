#!/usr/bin/env bash
# Local model in the rotation of devzone agent (#586), sourced by agent.sh.
# The local slot is the host model when Ollama answers /api/tags with at least
# one model (reference devzone-host/<model>). It always comes after every online
# model; its internal name has no slash (an ecart-<name> file is written for it);
# opencode gets the reference.
# Real host model name (Ollama) chosen for this attempt, empty otherwise.
LOCAL_HOST_REAL=""
# Internal (slash-free) name of the host model chosen for this attempt.
LOCAL_HOST_INTERNAL=""

# shellcheck source=SCRIPTDIR/ai/host-models.sh
# shellcheck disable=SC1091
. "$ICI/ai/host-models.sh"

# Sanitizes a model name into an internal name: every character outside
# [A-Za-z0-9._-] becomes '_'. Used for ecart-<name> files, the journal and
# the rotation, so a host model such as hf.co/org/model:tag never creates a
# nested or invalid path.
internal_name() {
    printf '%s' "$1" | sed 's/[^A-Za-z0-9._-]/_/g'
}

# Sets LOCAL_MODEL for this attempt, read by model_at_rank and
# models_total. Also records the real host model name when the host is chosen.
local_charge() {
    local nom
    LOCAL_MODEL=""
    LOCAL_HOST_REAL=""
    LOCAL_HOST_INTERNAL=""
    nom="$(premier 2>/dev/null || true)"
    [ -n "$nom" ] || return 0
    LOCAL_HOST_REAL="$nom"
    LOCAL_HOST_INTERNAL="$(internal_name "$nom")"
    LOCAL_MODEL="$LOCAL_HOST_INTERNAL"
    return 0
}

# Model reference given to opencode -m
model_ref() {
    if [ -n "$LOCAL_HOST_INTERNAL" ] && [ "$1" = "$LOCAL_HOST_INTERNAL" ]; then
        echo "devzone-host/$LOCAL_HOST_REAL"
    else
        echo "opencode/$1"
    fi
}

# Model of rank $1 in the attempt that starts at $2: online ones in rotation,
# then the local host model
model_at_rank() {
    if [ "$1" -lt "${#FREE_MODELS[@]}" ]; then
        echo "${FREE_MODELS[$(( ($2 + $1) % ${#FREE_MODELS[@]} ))]}"
    else
        echo "$LOCAL_MODEL"
    fi
}

# Number of models to try: the online ones, plus the local host model if ready
models_total() {
    local total="${#FREE_MODELS[@]}"
    [ -n "$LOCAL_MODEL" ] && total=$((total + 1))
    echo "$total"
}
