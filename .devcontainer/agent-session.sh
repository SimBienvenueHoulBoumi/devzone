#!/usr/bin/env bash
# Session of the agent supervisor: opencode configuration, shared rank, journal,
# state (#328). Library sourced by agent.sh: no command is launched here.

# Journal path of a folder in workspace/.agents/: outside the repo, ignored by git.
journal_of() {
    echo "$RACINE/workspace/.agents/$(basename "$1").log"
}

# Last write time (epoch), GNU (stat -c) or BSD/macOS (stat -f).
mtime() {
    if stat -c %Y "$1" >/dev/null 2>&1; then
        stat -c %Y "$1"
    else
        stat -f %m "$1"
    fi
}

# Readable UTC date of an epoch, GNU then BSD date: shown by devzone agent etat.
utc_time() {
    if date -u -d "@$1" '+%Y-%m-%d %H:%M:%S' >/dev/null 2>&1; then
        date -u -d "@$1" '+%Y-%m-%d %H:%M:%S'
    else
        date -u -r "$1" '+%Y-%m-%d %H:%M:%S'
    fi
}

# Lock trace in the agent journal ($AGENT_JOURNAL, set by agent.sh): one line when
# taken and one when released, with the clock and the pid, to diagnose simultaneous
# launches of the rank in CI (#421). Without a journal, nothing is written. An
# optional mention (second argument) gives the path, the age or the pid read.
lock_trace() {
    local d
    [ -n "${AGENT_JOURNAL:-}" ] || return 0
    d="$(date +%s.%N 2>/dev/null)" || d=""
    case "$d" in "" | *N*) d="$(date +%s)" ;; esac
    echo "=== lock $1 $d pid $$${2:+ $2}" >>"$AGENT_JOURNAL"
}

# Shared rank lock: two simultaneous launches must not start on the same model.
# mkdir is atomic and present everywhere (flock is missing on macOS); only the age
# of the lock decides (#377), the pid written being a diagnostic detail only: a pid
# read from another container of the volume does not exist here.
# When flock exists, the rank section is also taken under its lock on rang.lock
# (#421): if two mkdir succeeded, flock still serializes the read and the write of
# the rank. Each branch is traced (mkdir failure, purge, taking) to establish in CI
# which of the two launches succeeded in mkdir.
lock_take() {
    local end age lock_pid
    end=$(( $(date +%s) + ${DEVZONE_AGENT_VERROU_MAX:-10} ))
    while ! mkdir "$AGENT_ETAT/verrou" 2>/dev/null; do
        # A lock is orphaned only by its age: the rank is held for a few milliseconds,
        # 30 s can only be a stop to take over; otherwise wait, then give up (code 1).
        age=""
        if [ -d "$AGENT_ETAT/verrou" ]; then
            age="$(mtime "$AGENT_ETAT/verrou" 2>/dev/null)" || age=""
        fi
        lock_pid="$(cat "$AGENT_ETAT/verrou/pid" 2>/dev/null)" || lock_pid=""
        lock_trace "mkdir failed" "age=${age:-unknown} lock-pid=${lock_pid:-none}"
        if [ -n "$age" ] && [ "$(( $(date +%s) - age ))" -gt 30 ]; then
            rm -f "$AGENT_ETAT/verrou/pid"
            if rmdir "$AGENT_ETAT/verrou" 2>/dev/null; then
                lock_trace "purged" "age=$age"
                continue
            fi
        fi
        if [ "$(date +%s)" -ge "$end" ]; then return 1; fi
        sleep 1
    done
    # pid before flock: the other agent never removes the folder while we wait on
    # rang.lock, otherwise our pid write would fail with ENOENT.
    echo "$$" >"$AGENT_ETAT/verrou/pid"
    if command -v flock >/dev/null 2>&1; then
        # exec in an if makes a failure a condition instead of killing the shell
        # (bash 3.2 and GNU alike); without flock, mkdir remains the only guard (macOS).
        if { exec 9>"$AGENT_ETAT/rang.lock"; } && flock -w "${DEVZONE_AGENT_VERROU_MAX:-10}" 9; then
            AGENT_LOCK_FLOCK=1
        else
            lock_release
            return 1
        fi
    fi
    lock_trace taken "path=$AGENT_ETAT/verrou"
}

# Releases the shared rank taken by lock_take: removes the pid, then the folder, only
# when this lock belongs to the calling agent (pid in the file == $$). A lock held by
# another agent is never removed here. flock (#421) is released in every case, even
# when the pid read does not match: otherwise the next caller would stay blocked on
# rang.lock.
lock_release() {
    local pid
    pid="$(cat "$AGENT_ETAT/verrou/pid" 2>/dev/null)" || pid=""
    if [ "$pid" = "$$" ]; then
        rm -f "$AGENT_ETAT/verrou/pid"
        rmdir "$AGENT_ETAT/verrou" 2>/dev/null || true
        lock_trace released
    fi
    if [ "${AGENT_LOCK_FLOCK:-0}" = 1 ]; then
        flock -u 9 2>/dev/null || true
        exec 9>&-
        AGENT_LOCK_FLOCK=0
    fi
}

# Takes the shared rank and returns the start of the rotation (#421). The rank
# advances only when no requested model is available (#420). The "=== rank" line is
# written to the journal in every case. Called in a command substitution: the lock is
# taken and released in that same process.
rank_take() {
    local state="$1" journal="$2" start
    lock_take || return 1
    start=$(( $(cat "$state/rang" 2>/dev/null || echo 0) % ${#FREE_MODELS[@]} ))
    if [ "$PAUSE_RANK" -gt 0 ]; then sleep "$PAUSE_RANK"; fi
    if modele_rang_avance; then echo $(( start + 1 )) >"$state/rang"; fi
    lock_release
    echo "=== rank $(( start + 1 ))/${#FREE_MODELS[@]}" >>"$journal"
    echo "$start"
}

# Turns permission.edit into an object and adds, last, one deny per rights file (#361):
# the last matching rule wins, so the caller cannot remove it.
rights_edit_deny() {
    local patterns f
    patterns="[]"
    for f in "${DROITS_AGENT[@]}"; do
        patterns="$(jq -c --arg f "$f" '. + [$f, "**/" + $f]' <<<"$patterns")"
    done
    jq -ce --argjson patterns "$patterns" '
        (.permission.edit // "allow") as $e |
        (if ($e | type) == "object" then $e else {"*": $e} end) as $o |
        .permission.edit = (reduce $patterns[] as $k ($o; del(.[$k])) + ($patterns | map({(.): "deny"}) | add))
    ' <<<"$1"
}

# Safe configuration: agent.json by default, completed by OPENCODE_CONFIG_CONTENT when
# it is set. opencode applies the last matching rule: devzone's deny entries are taken
# out of the merge, then added back at the end (the key order of a jq object is the
# insertion order), so the caller can add permissions but never remove a devzone deny.
# ~/bash32 is always protected: the container's bash 3.2 was already replaced by a
# link (#210). The name configurer is kept: agent-rights-gh.bats calls it.
configurer() {
    local def config
    def="$ICI/opencode/agent.json"
    [ -r "$def" ] || refuse "default configuration missing: $def"
    if [ -n "${OPENCODE_CONFIG_CONTENT:-}" ]; then
        config="$(jq -ce -s '
            .[0] as $def | .[1] as $env |
            ($def.permission.bash // {}) as $bashdef |
            ($env.permission.bash // {}) as $bashenv |
            ([ $bashdef | to_entries[] | select(.value == "deny") | .key ]) as $deny |
            (($def * $env)
             | .permission.bash = (($bashdef + $bashenv) | delpaths($deny | map([.])))
             | reduce $deny[] as $k (. ; .permission.bash[$k] = "deny"))
        ' "$def" <(printf '%s' "$OPENCODE_CONFIG_CONTENT"))" ||
            refuse "opencode configuration unreadable: nothing launched"
    else
        config="$(jq -ce . "$def")" || refuse "opencode configuration unreadable: nothing launched"
    fi
    config="$(jq -ce '.permission.bash = ((.permission.bash // {}) + {
        "git commit*": "allow",
        "ln *bash32*": "deny",
        "cp *bash32*": "deny",
        "mv *bash32*": "deny",
        "rm *bash32*": "deny",
        "chmod *bash32*": "deny",
        "install *bash32*": "deny"
    })' <<<"$config")" || refuse "opencode configuration unreadable: nothing launched"
    config="$(rights_edit_deny "$config")" || refuse "opencode configuration unreadable: nothing launched"
    grep -q '"git push\*":"deny"' <<<"$config" || refuse "git push not denied: nothing launched"
    export OPENCODE_CONFIG_CONTENT="$config"
}

# Free models of the installed version, "opencode/" prefix removed:
# "opencode models opencode" may return "opencode/big-pickle".
list_models() {
    local l
    l="$(opencode models opencode 2>/dev/null | sed 's#^opencode/##' |
        grep -E '(-free$|^big-pickle$)' | awk 'NF && !seen[$0]++' || true)"
    if [ -n "$l" ]; then
        printf '%s\n' "$l"
    else
        printf '%s\n' "${FREE_MODELS[@]}"
    fi
}

# Model and start of a session (#308): read only on the last "=== model opencode/"
# line of the supervisor; text written by the model in the journal (a possible
# "opencode/agent.json") is not read.
session_model_start() {
    local line
    line="$(grep '^=== model opencode/' "$1" 2>/dev/null | tail -1 || true)"
    MODEL_SESSION="$(sed -nE 's/^=== model opencode\/([^ ]+) start .*/\1/p' <<<"$line")"
    START_SESSION="$(sed -nE 's/.* start ([^ ]+).*/\1/p' <<<"$line")"
}

# Models asked with devzone agent --modele (#420): the last header line
# "=== --modele : " of the journal, empty when nothing was asked.
session_request() {
    local line
    line="$(grep '^=== --modele : ' "$1" 2>/dev/null | tail -1 || true)"
    REQUEST_SESSION="${line#=== --modele : }"
    if [ "$REQUEST_SESSION" = none ]; then REQUEST_SESSION=""; fi
}

# A session is running (#308) when a live agent.sh process has as first argument (the
# folder, absolute since #287) a path whose name is exactly the journal without ".log";
# a plain folder containing that name is not enough, nor a path that is not an agent
# folder.
session_running() {
    local line folder
    while IFS= read -r line; do
        case "$line" in
            *agent.sh\ *) folder="${line#*agent.sh }" ;;
            *) continue ;;
        esac
        folder="${folder%% *}"
        [ -n "$folder" ] || continue
        if [ "$(basename "$folder")" = "$1" ]; then return 0; fi
    done < <(ps -eo args= 2>/dev/null || true)
    return 1
}

# Known sessions (journal, last model, start, last written) and models excluded
# by the supervisor, with the end time of each exclusion.
agent_state() {
    local f m start last seen=0
    echo "devzone agent: state"
    for f in "$RACINE"/workspace/.agents/*.log; do
        [ -e "$f" ] || continue
        seen=1
        session_model_start "$f"
        m="${MODEL_SESSION:+opencode/$MODEL_SESSION}"
        start="$START_SESSION"
        last="$(utc_time "$(mtime "$f")")"
        session_request "$f"
        echo "  session $(basename "$f"): model ${m:-unknown}${REQUEST_SESSION:+ (requested: $REQUEST_SESSION)}, since ${start:-unknown}, last written $last"
    done
    [ "$seen" = 1 ] || echo "  no session"
    agent_exclusions
    droits_alertes
}
