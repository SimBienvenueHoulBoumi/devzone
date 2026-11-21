#!/usr/bin/env bash
# shellcheck shell=bash
# devzone, version of the folder and of the published release.
# Sourced by .devcontainer/devzone (split of the 1 600 lines file, #722):
# functions only, shared variables are defined in devzone.

# Version of the devzone folder (manifest written by the workstation CLI),
# nothing if the folder predates the manifest
folder_version() {
    local v
    [ -f "$RACINE/.devzone.version" ] || return 1
    v="$(sed -n '1s/^version //p' "$RACINE/.devzone.version" 2>/dev/null | head -1 || true)"
    [ -n "$v" ] || return 1
    printf '%s\n' "$v"
}

# True if the first version is newer than the second
version_is_newer() {
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

# Version published on npm, at most once a day, cached under
# ~/.cache/devzone/; 5 s at most, silent offline
published_version() {
    local cache day npm v tmp pid waited
    cache="$HOME/.cache/devzone/version-publiee"
    day="$(date +%Y-%m-%d)"
    if [ -f "$cache" ] && [ "$(sed -n '1p' "$cache" 2>/dev/null || true)" = "$day" ]; then
        sed -n '2p' "$cache" 2>/dev/null || true
        return 0
    fi
    npm="${DEVZONE_NPM:-npm}"
    v=""
    if command -v "$npm" >/dev/null 2>&1; then
        mkdir -p "$(dirname "$cache")" 2>/dev/null || true
        tmp="$cache.$$"
        "$npm" view devzone version >"$tmp" 2>/dev/null &
        pid=$!
        waited=0
        while kill -0 "$pid" 2>/dev/null; do
            sleep 1
            waited=$((waited + 1))
            if [ "$waited" -ge 5 ]; then
                kill "$pid" 2>/dev/null || true
                break
            fi
        done
        wait "$pid" 2>/dev/null || true
        v="$(sed -n '1p' "$tmp" 2>/dev/null | tr -d '[:space:]' || true)"
        rm -f "$tmp"
    fi
    mkdir -p "$(dirname "$cache")" 2>/dev/null || true
    printf '%s\n%s\n' "$day" "$v" >"$cache" 2>/dev/null || true
    [ -n "$v" ] && printf '%s\n' "$v"
    return 0
}

version_available_line() {
    local folder published
    folder="$(folder_version)" || return 0
    published="$(published_version)" || return 0
    published="${published#v}"
    [ -n "$published" ] || return 0
    if version_is_newer "$published" "$folder"; then
        printf '  ○ devzone %s available: on the workstation, devzone update\n' "$published"
    fi
}
