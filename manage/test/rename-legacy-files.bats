#!/usr/bin/env bats
# rename-legacy-files.sh (#733, lot 3): each file and folder written under its
# former French name is renamed once, with its content. A new name that already
# exists is never overwritten, two folders with both names are merged, a second
# run changes nothing. The state key
# plateforme= of .devzone.modules becomes platform= (lot 4), same rules.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../../.devcontainer/rename-legacy-files.sh"
    T="$BATS_TEST_TMPDIR"
    export DEVZONE_ROOT="$T/devzone"
    export DEVZONE_TMP_DIR="$T/tmp"
    export HOME="$T/home"
    mkdir -p "$DEVZONE_ROOT" "$DEVZONE_TMP_DIR" "$HOME"
}

# Creates every legacy name with a content of its own, and the skill folders
legacy_tree() {
    echo "packages" >"$DEVZONE_ROOT/.devzone.paquets"
    mkdir -p "$DEVZONE_ROOT/.devzone.sauvegarde/20260101-120000"
    echo "backup" >"$DEVZONE_ROOT/.devzone.sauvegarde/20260101-120000/file"
    mkdir -p "$DEVZONE_ROOT/.devzone.ports-workspace/relais"
    echo "3000" >"$DEVZONE_ROOT/.devzone.ports-workspace/relais/3000"
    echo "state" >"$DEVZONE_ROOT/.devzone.etat"
    mkdir -p "$DEVZONE_ROOT/.devzone.catalogue-veilleur"
    echo "watcher" >"$DEVZONE_ROOT/.devzone.catalogue-veilleur/log"
    echo "gitlab" >"$DEVZONE_ROOT/.devzone.modules-echec-gitlab"
    mkdir -p "$HOME/.claude/skills/devzone" "$HOME/.config/opencode/skills/devzone"
    echo "abc" >"$HOME/.claude/skills/devzone/.devzone-empreinte"
    echo "def" >"$HOME/.config/opencode/skills/devzone/.devzone-empreinte"
    echo "packages" >"$DEVZONE_TMP_DIR/devzone-paquets.echec"
}

@test "rename-legacy-files: each legacy file and folder is renamed with its content" {
    legacy_tree
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(cat "$DEVZONE_ROOT/.devzone.packages")" = "packages" ]
    [ "$(cat "$DEVZONE_ROOT/.devzone.backup/20260101-120000/file")" = "backup" ]
    [ "$(cat "$DEVZONE_ROOT/.devzone.workspace-ports/relais/3000")" = "3000" ]
    [ "$(cat "$DEVZONE_ROOT/.devzone.state")" = "state" ]
    [ "$(cat "$DEVZONE_ROOT/.devzone.catalog-watcher/log")" = "watcher" ]
    [ "$(cat "$DEVZONE_ROOT/.devzone.modules-failed-gitlab")" = "gitlab" ]
    [ "$(cat "$HOME/.claude/skills/devzone/.devzone-fingerprint")" = "abc" ]
    [ "$(cat "$HOME/.config/opencode/skills/devzone/.devzone-fingerprint")" = "def" ]
    [ "$(cat "$DEVZONE_TMP_DIR/devzone-packages.failed")" = "packages" ]
    [ ! -e "$DEVZONE_ROOT/.devzone.paquets" ]
    [ ! -e "$DEVZONE_ROOT/.devzone.sauvegarde" ]
    [ ! -e "$DEVZONE_ROOT/.devzone.ports-workspace" ]
    [ ! -e "$DEVZONE_ROOT/.devzone.etat" ]
    [ ! -e "$DEVZONE_ROOT/.devzone.catalogue-veilleur" ]
    [ ! -e "$DEVZONE_ROOT/.devzone.modules-echec-gitlab" ]
    [ ! -e "$HOME/.claude/skills/devzone/.devzone-empreinte" ]
    [ ! -e "$DEVZONE_TMP_DIR/devzone-paquets.echec" ]
}

@test "rename-legacy-files: prints one line per rename" {
    echo "packages" >"$DEVZONE_ROOT/.devzone.paquets"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$output" = "devzone : $DEVZONE_ROOT/.devzone.paquets renamed to $DEVZONE_ROOT/.devzone.packages" ]
}

@test "rename-legacy-files: an existing new name is never overwritten" {
    echo "old" >"$DEVZONE_ROOT/.devzone.paquets"
    echo "new" >"$DEVZONE_ROOT/.devzone.packages"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(cat "$DEVZONE_ROOT/.devzone.packages")" = "new" ]
    [ "$(cat "$DEVZONE_ROOT/.devzone.paquets")" = "old" ]
    [[ "$output" != *"renamed to"* ]] || false
}

@test "rename-legacy-files: a second run changes nothing" {
    legacy_tree
    bash "$SCRIPT" >/dev/null
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(cat "$DEVZONE_ROOT/.devzone.packages")" = "packages" ]
}

@test "rename-legacy-files: nothing to do without legacy names" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$(ls -A "$DEVZONE_ROOT")" ]
}

@test "rename-legacy-files: plateforme= of the state file becomes platform= with its value" {
    printf 'gitlab=on\nplateforme=gitlab\ngitlab_url=http://gitlab.localhost:8929\n' >"$DEVZONE_ROOT/.devzone.modules"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$output" = "devzone : plateforme= renamed to platform=" ]
    grep -qx 'platform=gitlab' "$DEVZONE_ROOT/.devzone.modules"
    ! grep -q '^plateforme=' "$DEVZONE_ROOT/.devzone.modules" || false
    [ "$(ls -A "$DEVZONE_ROOT")" = ".devzone.modules" ]
}

@test "rename-legacy-files: the old plateforme= line is dropped when platform= exists" {
    printf 'platform=github\nplateforme=gitlab\n' >"$DEVZONE_ROOT/.devzone.modules"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(cat "$DEVZONE_ROOT/.devzone.modules")" = "platform=github" ]
}

@test "rename-legacy-files: the other lines of the state file are unchanged" {
    printf 'gitlab=on\ncluster=my-choice\nplateforme=gitlab\ngitlab_url=http://gitlab.localhost:8929\n' >"$DEVZONE_ROOT/.devzone.modules"
    printf 'gitlab=on\ncluster=my-choice\nplatform=gitlab\ngitlab_url=http://gitlab.localhost:8929\n' >"$T/expected"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    cmp -s "$T/expected" "$DEVZONE_ROOT/.devzone.modules"
}

@test "rename-legacy-files: a second run changes the state file no more" {
    printf 'plateforme=gitlab\n' >"$DEVZONE_ROOT/.devzone.modules"
    bash "$SCRIPT" >/dev/null
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(cat "$DEVZONE_ROOT/.devzone.modules")" = "platform=gitlab" ]
}

@test "rename-legacy-files: a missing state file is no error and creates nothing" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$DEVZONE_ROOT/.devzone.modules" ]
}

@test "rename-legacy-files: folders with both names are merged and the old one is removed" {
    mkdir -p "$DEVZONE_ROOT/.devzone.sauvegarde/20260101-120000" "$DEVZONE_ROOT/.devzone.backup/20260102-120000"
    echo "old" >"$DEVZONE_ROOT/.devzone.sauvegarde/20260101-120000/file"
    echo "new" >"$DEVZONE_ROOT/.devzone.backup/20260102-120000/file"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(cat "$DEVZONE_ROOT/.devzone.backup/20260101-120000/file")" = "old" ]
    [ "$(cat "$DEVZONE_ROOT/.devzone.backup/20260102-120000/file")" = "new" ]
    [ ! -e "$DEVZONE_ROOT/.devzone.sauvegarde" ]
    [ "$output" = "devzone : $DEVZONE_ROOT/.devzone.sauvegarde merged into $DEVZONE_ROOT/.devzone.backup" ]
}

@test "rename-legacy-files: a file present on both sides is kept in the old folder" {
    mkdir -p "$DEVZONE_ROOT/.devzone.ports-workspace" "$DEVZONE_ROOT/.devzone.workspace-ports"
    echo "old" >"$DEVZONE_ROOT/.devzone.ports-workspace/3000"
    echo "new" >"$DEVZONE_ROOT/.devzone.workspace-ports/3000"
    echo "moved" >"$DEVZONE_ROOT/.devzone.ports-workspace/5000"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(cat "$DEVZONE_ROOT/.devzone.ports-workspace/3000")" = "old" ]
    [ "$(cat "$DEVZONE_ROOT/.devzone.workspace-ports/3000")" = "new" ]
    [ "$(cat "$DEVZONE_ROOT/.devzone.workspace-ports/5000")" = "moved" ]
    [ ! -e "$DEVZONE_ROOT/.devzone.ports-workspace/5000" ]
    [ -d "$DEVZONE_ROOT/.devzone.ports-workspace" ]
    [[ "$output" == *"$DEVZONE_ROOT/.devzone.ports-workspace/3000 kept: $DEVZONE_ROOT/.devzone.workspace-ports/3000 already exists"* ]] || false
    [[ "$output" != *"merged into"* ]] || false
}

@test "rename-legacy-files: an empty old folder is removed when the new one exists" {
    mkdir -p "$DEVZONE_ROOT/.devzone.sauvegarde" "$DEVZONE_ROOT/.devzone.backup"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -e "$DEVZONE_ROOT/.devzone.sauvegarde" ]
    [ -d "$DEVZONE_ROOT/.devzone.backup" ]
    [ "$output" = "devzone : $DEVZONE_ROOT/.devzone.sauvegarde merged into $DEVZONE_ROOT/.devzone.backup" ]
}

@test "rename-legacy-files: a folder without its new name is renamed as before" {
    mkdir -p "$DEVZONE_ROOT/.devzone.catalogue-veilleur"
    echo "watcher" >"$DEVZONE_ROOT/.devzone.catalogue-veilleur/log"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$output" = "devzone : $DEVZONE_ROOT/.devzone.catalogue-veilleur renamed to $DEVZONE_ROOT/.devzone.catalog-watcher" ]
    [ "$(cat "$DEVZONE_ROOT/.devzone.catalog-watcher/log")" = "watcher" ]
}

@test "rename-legacy-files: a second run after a merge changes nothing" {
    mkdir -p "$DEVZONE_ROOT/.devzone.sauvegarde/a" "$DEVZONE_ROOT/.devzone.backup"
    echo "x" >"$DEVZONE_ROOT/.devzone.sauvegarde/a/file"
    bash "$SCRIPT" >/dev/null
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(cat "$DEVZONE_ROOT/.devzone.backup/a/file")" = "x" ]
}

@test "rename-legacy-files: hidden entries of the old folder are merged" {
    mkdir -p "$DEVZONE_ROOT/.devzone.paquets" "$DEVZONE_ROOT/.devzone.packages"
    echo "hidden" >"$DEVZONE_ROOT/.devzone.paquets/.lock"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(cat "$DEVZONE_ROOT/.devzone.packages/.lock")" = "hidden" ]
    [ ! -e "$DEVZONE_ROOT/.devzone.paquets" ]
}

@test "rename-legacy-files: a file and a folder with the two names are left alone" {
    echo "old" >"$DEVZONE_ROOT/.devzone.etat"
    mkdir -p "$DEVZONE_ROOT/.devzone.state"
    echo "state" >"$DEVZONE_ROOT/.devzone.state/x"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$output" = "devzone : $DEVZONE_ROOT/.devzone.etat kept, $DEVZONE_ROOT/.devzone.state already exists" ]
    [ "$(cat "$DEVZONE_ROOT/.devzone.etat")" = "old" ]
    [ "$(cat "$DEVZONE_ROOT/.devzone.state/x")" = "state" ]
}

@test "rename-legacy-files: no file is lost in a merge with a conflict" {
    mkdir -p "$DEVZONE_ROOT/.devzone.sauvegarde/20260101-120000" "$DEVZONE_ROOT/.devzone.backup/20260101-120000"
    echo "a" >"$DEVZONE_ROOT/.devzone.sauvegarde/20260101-120000/file"
    echo "b" >"$DEVZONE_ROOT/.devzone.backup/20260101-120000/file"
    echo "c" >"$DEVZONE_ROOT/.devzone.sauvegarde/.hidden"
    echo "d" >"$DEVZONE_ROOT/.devzone.sauvegarde/other"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(cat "$DEVZONE_ROOT/.devzone.sauvegarde/20260101-120000/file")" = "a" ]
    [ "$(cat "$DEVZONE_ROOT/.devzone.backup/20260101-120000/file")" = "b" ]
    [ "$(cat "$DEVZONE_ROOT/.devzone.backup/.hidden")" = "c" ]
    [ "$(cat "$DEVZONE_ROOT/.devzone.backup/other")" = "d" ]
    [ ! -e "$DEVZONE_ROOT/.devzone.sauvegarde/other" ]
}
