#!/usr/bin/env bats
# check-names.sh (#716): a tracked path with a French word in its name fails,
# .github/ is not checked. The former user data names fail too (#733: they are
# renamed by rename-legacy-files.sh, the allowlist no longer holds them).

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/ci/check-names.sh"
    REPO="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$REPO/manage/scripts/ci" "$REPO/.github/workflows"
    cp "$SCRIPT" "$REPO/manage/scripts/ci/check-names.sh"
    git -C "$REPO" init -q
}

@test "check-names: English names are accepted" {
    : >"$REPO/manage/scripts/uninstall.sh"
    : >"$REPO/state.sh"
    run bash "$REPO/manage/scripts/ci/check-names.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == "names check: "*" paths ok" ]] || false
}

@test "check-names: a French file name fails with the path and the word" {
    : >"$REPO/manage/scripts/desinstaller.sh"
    run bash "$REPO/manage/scripts/ci/check-names.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"manage/scripts/desinstaller.sh: desinstaller"* ]] || false
}

@test "check-names: a French folder name fails" {
    mkdir -p "$REPO/catalogue"
    : >"$REPO/catalogue/app.sh"
    run bash "$REPO/manage/scripts/ci/check-names.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"catalogue/app.sh: catalogue"* ]] || false
}

@test "check-names: a former user data name fails, .github/ is not checked" {
    : >"$REPO/.devzone.paquets"
    : >"$REPO/.github/workflows/fonctionnel.yml"
    run bash "$REPO/manage/scripts/ci/check-names.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *".devzone.paquets: paquets"* ]] || false
    [[ "$output" != *"fonctionnel"* ]] || false
}
