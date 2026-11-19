#!/usr/bin/env bash
# Local model in the rotation of devzone agent (#586), sourced by agent.sh.
# The local slot is first the host model (Ollama answers /api/tags with at
# least one model, reference devzone-host/<model>), otherwise the llm module's
# local model (devzone-llm/local, cluster / relay /health). It always comes
# after every online model; its internal name has no slash (an ecart-<name>
# file is written for it); opencode gets the reference.
LOCAL_NOM=devzone-llm-local
# Real host model name (Ollama) chosen for this attempt, empty otherwise.
LOCAL_HOTE_REEL=""
# Internal (slash-free) name of the host model chosen for this attempt.
LOCAL_HOTE_INTERNE=""

# shellcheck source=SCRIPTDIR/ia/host-models.sh
# shellcheck disable=SC1091
. "$ICI/ia/host-models.sh"

# Sanitizes a model name into an internal name: every character outside
# [A-Za-z0-9._-] becomes '_'. Used for ecart-<name> files, the journal and
# the rotation, so a host model such as hf.co/org/model:tag never creates a
# nested or invalid path.
nom_interne() {
    printf '%s' "$1" | sed 's/[^A-Za-z0-9._-]/_/g'
}

# Sets LOCAL_MODELE for this attempt, read by modele_au_rang and
# modeles_total. Also records the real host model name when the host is chosen.
local_charge() {
    local nom url
    LOCAL_HOTE_REEL=""
    LOCAL_HOTE_INTERNE=""
    nom="$(premier 2>/dev/null || true)"
    if [ -n "$nom" ]; then
        LOCAL_HOTE_REEL="$nom"
        LOCAL_HOTE_INTERNE="$(nom_interne "$nom")"
        LOCAL_MODELE="$LOCAL_HOTE_INTERNE"
        return 0
    fi
    # Fallback: the llm module local model (cluster / relay).
    LOCAL_MODELE=""
    if [ "${DEVZONE_WORKSPACE:-}" != kubernetes ]; then
        bash "$ICI/devzone" is-enabled llm >/dev/null 2>&1 || return 0
    fi
    url="$(bash "$ICI/llm/opencode.sh" url)" || return 0
    if curl -fsS --max-time 3 "${url%/v1}/health" >/dev/null 2>&1; then
        LOCAL_MODELE="$LOCAL_NOM"
    fi
    return 0
}

# Model reference given to opencode -m
modele_ref() {
    if [ "$1" = "$LOCAL_NOM" ]; then echo devzone-llm/local;
    elif [ -n "$LOCAL_HOTE_INTERNE" ] && [ "$1" = "$LOCAL_HOTE_INTERNE" ]; then echo "devzone-host/$LOCAL_HOTE_REEL";
    else echo "opencode/$1"; fi
}

# Model of rank $1 in the attempt that starts at $2: online ones in rotation,
# then the local one (host or llm module)
modele_au_rang() {
    if [ "$1" -lt "${#FREE_MODELS[@]}" ]; then
        echo "${FREE_MODELS[$(( ($2 + $1) % ${#FREE_MODELS[@]} ))]}"
    else
        echo "$LOCAL_MODELE"
    fi
}

# Number of models to try: the online ones, plus the local one if ready
modeles_total() {
    local total="${#FREE_MODELS[@]}"
    [ -n "$LOCAL_MODELE" ] && total=$((total + 1))
    echo "$total"
}
