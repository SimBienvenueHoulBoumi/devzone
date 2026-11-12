#!/usr/bin/env bats
# CI check of the files listed in .english (#502): no French accented
# letters, no frequent French whole words, every listed file must exist.

setup() {
    load commun
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$RACINE/manage/scripts/check-english.sh"
    T="$BATS_TEST_TMPDIR"
    # The script reads .english at the root two levels above its own folder:
    # a copy under $T makes $T the checked root.
    mkdir -p "$T/manage/scripts"
    cp "$SCRIPT" "$T/manage/scripts/check-english.sh"
    cd "$T" || return 1
}

@test "clean file: ok" {
    printf 'clean content\nanother line\n\nlast line\n' >"$T/clean.txt"
    printf '\nclean.txt\n\n' >"$T/.english"
    run bash "$T/manage/scripts/check-english.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "english check: 1 files ok" ]
}

@test "accented letter: fails with path:line" {
    printf 'first line\ncaf\xc3\xa9 au lait\n' >"$T/accents.txt"
    printf 'accents.txt\n' >"$T/.english"
    run bash "$T/manage/scripts/check-english.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *'accents.txt:2: '* ]] || false
}

@test "frequent french word: fails with path:line" {
    printf 'a line with the word %s\n' "$(printf 'p''our')" >"$T/words.txt"
    printf 'words.txt\n' >"$T/.english"
    run bash "$T/manage/scripts/check-english.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *'words.txt:1: '* ]] || false
}

@test "commented line in .english ignored" {
    printf 'clean.txt\n# absent.txt\n' >"$T/.english"
    printf 'clean content\n' >"$T/clean.txt"
    run bash "$T/manage/scripts/check-english.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "english check: 1 files ok" ]
}

@test "listed file missing: fails" {
    printf 'missing.txt\n' >"$T/.english"
    run bash "$T/manage/scripts/check-english.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *'missing.txt'* ]] || false
}
