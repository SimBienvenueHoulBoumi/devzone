#!/usr/bin/env bash
# shellcheck shell=bash
# devzone, version of the folder and of the published release.
# Sourced by .devcontainer/devzone (split of the 1 600 lines file, #722):
# functions only, shared variables are defined in devzone.

# Version du dossier devzone (manifeste écrit par la CLI du poste), rien si
# le dossier vient d'avant le manifeste
version_du_dossier() {
    local v
    [ -f "$RACINE/.devzone.version" ] || return 1
    v="$(sed -n '1s/^version //p' "$RACINE/.devzone.version" 2>/dev/null | head -1 || true)"
    [ -n "$v" ] || return 1
    printf '%s\n' "$v"
}

# Vrai si la première version est plus récente que la seconde
version_plus_recente() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        na = split(a, x, ".")
        nb = split(b, y, ".")
        n = (na > nb ? na : nb)
        for (i = 1; i <= n; i++) {
            p = (i <= na ? x[i] : 0) + 0
            q = (i <= nb ? y[i] : 0) + 0
            if (p > q) exit 0
            if (p < q) exit 1
        }
        exit 1
    }'
}

# Version publiée sur npm, au plus une fois par jour, en cache sous
# ~/.cache/devzone/ ; 5 s au plus, silencieux hors ligne
version_publiee() {
    local cache jour npm v temporal pid attente
    cache="$HOME/.cache/devzone/version-publiee"
    jour="$(date +%Y-%m-%d)"
    if [ -f "$cache" ] && [ "$(sed -n '1p' "$cache" 2>/dev/null || true)" = "$jour" ]; then
        sed -n '2p' "$cache" 2>/dev/null || true
        return 0
    fi
    npm="${DEVZONE_NPM:-npm}"
    v=""
    if command -v "$npm" >/dev/null 2>&1; then
        mkdir -p "$(dirname "$cache")" 2>/dev/null || true
        temporal="$cache.$$"
        "$npm" view devzone version >"$temporal" 2>/dev/null &
        pid=$!
        attente=0
        while kill -0 "$pid" 2>/dev/null; do
            sleep 1
            attente=$((attente + 1))
            if [ "$attente" -ge 5 ]; then
                kill "$pid" 2>/dev/null || true
                break
            fi
        done
        wait "$pid" 2>/dev/null || true
        v="$(sed -n '1p' "$temporal" 2>/dev/null | tr -d '[:space:]' || true)"
        rm -f "$temporal"
    fi
    mkdir -p "$(dirname "$cache")" 2>/dev/null || true
    printf '%s\n%s\n' "$jour" "$v" >"$cache" 2>/dev/null || true
    [ -n "$v" ] && printf '%s\n' "$v"
    return 0
}

ligne_version_disponible() {
    local dossier publiee
    dossier="$(version_du_dossier)" || return 0
    publiee="$(version_publiee)" || return 0
    publiee="${publiee#v}"
    [ -n "$publiee" ] || return 0
    if version_plus_recente "$publiee" "$dossier"; then
        printf '  ○ devzone %s available: on the workstation, devzone update\n' "$publiee"
    fi
}
