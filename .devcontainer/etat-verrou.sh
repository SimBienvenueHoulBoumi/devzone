#!/usr/bin/env bash
# Write lock of the module state, sourced by etat.sh (#417 and #476)
#   state_lock_take / state_lock_release    write lock

# Exclusive lock (mkdir): one write at a time. A vanished holder is guessed
# from the age of the folder (no kill) and the depth counter makes the lock
# re-takeable within the same process (init then write).
state_lock_take() {
    local age start
    [ "${STATE_LOCK_DEPTH:-0}" -gt 0 ] && { STATE_LOCK_DEPTH=$((STATE_LOCK_DEPTH + 1)); return 0; }
    mkdir -p "$(dirname "$ETAT")" || return 1
    start="$(date +%s)"
    while ! mkdir "${ETAT}.verrou" 2>/dev/null; do
        age="$(stat -c %Y "${ETAT}.verrou" 2>/dev/null || stat -f %m "${ETAT}.verrou" 2>/dev/null || true)"
        if [ -n "$age" ] && [ "$(( $(date +%s) - age ))" -gt 30 ]; then
            rm -rf "${ETAT}.verrou"
            continue
        fi
        if [ "$(( $(date +%s) - start ))" -ge 10 ]; then
            echo "devzone : state locked elsewhere: ${ETAT}.verrou" >&2
            return 1
        fi
        sleep 1
    done
    # flock serializes the write when it exists (Linux); mkdir stays the only
    # guard on macOS (#476, same pattern as #461).
    if command -v flock >/dev/null 2>&1; then
        if { exec 8>"${ETAT}.lock"; } && flock -w 10 8; then
            STATE_LOCK_FLOCK=1
        else
            rm -rf "${ETAT}.verrou" 2>/dev/null || true
            echo "devzone : state locked elsewhere (flock): ${ETAT}.lock" >&2
            return 1
        fi
    fi
    STATE_LOCK_DEPTH=1
    return 0
}

# Releases the lock taken by this process; depth > 1: still held
state_lock_release() {
    local depth="${STATE_LOCK_DEPTH:-0}"
    [ "$depth" -gt 0 ] || return 0
    [ "$depth" -gt 1 ] && { STATE_LOCK_DEPTH=$((depth - 1)); return 0; }
    STATE_LOCK_DEPTH=0
    if [ "${STATE_LOCK_FLOCK:-0}" = 1 ]; then
        flock -u 8 2>/dev/null || true
        exec 8>&-
        STATE_LOCK_FLOCK=0
    fi
    rm -rf "${ETAT}.verrou" 2>/dev/null || true
    return 0
}
