#!/usr/bin/env bats
# rename-legacy-files.sh (#733, lot 3): each file and folder written under its
# former French name is renamed once, with its content. A new name that already
# exists is never overwritten, a second run changes nothing.

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
    echo "relay" >"$DEVZONE_TMP_DIR/devzone-relais-docker.echec"
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
    [ "$(cat "$DEVZONE_TMP_DIR/devzone-relay.failed")" = "relay" ]
    [ "$(cat "$DEVZONE_TMP_DIR/devzone-packages.failed")" = "packages" ]
    [ ! -e "$DEVZONE_ROOT/.devzone.paquets" ]
    [ ! -e "$DEVZONE_ROOT/.devzone.sauvegarde" ]
    [ ! -e "$DEVZONE_ROOT/.devzone.ports-workspace" ]
    [ ! -e "$DEVZONE_ROOT/.devzone.etat" ]
    [ ! -e "$DEVZONE_ROOT/.devzone.catalogue-veilleur" ]
    [ ! -e "$DEVZONE_ROOT/.devzone.modules-echec-gitlab" ]
    [ ! -e "$HOME/.claude/skills/devzone/.devzone-empreinte" ]
    [ ! -e "$DEVZONE_TMP_DIR/devzone-relais-docker.echec" ]
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
