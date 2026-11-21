#!/usr/bin/env bash
# shellcheck disable=SC2034
# Model exclusions and network wait of the agent supervisor (#328).
# Library sourced by agent.sh: no command is launched here.

# Known opencode error texts (grep -E); error_cause takes the cause from them.
ERRORS='not available in your country|Free usage limit|content filter|Model is unavailable|Upstream request failed|ProviderHeaderTimeout|ENOTFOUND|ECONNREFUSED|ETIMEDOUT|EAI_AGAIN|ECONNRESET|fetch failed|network'
# Prefix of an opencode error line. Erreur: stays so that French output still matches.
ERROR_LINE='(^|[[:space:]])(Error|ERROR|Erreur):'

# Cause of a failure: pays (country, lasting), quota, filtre (filter), reseau
# (network, no exclusion) or autre (other). The stored names stay as they are:
# they are written to the state files and to devzone agent state --json.
error_cause() {
    local t="$1"
    case "$t" in
        *"not available in your country"*) echo "pays" ;;
        *"Free usage limit"*) echo "quota" ;;
        *"content filter"*) echo "filtre" ;;
        *"ENOTFOUND"* | *"ECONNREFUSED"* | *"ETIMEDOUT"* | *"EAI_AGAIN"* | *"ECONNRESET"* | *"fetch failed"* | *"network"*)
            echo "reseau" ;;
        *) echo "autre" ;;
    esac
}

# Cause name shown to the user, from a stored cause (mute and muet are both silent).
cause_label() {
    case "$1" in
        pays) echo "country" ;;
        quota) echo "quota" ;;
        filtre) echo "filter" ;;
        reseau) echo "network" ;;
        mute | muet) echo "silent" ;;
        *) echo "other" ;;
    esac
}

# Duration of an exclusion in seconds: country 7 days (DEVZONE_AGENT_COUNTRY_EXCLUSION), the others 1 h.
exclusion_duration() {
    case "$1" in
        pays) echo "${DEVZONE_AGENT_COUNTRY_EXCLUSION:-604800}" ;;
        *) echo 3600 ;;
    esac
}

# Readable duration of an exclusion for the journal: "7 d", "1 h" or "30 s".
exclusion_label() {
    local d
    d="$(exclusion_duration "$1")"
    if [ "$d" -ge 86400 ]; then
        echo "$(( d / 86400 )) d"
    elif [ "$d" -ge 3600 ]; then
        echo "$(( d / 3600 )) h"
    else
        echo "${d} s"
    fi
}

# Writes the exclusion of the model: "<start> <cause> <duration>" in $AGENT_STATE/ecart-<model>
# (the state file keeps its name on disk).
model_exclude() {
    printf '%s %s %s\n' "$(date +%s)" "$2" "$(exclusion_duration "$2")" >"$AGENT_STATE/ecart-$1"
}

# True (0) when the model is excluded right now. Also reads the old muet-<model>
# format (timestamp only, 1 h).
model_excluded() {
    local f e cause d
    f="$AGENT_STATE/ecart-$1"
    if [ ! -f "$f" ]; then f="$AGENT_STATE/muet-$1"; fi
    if [ ! -f "$f" ]; then return 1; fi
    read -r e cause d <<<"$(cat "$f")"
    [ "$(date +%s)" -lt $(( e + ${d:-3600} )) ]
}

# True (0) when opencode.ai resolves and answers over HTTPS: one try, no wait.
network_reachable() {
    getent hosts opencode.ai >/dev/null 2>&1 && curl -sI --max-time 5 https://opencode.ai >/dev/null 2>&1
}

# Waits for the network to come back: a try every DEVZONE_AGENT_NETWORK_STEP s, for
# DEVZONE_AGENT_NETWORK_MAX s at most. Returns 0 when it is back.
network_wait() {
    local end
    end=$(( $(date +%s) + ${DEVZONE_AGENT_NETWORK_MAX:-1800} ))
    echo "=== network down, waiting" >>"$AGENT_JOURNAL"
    while [ "$(date +%s)" -lt "$end" ]; do
        if network_reachable; then
            echo "=== network back" >>"$AGENT_JOURNAL"
            return 0
        fi
        sleep "${DEVZONE_AGENT_NETWORK_STEP:-30}"
    done
    return 1
}

# Lists the current exclusions for devzone agent state (muet- too, without cause).
agent_exclusions() {
    local f m e cause d end now
    now="$(date +%s)"
    for f in "$AGENT_STATE"/ecart-*; do
        [ -e "$f" ] || continue
        m="${f##*/ecart-}"
        read -r e cause d <<<"$(cat "$f")"
        end=$(( e + ${d:-3600} ))
        [ "$now" -lt "$end" ] || continue
        echo "  model $m excluded ($(cause_label "$cause")) until $(utc_time "$end")"
    done
    for f in "$AGENT_STATE"/muet-*; do
        [ -e "$f" ] || continue
        m="${f##*/muet-}"
        e="$(cat "$f" 2>/dev/null || true)"
        [ -n "$e" ] || continue
        end=$(( e + 3600 ))
        [ "$now" -lt "$end" ] || continue
        echo "  model $m excluded (silent) until $(utc_time "$end")"
    done
}

# Lifts the exclusion of a model, or of all (--all): devzone agent release.
exclusion_clear() {
    case "$1" in
        --all) rm -f "$AGENT_STATE"/ecart-* "$AGENT_STATE"/muet-* ;;
        *) rm -f "$AGENT_STATE/ecart-$1" "$AGENT_STATE/muet-$1" ;;
    esac
}

# Keeps the opencode log lines of the session written by --print-logs: only the
# "timestamp=... level=ERROR ..." lines of a failure declare an exclusion, not the
# rest of the text read or written by the model.
error_lines() {
    printf '%s\n' "$1" | sed -e $'s/\033\[[0-9;]*m//g' | grep -a -E '^timestamp=.* level=ERROR ' || true
}

# Stops the current session when the journal holds quota, country or filter since
# its start: the model is excluded and the session is killed (process and children).
session_fatal_error() {
    local pid="$1" journal="$2" offset="$3" m="$4" folder="$5"
    local output cause
    output="$(tail -c "+$(( offset + 1 ))" "$journal" 2>/dev/null || true)"
    cause="$(error_cause "$(error_lines "$output")")"
    case "$cause" in
        quota | pays | filtre) ;;
        *) return 1 ;;
    esac
    pkill -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rights_verify "$folder"
    model_exclude "$m" "$cause"
    model_requested_excluded "$m" "$cause" "$journal"
    printf '%s\n' "=== opencode/$m excluded ($(cause_label "$cause")): next model" >>"$journal"
    return 0
}
