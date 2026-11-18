#!/usr/bin/env bats
# Tests of manage/test/journal-erreur.sh (#652): the error lines of a build log
# are printed with their line numbers before its tail, a log without error
# prints only its tail, an absent log prints nothing and returns 0, and the
# function never changes the caller exit code.

setup() {
    SOURCE="$BATS_TEST_DIRNAME/journal-erreur.sh"
    LOG="$BATS_TEST_TMPDIR/journal.log"
}

# log_200 <file> [with-error]: 200 lines; with-error puts the error at line 40.
log_200() {
    local f="$1" with_error="${2:-}" i
    : >"$f"
    for i in $(seq 1 200); do
        if [ "$i" -eq 40 ] && [ -n "$with_error" ]; then
            echo 'ERROR: failed to solve: process "x"' >>"$f"
        else
            echo "line $i without error" >>"$f"
        fi
    done
}

@test "error line and tail are both printed" {
    log_200 "$LOG" with-error
    run bash -c '. "$1"; print_log_errors "$2"' bash "$SOURCE" "$LOG"
    [ "$status" -eq 0 ]
    [[ "$output" == *"40:ERROR: failed to solve"* ]] || false
    [[ "$output" == *"line 200 without error"* ]] || false
}

@test "log without error: only the tail is printed" {
    log_200 "$LOG"
    run bash -c '. "$1"; print_log_errors "$2"' bash "$SOURCE" "$LOG"
    [ "$status" -eq 0 ]
    [[ "$output" == *"line 200 without error"* ]] || false
    [ -z "$(grep 'ERROR' <<<"$output")" ]
    [ -z "$(grep 'line 140 ' <<<"$output")" ]
}

@test "absent log: no output, exit code 0" {
    run bash -c '. "$1"; print_log_errors "$2"' bash "$SOURCE" "$BATS_TEST_TMPDIR/absent.log"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "the caller exit code is preserved" {
    log_200 "$LOG" with-error
    run bash -c '. "$1"; print_log_errors "$2"; exit 7' bash "$SOURCE" "$LOG"
    [ "$status" -eq 7 ]
    run bash -c '. "$1"; print_log_errors "$2"; false' bash "$SOURCE" "$LOG"
    [ "$status" -eq 1 ]
    run bash -c '. "$1"; print_log_errors "$2"; true' bash "$SOURCE" "$LOG"
    [ "$status" -eq 0 ]
}

@test "at most 20 error lines are printed" {
    local i
    : >"$LOG"
    for i in $(seq 1 30); do
        echo "ERROR: failed to solve number $i" >>"$LOG"
    done
    for i in $(seq 31 100); do
        echo "line $i without error" >>"$LOG"
    done
    run bash -c '. "$1"; print_log_errors "$2"' bash "$SOURCE" "$LOG"
    [ "$status" -eq 0 ]
    [ "$(grep -c 'ERROR: failed to' <<<"$output")" -eq 20 ]
}
