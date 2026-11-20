#!/usr/bin/env bats
# Tests of manage/test/journal-error.sh (#652): the error lines of a build log
# are printed with their line numbers before its tail, a log without error
# prints only its tail, an absent log prints nothing and returns 0, and the
# function never changes the caller exit code.

setup() {
    SOURCE="$BATS_TEST_DIRNAME/journal-error.sh"
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

# Fake build command: counts its runs in $FAKE_RUNS, prints the line of the
# run (FAKE_OUT_1, FAKE_OUT_2...) and fails unless the line is "ok".
fake_build() {
    cat >"$BATS_TEST_TMPDIR/build" <<'FAKE'
#!/usr/bin/env bash
n=$(( $(cat "$FAKE_RUNS" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$FAKE_RUNS"
var="FAKE_OUT_$n"
echo "${!var:-ok}"
[ "${!var:-ok}" = ok ]
FAKE
    chmod +x "$BATS_TEST_TMPDIR/build"
    export FAKE_RUNS="$BATS_TEST_TMPDIR/runs"
    export BUILD_RETRY_WAIT=0
    : >"$FAKE_RUNS"
}

@test "build_with_retry: success on the first run, no retry" {
    . "$SOURCE"
    fake_build
    run build_with_retry "$BATS_TEST_TMPDIR/log" "$BATS_TEST_TMPDIR/build"
    [ "$status" -eq 0 ]
    [ "$(cat "$FAKE_RUNS")" = 1 ]
    [[ "$output" != *"retry"* ]] || false
}

@test "build_with_retry: corrupt archive once, then success: one retry, message, code 0" {
    . "$SOURCE"
    fake_build
    export FAKE_OUT_1="Stop! The archive was corrupt and has been removed!"
    run build_with_retry "$BATS_TEST_TMPDIR/log" "$BATS_TEST_TMPDIR/build"
    [ "$status" -eq 0 ]
    [ "$(cat "$FAKE_RUNS")" = 2 ]
    [[ "$output" == *"one retry of the build"* ]] || false
    grep -q "retry of the build in 0s: corrupt download" "$BATS_TEST_TMPDIR/log"
}

@test "build_with_retry: corrupt archive twice: failure kept, never a third run" {
    . "$SOURCE"
    fake_build
    export FAKE_OUT_1="The archive was corrupt" FAKE_OUT_2="The archive was corrupt"
    run build_with_retry "$BATS_TEST_TMPDIR/log" "$BATS_TEST_TMPDIR/build"
    [ "$status" -ne 0 ]
    [ "$(cat "$FAKE_RUNS")" = 2 ]
}

@test "build_with_retry: another error: no retry, failure kept" {
    . "$SOURCE"
    fake_build
    export FAKE_OUT_1="ERROR: Feature failed to install"
    run build_with_retry "$BATS_TEST_TMPDIR/log" "$BATS_TEST_TMPDIR/build"
    [ "$status" -ne 0 ]
    [ "$(cat "$FAKE_RUNS")" = 1 ]
    [[ "$output" != *"retry"* ]] || false
}

@test "build_with_retry: a corrupt line already in the log before the run does not count" {
    . "$SOURCE"
    fake_build
    echo "The archive was corrupt (old run)" >"$BATS_TEST_TMPDIR/log"
    export FAKE_OUT_1="ERROR: something else"
    run build_with_retry "$BATS_TEST_TMPDIR/log" "$BATS_TEST_TMPDIR/build"
    [ "$status" -ne 0 ]
    [ "$(cat "$FAKE_RUNS")" = 1 ]
}

@test "build_with_retry: the retry waits BUILD_RETRY_WAIT seconds (default 120), announced in the message" {
    . "$SOURCE"
    fake_build
    export FAKE_OUT_1="The archive was corrupt"
    export BUILD_RETRY_WAIT=1
    start="$(date +%s)"
    run build_with_retry "$BATS_TEST_TMPDIR/log" "$BATS_TEST_TMPDIR/build"
    [ "$status" -eq 0 ]
    [ $(( $(date +%s) - start )) -ge 1 ]
    [[ "$output" == *"in 1s"* ]] || false
    grep -q 'BUILD_RETRY_WAIT:-120' "$RACINE/manage/test/journal-error.sh" 2>/dev/null || grep -q 'BUILD_RETRY_WAIT:-120' "$SOURCE"
}

@test "build_with_retry: an absent log gives no shell error" {
    . "$SOURCE"
    fake_build
    run build_with_retry "$BATS_TEST_TMPDIR/not-yet.log" "$BATS_TEST_TMPDIR/build"
    [[ "$output" != *"No such file"* ]] || false
}
