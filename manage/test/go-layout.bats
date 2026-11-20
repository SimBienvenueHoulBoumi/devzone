#!/usr/bin/env bats
# CI check of the 250-line limit of the Go files (#710):
# manage/scripts/check-go-layout.sh on a temporary git repository under
# BATS_TEST_TMPDIR, never on the real tree (that is the CI's job).

setup() {
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$RACINE/manage/scripts/check-go-layout.sh"
    T="$BATS_TEST_TMPDIR"
    mkdir -p "$T/manage/scripts"
    cp "$SCRIPT" "$T/manage/scripts/check-go-layout.sh"
    git -C "$T" init -q
    cd "$T" || return 1
}

# Writes the Go file $1 with $2 lines
go_file_of() {
    mkdir -p "$(dirname "$T/$1")"
    awk -v n="$2" 'BEGIN { for (i = 1; i <= n; i++) print "// line" }' >"$T/$1"
}

@test "251 lines: refused with path and count" {
    go_file_of internal/big.go 251
    run bash "$T/manage/scripts/check-go-layout.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *'internal/big.go: 251 lines'* ]] || false
}

@test "250 lines: accepted" {
    go_file_of internal/limit_test.go 250
    run bash "$T/manage/scripts/check-go-layout.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "go layout: 1 files ok" ]
}

@test "no Go file: ok" {
    printf 'text only\n' >"$T/notes.txt"
    run bash "$T/manage/scripts/check-go-layout.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "go layout: 0 files ok" ]
}

@test "ignored Go file: not counted" {
    printf 'vendor/\n' >"$T/.gitignore"
    go_file_of vendor/long.go 300
    run bash "$T/manage/scripts/check-go-layout.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "go layout: 0 files ok" ]
}
