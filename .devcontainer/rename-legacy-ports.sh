#!/usr/bin/env bash
# shellcheck shell=bash
# Migration of the names of the port watcher, of the locks and of the state files
# of the port automation (#774, lot 5). Sourced by rename-legacy-files.sh, which
# defines ROOT, TMP_DIR, is_real_dir and rename_legacy: never run alone. bash 3.2.
#
# Rule for a lock: a lock held by a live process is never moved or removed, it
# is reported on stderr and the next run migrates it once its holder has gone.

# pid_alive PID: true when PID is a live process
pid_alive() {
    [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null
}

# lock_held DIR: true when the lock folder DIR names a live process in DIR/pid
lock_held() {
    pid_alive "$(cat "$1/pid" 2>/dev/null || true)"
}

# migrate_lock OLD NEW: the lock folder OLD becomes NEW, unless a live process
# holds it
migrate_lock() {
    [ -e "$1" ] || [ -L "$1" ] || return 0
    if lock_held "$1"; then
        echo "devzone : $1 kept: held by a live process" >&2
        return 0
    fi
    rename_legacy "$1" "$2"
}

# is_watcher PID: true when PID is a live port watcher (its command line names
# ports-workspace.sh, or is "workspace ports loop" of the Go watcher), so a pid
# file left by a dead watcher never makes us signal an unrelated process that
# reuses the number
is_watcher() {
    [ -n "${1:-}" ] || return 1
    kill -0 "$1" 2>/dev/null || return 1
    ps -p "$1" -o command= 2>/dev/null | grep -Eq 'ports-workspace\.sh|workspace ports loop'
}

# Folders of the workstation port watcher (#774, lots 4 and 5): relais/ becomes
# relays/, pris/ taken/, verrou lock and plafond cap. A watcher that is running
# keeps the old folders and creates them again at each round, so it is stopped
# first: SIGTERM, and its own handler removes its relays, its lock and its pid.
# It is not restarted here (the files of the package are replaced after this
# script): the file restart is left in its folder as the signal that this
# migration, not the user, stopped it; devzone update starts it again once the
# files are replaced, and a start or a stop by the user removes the signal. If
# it does not stop within 2 s, nothing is renamed.
migrate_ports() {
    local d="$ROOT/.devzone.workspace-ports" pid old n
    is_real_dir "$d" || return 0
    old=""
    for n in relais pris verrou plafond; do
        if [ -e "$d/$n" ] || [ -L "$d/$n" ]; then old=1; fi
    done
    [ -n "$old" ] || return 0
    pid="$(cat "$d/pid" 2>/dev/null || true)"
    if is_watcher "$pid"; then
        kill "$pid" 2>/dev/null || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            is_watcher "$pid" || break
            sleep 0.2
        done
        if is_watcher "$pid"; then
            echo "devzone : port watcher (pid $pid) still running, $d folders kept under their old names" >&2
            return 0
        fi
        : >"$d/restart"
        echo "devzone : port watcher stopped to rename its folders, restart it: devzone workspace ports start"
    fi
    rename_legacy "$d/relais" "$d/relays"
    rename_legacy "$d/pris" "$d/taken"
    rename_legacy "$d/verrou" "$d/lock"
    rename_legacy "$d/plafond" "$d/cap"
}

# State of the port automation of the pod, one folder per instance in
# $DEVZONE_PORTS_AUTO_DIR (default: devzone-ports-auto of the temporary folder):
# verrou lock, occupes busy, actifs active, courant current. An instance whose
# lock is held by a live watcher is left whole: its files are in use.
migrate_ports_auto() {
    local base="${DEVZONE_PORTS_AUTO_DIR:-$TMP_DIR/devzone-ports-auto}" d
    for d in "$base"/*; do
        is_real_dir "$d" || continue
        if lock_held "$d/verrou"; then
            echo "devzone : $d kept: its watcher is running" >&2
            continue
        fi
        rename_legacy "$d/verrou" "$d/lock"
        rename_legacy "$d/occupes" "$d/busy"
        rename_legacy "$d/actifs" "$d/active"
        rename_legacy "$d/courant" "$d/current"
    done
}

# Locks of the agent (state folder of devzone agent) and of the catalog watcher
migrate_agent_locks() {
    migrate_lock "${DEVZONE_AGENT_STATE:-${HOME:-/nonexistent}/.local/state/oc-lancer}/verrou" \
        "${DEVZONE_AGENT_STATE:-${HOME:-/nonexistent}/.local/state/oc-lancer}/lock"
    migrate_lock "$ROOT/.devzone.catalog-watcher/verrou" "$ROOT/.devzone.catalog-watcher/lock"
}

# Write lock of the state file: the folder .devzone.modules.verrou became
# .devzone.modules.lockdir. It is a transient mkdir lock without pid: it is
# not renamed, the old one is removed once it is older than 30 s, which is the
# age after which state-lock.sh itself takes a lock for abandoned. A younger
# one may belong to a write in progress: it is left for the next run.
migrate_state_lock() {
    local old="$ROOT/.devzone.modules.verrou" t
    is_real_dir "$old" || return 0
    t="$(stat -c %Y "$old" 2>/dev/null || stat -f %m "$old" 2>/dev/null || true)"
    [ -n "$t" ] && [ "$(($(date +%s) - t))" -gt 30 ] || return 0
    if rm -rf -- "$old"; then
        echo "devzone : $old removed (abandoned write lock, now .devzone.modules.lockdir)"
    else
        echo "devzone : $old not removed" >&2
    fi
}
