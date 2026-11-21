#!/usr/bin/env bash
# Drives opencode on a brief: rotation, silence at start, resume.
# ai module (#221). devzone agent <folder> <brief> | state | release.
# shellcheck disable=SC2034 # RACINE, FREE_MODELS, PAUSE_RANK: read by the sourced agent-*.sh
set -euo pipefail
# Folder of the script, symbolic links followed by hand: readlink -f does not exist
# on macOS (tests under bash 3.2).
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    case "$SOURCE" in
        /*) ;;
        *) SOURCE="$DIR/$SOURCE" ;;
    esac
done
ICI="$(cd -P "$(dirname "$SOURCE")" && pwd)"
RACINE="${DEVZONE_ROOT:-$(dirname "$ICI")}"
# shellcheck source=agent-errors.sh disable=SC1091
. "$ICI/agent-errors.sh"
# shellcheck source=agent-rights.sh disable=SC1091
. "$ICI/agent-rights.sh"
# shellcheck source=SCRIPTDIR/agent-session.sh disable=SC1091
. "$ICI/agent-session.sh"
# shellcheck source=agent-workspace.sh disable=SC1091
. "$ICI/agent-workspace.sh"
# shellcheck source=agent-local.sh disable=SC1091
. "$ICI/agent-local.sh"
# shellcheck source=SCRIPTDIR/agent-model.sh disable=SC1091
. "$ICI/agent-model.sh"
FREE_MODELS=(big-pickle deepseek-v4.1-flash-free hy4-flash-free nemotron-3.5-super-vl-free
    nemotron-3.5-lightning-free mimo-v2.6-flash-free beam-free flint-40b-free longcat-2.5-free)
# Ephemeral session pod (#222)
# shellcheck source=agent-pod.sh disable=SC1091
. "$ICI/agent-pod.sh"
SILENCE="${DEVZONE_AGENT_SILENCE:-45}"
FROZEN="${DEVZONE_AGENT_FROZEN:-600}"
AGENT_STATE="${DEVZONE_AGENT_STATE:-$HOME/.local/state/oc-lancer}"
# Pause between read and write of the rank (tests only): active only when
# DEVZONE_AGENT_PAUSE_RANK is set under bats; never a pause by default.
PAUSE_RANK=0
if [ -n "${DEVZONE_AGENT_PAUSE_RANK:-}" ] && [ -n "${BATS_TEST_TMPDIR:-}" ]; then PAUSE_RANK="$DEVZONE_AGENT_PAUSE_RANK"; fi
# Retries of the same session for a network cause, per model, before the next model
NETWORK_RETRIES=3
refuse() { echo "devzone agent: $*" >&2; exit 2; }
agent_launch() {
    local folder="$1" brief="$2"
    local journal state start m i pid code offset size started freeze discard new
    local brief_current resumed=0 now last output recent cause start_t
    local network_for="" network_n=0
    # Paths relative to the calling folder: made absolute before any cd, lock or
    # state write; the name of the brief is kept.
    [ -d "$folder" ] || refuse "folder not found: $folder (searched from $(pwd))"
    [ -r "$brief" ] || refuse "brief not found: $brief (searched from $(pwd))"
    folder="$(cd "$folder" && pwd -P)"
    brief="$(cd "$(dirname "$brief")" && pwd -P)/$(basename "$brief")"
    # ai module required: without assistants, nothing to drive.
    if ! bash "$ICI/devzone" is-enabled ai >/dev/null 2>&1; then
        refuse "ai module disabled: devzone enable ai"
    fi
    configure
    journal="$(journal_of "$folder")"
    export AGENT_JOURNAL="$journal"
    state="$AGENT_STATE"
    mkdir -p "$(dirname "$journal")" "$state"
    rights_snapshot "$folder"
    models_load "$journal"
    local_charge
    start="$(rank_take "$state" "$journal")" || refuse "model rank locked: retry later"
    brief_current="$brief"
    # Resume: a new session restarts from the work already present (git status,
    # diff, log), without conversation history.
    resume() {
        if [ "$resumed" = 1 ]; then return 0; fi
        resumed=1
        local c
        c="$(mktemp)"
        cat "$brief_current" >"$c"
        printf '\n\nRESUME: a previous session was interrupted. Read git status, git diff and git log in the folder, check this work against the brief above, fix what deviates from it and finish what is missing.\n' >>"$c"
        brief_current="$c"
    }
    model_order "$start"
    i=0
    while [ "$i" -lt "${#ORDER[@]}" ]; do
        m="${ORDER[$i]}"
        if [ "$m" != "$network_for" ]; then network_for="$m"; network_n=0; fi
        if model_excluded "$m"; then
            model_requested_excluded "$m" "$(model_exclusion_cause "$m")" "$journal"
            i=$(( i + 1 ))
            continue
        fi
        model_requested_chosen "$m" "$journal"
        echo "=== model opencode/$m start $(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$journal"
        offset="$(wc -c <"$journal")"
        opencode_launch "$folder" "$m" "$brief_current" "$journal" "$state"
        pid=$!
        started=0
        discard=0
        start_t="$(date +%s)"
        while kill -0 "$pid" 2>/dev/null; do
            if session_fatal_error "$pid" "$journal" "$offset" "$m" "$folder"; then discard=1; break; fi
            if [ "$(wc -c <"$journal")" -gt "$offset" ]; then
                new="$(tail -c "+$(( offset + 1 ))" "$journal" 2>/dev/null || true)"
                if [ "$(error_cause "$(error_lines "$new")")" != "quota" ]; then started=1; break; fi
            fi
            if [ $(( $(date +%s) - start_t )) -ge "$SILENCE" ]; then break; fi
            sleep "${DEVZONE_AGENT_STEP:-1}"
        done
        if [ "$discard" = 1 ]; then resume; i=$(( i + 1 )); continue; fi
        if kill -0 "$pid" 2>/dev/null && [ "$started" = 0 ]; then
            pkill -P "$pid" 2>/dev/null || true
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            rights_verify "$folder"
            echo "=== opencode/$m silent at start: excluded 1 h, next model" >>"$journal"
            model_exclude "$m" mute
            model_requested_excluded "$m" mute "$journal"
            resume
            i=$(( i + 1 ))
            continue
        fi
        # Frozen session: nothing written for FROZEN seconds during the run -> stopped,
        # then a new session with the resume brief.
        freeze=0
        if kill -0 "$pid" 2>/dev/null && [ "$started" = 1 ]; then
            last="$(date +%s)"
            size="$(wc -c <"$journal")"
            while kill -0 "$pid" 2>/dev/null; do
                if session_fatal_error "$pid" "$journal" "$offset" "$m" "$folder"; then discard=1; break; fi
                sleep "${DEVZONE_AGENT_STEP:-1}"
                now="$(date +%s)"
                if [ "$(wc -c <"$journal")" -gt "$size" ]; then
                    size="$(wc -c <"$journal")"
                    last="$now"
                fi
                if [ $(( now - last )) -gt "$FROZEN" ]; then
                    pkill -P "$pid" 2>/dev/null || true
                    kill "$pid" 2>/dev/null || true
                    wait "$pid" 2>/dev/null || true
                    rights_verify "$folder"
                    freeze=1
                    break
                fi
            done
        fi
        if [ "$discard" = 1 ]; then resume; i=$(( i + 1 )); continue; fi
        if [ "$freeze" = 1 ]; then
            echo "=== opencode/$m frozen ($FROZEN s without writing): new session, next model" >>"$journal"
            resume
            i=$(( i + 1 ))
            continue
        fi
        code=0
        wait "$pid" || code=$?
        rights_verify "$folder"
        # Only the output of this attempt counts: an error of a previous model must not
        # condemn the next one. Only its last 30 lines are read, and only when the exit
        # code is non-zero or opencode wrote its own error line: a printed "Free usage
        # limit" in text that ends normally is not a failure.
        output="$(tail -c "+$(( offset + 1 ))" "$journal" 2>/dev/null || true)"
        recent="$(printf '%s\n' "$output" | tail -n 30)"
        if [ "$code" -ne 0 ] || printf '%s\n' "$recent" | grep -qE "$ERROR_LINE"; then
            if printf '%s\n' "$recent" | grep -qE "$ERRORS"; then
                cause="$(error_cause "$(printf '%s\n' "$recent" | grep -oE "$ERRORS" | tail -1)")"
                # A network error is kept only if the network is down now: otherwise it
                # would repeat endlessly on a good network.
                if [ "$cause" = reseau ] && network_reachable; then
                    echo "=== network error reported but network reachable: treated as other" >>"$journal"
                    cause=autre
                fi
                if [ "$cause" = reseau ] && [ "$network_n" -ge "$NETWORK_RETRIES" ]; then
                    echo "=== opencode/$m network down $NETWORK_RETRIES times: next model, no exclusion" >>"$journal"
                    cause=autre
                fi
                if [ "$cause" = reseau ]; then
                    if network_wait; then
                        network_n=$(( network_n + 1 ))
                        resume
                        continue
                    fi
                    echo "=== network unavailable" >>"$journal"
                    exit 4
                fi
                if [ "$cause" = autre ]; then
                    echo "=== opencode/$m error, no exclusion: next model" >>"$journal"
                else
                    model_exclude "$m" "$cause"
                    model_requested_excluded "$m" "$cause" "$journal"
                    echo "=== opencode/$m excluded ($(cause_label "$cause"), $(exclusion_label "$cause")): next model" >>"$journal"
                fi
                resume
                i=$(( i + 1 ))
                continue
            fi
        fi
        if [ "$code" -ne 0 ]; then
            echo "=== opencode/$m stopped on error (code $code): next model" >>"$journal"
            resume
            i=$(( i + 1 ))
            continue
        fi
        echo "=== end with opencode/$m (code $code)" >>"$journal"
        exit "$code"
    done
    echo "=== no free model available" >>"$journal"
    exit 3
}
case "${1:-}" in
    status) agent_pod_status ;;
    state) if [ "${2:-}" = "--json" ]; then exec bash "$ICI/agent-state-json.sh"; else agent_state; fi ;;
    release)
        [ -n "${2:-}" ] || { agent_help >&2; exit 2; }
        exclusion_clear "$2"
        ;;
    -h | --help | help) agent_help ;;
    "")
        agent_help
        exit 2
        ;;
    *)
        if [ "${1:-}" = "--model" ]; then [ -n "${2:-}" ] || { agent_help >&2; exit 2; }; MODEL_LIST="$2"; shift 2; fi
        if [ "${1:-}" = "--pod" ]; then
            [ -z "$MODEL_LIST" ] || refuse "--model is not supported with --pod"
            shift
            if [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
                agent_help >&2
                exit 2
            fi
            agent_pod_launch "$1" "$2"
        fi
        local_mode=0
        if [ "${1:-}" = "--local" ]; then
            local_mode=1
            shift
        fi
        if [ "$#" -lt 2 ]; then
            agent_help >&2
            exit 2
        fi
        if [ "$local_mode" = 0 ] && workspace_available; then
            code=0
            agent_workspace "$1" "$2" || code=$?
            exit "$code"
        fi
        agent_launch "$1" "$2"
        ;;
esac
