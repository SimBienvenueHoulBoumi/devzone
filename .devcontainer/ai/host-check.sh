#!/usr/bin/env bash
# Update check and report for the host (Ollama) models (#668).
#   host-check.sh check      per detected model: up to date, update available,
#                            or not verifiable; never downloads anything
#   host-check.sh rapport    sizes, update state, measurements and the chosen
#                            default model with its reason
# The registry manifest digest is compared with the local /api/tags digest: one
# GET per model, no download, no "ollama pull" executed (the command is only
# printed for the host). The registry is DEVZONE_OLLAMA_REGISTRY, else
# https://registry.ollama.ai.
# bash 3.2 (macOS). Code and comments in English; the user messages are French
# and live in host-check.message (not listed in .english).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/host-models.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/host-models.sh"

REG="${DEVZONE_OLLAMA_REGISTRY:-https://registry.ollama.ai}"
REG="${REG%/}"
MESSAGE_FILE="$SCRIPT_DIR/host-check.message"

# English fallbacks, overridden by the French message file.
MSG_TITRE="host (Ollama) models detected:"
MSG_AUCUN="devzone: no Ollama model detected on {url} (answer on /api/tags)"
MSG_TAILLE="size"
MSG_A_JOUR="up to date"
MSG_MAJ="update available"
MSG_NON="not verifiable"
MSG_PULL="on the host: ollama pull {modele}"
MSG_MESURE="measurement reussite {reussite}, tok_s {tok_s}"
MSG_RETENU="chosen model: {modele} ({raison})"
MSG_RAISON_VAR="DEVZONE_HOST_MODEL"
MSG_RAISON_MESURE="measurement"
MSG_RAISON_REGLE="rule"

if [ -r "$MESSAGE_FILE" ]; then
    # shellcheck source=/dev/null
    . "$MESSAGE_FILE"
fi

# Lowercase hex sha256 of a file (sha256sum on Linux, shasum on macOS).
sha256_fichier() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# Prints the update state of one model: MSG_A_JOUR, MSG_MAJ or MSG_NON.
# A name with a slash (hf.co/...), a 404, an unreachable registry or a missing
# digest is not verifiable.
etat_modele() {
    local nom="$1" digest="$2" court tag somme tmp
    case "$nom" in
        */*) printf '%s\n' "$MSG_NON"; return 0 ;;
    esac
    case "$nom" in
        *:*) court="${nom%:*}"; tag="${nom##*:}" ;;
        *) court="$nom"; tag="latest" ;;
    esac
    tmp="$(mktemp "${TMPDIR:-/tmp}/devzone-manifest.XXXXXX")"
    if ! curl -fsS --max-time 5 \
        -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
        -o "$tmp" "${REG}/v2/library/${court}/manifests/${tag}" 2>/dev/null; then
        rm -f "$tmp"
        printf '%s\n' "$MSG_NON"
        return 0
    fi
    somme="$(sha256_fichier "$tmp")"
    rm -f "$tmp"
    if [ -z "$digest" ]; then
        printf '%s\n' "$MSG_NON"
        return 0
    fi
    if [ "$(printf '%s' "$somme" | tr '[:upper:]' '[:lower:]')" = \
        "$(printf '%s' "${digest#sha256:}" | tr '[:upper:]' '[:lower:]')" ]; then
        printf '%s\n' "$MSG_A_JOUR"
    else
        printf '%s\n' "$MSG_MAJ"
    fi
}

# Prints "reussite tok_s" for a model, empty when it has no measurement.
mesure_pour() {
    local nom="$1" data
    [ -f "$MEASURES" ] || return 0
    data="$(cat "$MEASURES" 2>/dev/null)" || return 0
    [ -n "$data" ] || return 0
    printf '%s' "$data" | jq -r --arg nom "$nom" '
        .[$nom] | if . == null then empty else "\(.reussite // 0) \(.tok_s // 0)" end
    ' 2>/dev/null || return 0
}

# Why the model is chosen: variable, measurement or rule.
raison_choix() {
    local liste="$1" m
    if [ -n "${DEVZONE_HOST_MODEL:-}" ]; then
        printf '%s\n' "$MSG_RAISON_VAR"
        return 0
    fi
    m="$(mesure_choix "$liste")" || true
    if [ -n "$m" ]; then
        printf '%s\n' "$MSG_RAISON_MESURE"
    else
        printf '%s\n' "$MSG_RAISON_REGLE"
    fi
}

# Update check of every detected model. Nothing is downloaded, nothing changes.
check() {
    local data ligne nom taille digest etat
    data="$(infos)" || true
    if [ -z "$data" ]; then
        printf '%s\n' "${MSG_AUCUN//\{url\}/$URL}"
        return 0
    fi
    printf '%s\n' "$data" | while IFS=$'\t' read -r nom taille digest; do
        [ -n "$nom" ] || continue
        etat="$(etat_modele "$nom" "$digest")"
        printf '%s : %s\n' "$nom" "$etat"
        if [ "$etat" = "$MSG_MAJ" ]; then
            printf '%s\n' "${MSG_PULL//\{modele\}/$nom}"
        fi
    done
    return 0
}

# Report: sizes, update state, measurements and the chosen model with its
# reason. Proposes, changes nothing.
rapport() {
    local data liste ligne nom taille digest etat mes r t def raison
    data="$(infos)" || true
    if [ -z "$data" ]; then
        printf '%s\n' "${MSG_AUCUN//\{url\}/$URL}"
        return 0
    fi
    liste="$(printf '%s\n' "$data" | cut -f1)"
    printf '%s\n' "$MSG_TITRE"
    printf '%s\n' "$data" | while IFS=$'\t' read -r nom taille digest; do
        [ -n "$nom" ] || continue
        etat="$(etat_modele "$nom" "$digest")"
        printf '  %s : %s ; %s %s\n' "$nom" "$etat" "$MSG_TAILLE" "$taille"
        mes="$(mesure_pour "$nom")"
        if [ -n "$mes" ]; then
            r="${mes%% *}"
            t="${mes#* }"
            ligne="${MSG_MESURE//\{reussite\}/$r}"
            ligne="${ligne//\{tok_s\}/$t}"
            printf '    %s\n' "$ligne"
        fi
        if [ "$etat" = "$MSG_MAJ" ]; then
            printf '%s\n' "${MSG_PULL//\{modele\}/$nom}"
        fi
    done
    def="$(choix "$liste")" || true
    raison="$(raison_choix "$liste")" || true
    ligne="${MSG_RETENU//\{modele\}/${def:-}}"
    ligne="${ligne//\{raison\}/$raison}"
    printf '%s\n' "$ligne"
    return 0
}

# When run directly (not sourced): dispatch the subcommands.
if [ "${0##*/}" = "host-check.sh" ]; then
    case "${1:-}" in
        check) check ;;
        rapport) rapport ;;
        *) check ;;
    esac
fi
