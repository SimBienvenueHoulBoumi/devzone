#!/usr/bin/env bats
# check-names.sh (#716): a tracked path with a French word in its name fails,
# the user data files and .github/ are not checked.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/check-names.sh"
    REPO="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$REPO/manage/scripts" "$REPO/.github/workflows"
    cp "$SCRIPT" "$REPO/manage/scripts/check-names.sh"
    git -C "$REPO" init -q
}

@test "check-names: English names are accepted" {
    : >"$REPO/manage/scripts/uninstall.sh"
    : >"$REPO/state.sh"
    run bash "$REPO/manage/scripts/check-names.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == "names check: "*" paths ok" ]] || false
}

@test "check-names: a French file name fails with the path and the word" {
    : >"$REPO/manage/scripts/desinstaller.sh"
    run bash "$REPO/manage/scripts/check-names.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"manage/scripts/desinstaller.sh: desinstaller"* ]] || false
}

@test "check-names: a French folder name fails" {
    mkdir -p "$REPO/catalogue"
    : >"$REPO/catalogue/app.sh"
    run bash "$REPO/manage/scripts/check-names.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"catalogue/app.sh: catalogue"* ]] || false
}

@test "check-names: the user data files and .github/ are not checked" {
    : >"$REPO/.devzone.paquets"
    : >"$REPO/.github/workflows/fonctionnel.yml"
    run bash "$REPO/manage/scripts/check-names.sh"
    [ "$status" -eq 0 ]
}
