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
