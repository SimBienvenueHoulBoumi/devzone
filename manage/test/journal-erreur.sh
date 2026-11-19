#!/usr/bin/env bash
# Build log diagnostics (#652): a container build often fails far above the
# end of the log, so print the lines carrying "ERROR" or "failed to" (with
# their line numbers, at most 20) and then the tail (60 lines). Sourced by
# manage/test/fonctionnel.sh and manage/test/cli-terminal.sh. The function is
# silent when the log is absent and never changes the caller exit code.

# print_log_errors <log> [tail-lines] [max-error-lines]
print_log_errors() {
    local log="$1" tail_lines="${2:-60}" max_errors="${3:-20}" errors
    [ -f "$log" ] || return 0
    errors="$(grep -nE 'ERROR|failed to' "$log" | head -n "$max_errors")"
    if [ -n "$errors" ]; then
        printf '%s\n' "$errors" | sed 's/^/    /'
    fi
    tail -n "$tail_lines" "$log" | sed 's/^/    /'
    return 0
}

# build_with_retry <log> <command...> (#685): runs the build command with its
# output appended to <log>. When it fails and the NEW part of the log shows a
# corrupt download ("The archive was corrupt", SDKMAN), the command runs once
# more, never twice: a second failure, or any other error, is returned as is,
# so a real failure is never hidden. Returns the exit code of the last run.
build_with_retry() {
    local log="$1" start code=0
    shift
    start="$(wc -c <"$log" 2>/dev/null || echo 0)"
    "$@" >>"$log" 2>&1 && return 0
    code=$?
    if tail -c "+$((start + 1))" "$log" 2>/dev/null | grep -q 'archive was corrupt'; then
        echo "⚠ corrupt download in the build log (#685): one retry of the build"
        echo "=== retry of the build: corrupt download ===" >>"$log"
        "$@" >>"$log" 2>&1 && return 0
        code=$?
    fi
    return "$code"
}
