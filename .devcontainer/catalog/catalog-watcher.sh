#!/usr/bin/env bash
# Catalog hot detection (#414): when .devzone.modules changes, catalog.sh apply
# runs. A single instance (lock, as #394).
#   catalog-watcher.sh demarrer | arreter | tour
set -euo pipefail

ICI="$(cd "$(dirname "$0")" && pwd)"
RACINE="${DEVZONE_ROOT:-$(cd "$ICI/../.." && pwd)}"
ETAT="${DEVZONE_STATE:-$RACINE/.devzone.modules}"
# shellcheck source=SCRIPTDIR/state.sh
# shellcheck disable=SC1091
. "$(dirname "$ICI")/state.sh"
BASE="${DEVZONE_CATALOG_WATCHER_DIR:-$RACINE/.devzone.catalogue-veilleur}"
LOCK_DIR="$BASE/verrou"
LAST_FILE="$BASE/dernier"

refuse() { echo "devzone : catalog-watcher : $*" >&2; exit 2; }

# Guard (#293): never under bats, only with DEVZONE_CATALOG_REAL=yes
guard_watcher() {
    if [ "${DEVZONE_CATALOG_REAL:-}" != yes ]; then
        echo "devzone : catalog-watcher : refused here (DEVZONE_CATALOG_REAL=yes)" >&2
        return 2
    fi
    if [ -n "${BATS_TEST_TMPDIR:-}" ]; then
        echo "devzone : catalog-watcher : refused under bats (tests)" >&2
        return 2
    fi
    return 0
}

# Exclusive lock (mkdir) with the pid; a single watcher instance
lock_take() {
    local start now age pid
    start="$(date +%s)"
    while true; do
        if mkdir "$LOCK_DIR" 2>/dev/null; then echo "$$" >"$LOCK_DIR/pid"; return 0; fi
        now="$(date +%s)"
        age=""; [ -d "$LOCK_DIR" ] && age="$(stat -c %Y "$LOCK_DIR" 2>/dev/null || stat -f %m "$LOCK_DIR" 2>/dev/null || true)"
        pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
        if [ -n "$age" ] && [ "$(( now - age ))" -gt 30 ]; then rm -rf "$LOCK_DIR"; continue; fi
        if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then rm -rf "$LOCK_DIR"; continue; fi
        [ "$(( now - start ))" -ge 5 ] && return 1
        sleep 1
    done
}

# Marks the live lock (date and pid up to date)
lock_refresh() { touch "$LOCK_DIR" 2>/dev/null || true; echo "$$" >"$LOCK_DIR/pid" 2>/dev/null || true; }

# One tick: if .devzone.modules changed since the last tick, apply
tick() {
    local now previous
    [ -f "$ETAT" ] || return 0
    # Restored or rebuilt state: the watcher does not follow a doubtful state,
    # and never uninstalls until devzone apply has confirmed it
    state_recovery_wait && return 0
    state_recovery_pending && return 0
    mkdir -p "$BASE"
    now="$(stat -c %Y "$ETAT" 2>/dev/null || stat -f %m "$ETAT" 2>/dev/null || true)"
    [ -n "$now" ] || return 0
    previous="$(cat "$LAST_FILE" 2>/dev/null || true)"
    if [ "$now" != "$previous" ]; then
        echo "$now" >"$LAST_FILE"
        echo "devzone : catalog-watcher : .devzone.modules changed, applying" >&2
        bash "$ICI/../catalog.sh" apply
    fi
}

# Loop: one tick every 5 s, lock refreshed on each tick
loop() {
    mkdir -p "$BASE"
    if ! lock_take; then return 0; fi
    trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM
    while true; do
        [ -f "$ETAT" ] || { rm -rf "$LOCK_DIR"; break; }
        lock_refresh
        tick || true
        sleep 5
    done
}

# Starts the detached loop (#435) and checks that its lock is alive
start_detached() {
    local i pid stable=0 detache=()
    mkdir -p "$BASE"
    # Same detachment as relay_start: setsid when present, else nohup.
    command -v setsid >/dev/null 2>&1 && detache=(setsid)
    ${detache[@]+"${detache[@]}"} nohup env DEVZONE_CATALOG_REAL=yes bash "$0" boucle >"$BASE/veilleur.log" 2>&1 &
    i=0
    while [ "$i" -lt 20 ]; do
        pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            stable=$((stable + 1))
            [ "$stable" -ge 5 ] && { echo "started"; return 0; }
        else
            stable=0
        fi
        sleep 0.1
        i=$((i + 1))
    done
    echo "devzone : catalog-watcher : cannot start, see $BASE/veilleur.log" >&2
    return 1
}

# Stops the watcher and removes the lock
stop_watcher() {
    local pid
    pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi
    rm -rf "$LOCK_DIR"
}

case "${1:-}" in
    boucle | loop) if ! guard_watcher; then exit 2; fi; loop ;;
    demarrer | start | lancer)
        if ! guard_watcher; then exit 2; fi
        if [ -f "$LOCK_DIR/pid" ] && kill -0 "$(cat "$LOCK_DIR/pid")" 2>/dev/null; then
            echo "already running"
        else
            start_detached || exit 1
        fi
        ;;
    arreter | stop) stop_watcher ; echo "stopped" ;;
    tour | un-tour) tick ;;
    *)
        echo "devzone : catalog-watcher : demarrer | arreter | tour" >&2
        exit 2
        ;;
esac
