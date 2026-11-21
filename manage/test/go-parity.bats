#!/usr/bin/env bats
# Parity of the Go binary (cmd/devzone) with the bash entry point (#711): for
# each command ported to Go, the standard output, the standard error and the
# exit status are the same as those of manage/devzone. The binary is built once
# for the file; without go, the file is skipped.

setup_file() {
    if ! command -v go >/dev/null 2>&1; then
        skip "go is not installed"
    fi
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export DZ_GO="$BATS_FILE_TMPDIR/dz"
    (cd "$RACINE" && go build -o "$DZ_GO" ./cmd/devzone) || { echo "go build failed"; return 1; }
}

setup() {
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CLI="$RACINE/manage/devzone"
    # Absolute path: the binary finds the package.json of the checkout through it
    export DEVZONE_BASH_ENTRY="$CLI"
    cd "$BATS_TEST_TMPDIR" || return 1
}

# parite <args...> : runs manage/devzone, then the binary, with the same
# arguments; fails when the status, the standard output or the standard error differ
parite() {
    local t="$BATS_TEST_TMPDIR" st_bash=0 st_go=0
    bash "$CLI" "$@" >"$t/bash.out" 2>"$t/bash.err" || st_bash=$?
    "$DZ_GO" "$@" >"$t/go.out" 2>"$t/go.err" || st_go=$?
    [ "$st_go" -eq "$st_bash" ] || { echo "status for [$*]: bash $st_bash, go $st_go"; return 1; }
    cmp "$t/bash.out" "$t/go.out" || { echo "stdout for [$*] differs"; diff "$t/bash.out" "$t/go.out"; return 1; }
    cmp "$t/bash.err" "$t/go.err" || { echo "stderr for [$*] differs"; diff "$t/bash.err" "$t/go.err"; return 1; }
}

@test "go-parity: --version" {
    parite --version
    run "$DZ_GO" --version
    [ "$status" -eq 0 ]
}

@test "go-parity: -v" {
    parite -v
}

@test "go-parity: help" {
    parite help
    run "$DZ_GO" help
    [ "$status" -eq 0 ]
}

@test "go-parity: -h" {
    parite -h
}

@test "go-parity: --help" {
    parite --help
}

@test "go-parity: no argument shows the help" {
    parite
}

@test "go-parity: help with an argument is delegated, same output" {
    parite help extra
}

@test "go-parity: renamed option refused by bash, same message and status" {
    parite --version --oui
}
