#!/usr/bin/env bash
# Local model in the rotation of devzone agent (#586), sourced by agent.sh.
# The model devzone-llm/local comes after every online model (never first, never
# when the module llm is off or the server does not answer /health): it is used
# when the online ones are all set aside (quota, network). Its internal name has
# no slash (a file ecart-<name> is written for it); opencode gets the reference.
LOCAL_NOM=devzone-llm-local

# Prints LOCAL_NOM when the module is on (in the pod: the cluster answers) and
# the server answers /health
local_pret() {
    local url
    if [ "${DEVZONE_WORKSPACE:-}" != kubernetes ]; then
        bash "$ICI/devzone" is-enabled llm >/dev/null 2>&1 || return 0
    fi
    url="$(bash "$ICI/llm/opencode.sh" url)" || return 0
    curl -fsS --max-time 3 "${url%/v1}/health" >/dev/null 2>&1 && echo "$LOCAL_NOM"
    return 0
}

# Model reference given to opencode -m
modele_ref() {
    if [ "$1" = "$LOCAL_NOM" ]; then echo devzone-llm/local; else echo "opencode/$1"; fi
}

# Model of rank $1 in the attempt that starts at $2: online ones in rotation,
# then the local one
modele_au_rang() {
    if [ "$1" -lt "${#FREE_MODELS[@]}" ]; then
        echo "${FREE_MODELS[$(( ($2 + $1) % ${#FREE_MODELS[@]} ))]}"
    else
        echo "$LOCAL_MODELE"
    fi
}

# Number of models to try: the online ones, plus the local one if ready
modeles_total() {
    echo $(( ${#FREE_MODELS[@]} + ${#LOCAL_MODELE} / ${#LOCAL_NOM} ))
}
