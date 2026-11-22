#!/usr/bin/env bats
# rename-legacy-files.sh (#733, lot 3): each file and folder written under its
# former French name is renamed once, with its content. A new name that already
# exists is never overwritten, two folders with both names are merged, a second
# run changes nothing. The state key
# plateforme= of .devzone.modules becomes platform= (lot 4), same rules.

setup() {
    bats_require_minimum_version 1.5.0
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
    [ "$(cat "$DEVZONE_ROOT/.devzone.workspace-ports/relays/3000")" = "3000" ]
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

@test "rename-legacy-files: the ia= line becomes ai= with its value" {
    printf 'ia=on\n' >"$DEVZONE_ROOT/.devzone.modules"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$output" = "devzone : ia= renamed to ai=" ]
    [ "$(cat "$DEVZONE_ROOT/.devzone.modules")" = "ai=on" ]
    printf 'ia=off\n' >"$DEVZONE_ROOT/.devzone.modules"
    bash "$SCRIPT" >/dev/null
    [ "$(cat "$DEVZONE_ROOT/.devzone.modules")" = "ai=off" ]
}

@test "rename-legacy-files: the old ia= line is dropped when ai= exists" {
    printf 'ai=off\nia=on\n' >"$DEVZONE_ROOT/.devzone.modules"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(cat "$DEVZONE_ROOT/.devzone.modules")" = "ai=off" ]
}

@test "rename-legacy-files: the other lines are unchanged by the ia= migration" {
    printf 'kubernetes=on\nia=on\ngitlab=off\nports=3000\n' >"$DEVZONE_ROOT/.devzone.modules"
    printf 'kubernetes=on\nai=on\ngitlab=off\nports=3000\n' >"$T/expected"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    cmp -s "$T/expected" "$DEVZONE_ROOT/.devzone.modules"
}

@test "rename-legacy-files: a second run after the ia= migration changes nothing" {
    printf 'ia=on\nplateforme=github\n' >"$DEVZONE_ROOT/.devzone.modules"
    bash "$SCRIPT" >/dev/null
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(cat "$DEVZONE_ROOT/.devzone.modules")" = "$(printf 'ai=on\nplatform=github')" ]
}

@test "rename-legacy-files: a key that only starts like ia is left alone" {
    printf 'iam=on\nmedia=on\n' >"$DEVZONE_ROOT/.devzone.modules"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(cat "$DEVZONE_ROOT/.devzone.modules")" = "$(printf 'iam=on\nmedia=on')" ]
}

@test "rename-legacy-files: the failure marker of the AI module is renamed" {
    echo "npm log" >"$DEVZONE_ROOT/.devzone.modules-failed-ia"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -e "$DEVZONE_ROOT/.devzone.modules-failed-ia" ]
    [ "$(cat "$DEVZONE_ROOT/.devzone.modules-failed-ai")" = "npm log" ]
}

@test "devzone: a state with ia=on migrated at the startup is read as ai on" {
    printf 'ia=on\nkubernetes=off\n' >"$DEVZONE_ROOT/.devzone.modules"
    bash "$SCRIPT" >/dev/null
    run bash "$BATS_TEST_DIRNAME/../../.devcontainer/devzone" is-enabled ai
    [ "$status" -eq 0 ]
}

# ---- #774, lot 4: watcher folders, state backup, AI measures, packages marker

# Fake port watcher: a script named ports-workspace.sh, as the real one, started
# in the background. $1 = state folder; $2 = "ignore" to ignore SIGTERM.
fake_watcher() {
    local d="$1" ignore="${2:-}" script="$T/ports-workspace.sh"
    {
        echo '#!/usr/bin/env bash'
        if [ "$ignore" = ignore ]; then
            echo "trap '' TERM"
        else
            echo "trap 'rm -rf \"$d/verrou\" \"$d/pid\"; exit 0' TERM"
        fi
        echo 'while :; do sleep 0.1; done'
    } >"$script"
    bash "$script" &
    WATCHER=$!
    echo "$WATCHER" >"$d/pid"
}

watcher_tree() {
    local d="$DEVZONE_ROOT/.devzone.workspace-ports"
    mkdir -p "$d/relais" "$d/pris" "$d/verrou"
    echo "4242" >"$d/relais/3000"
    : >"$d/pris/8080"
    echo "1" >"$d/verrou/pid"
    echo "log" >"$d/journal.log"
}

@test "rename-legacy-files: the watcher folders relais, pris and verrou become relays, taken and lock" {
    watcher_tree
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    local d="$DEVZONE_ROOT/.devzone.workspace-ports"
    [ "$(cat "$d/relays/3000")" = "4242" ]
    [ -e "$d/taken/8080" ]
    [ "$(cat "$d/lock/pid")" = "1" ]
    [ "$(cat "$d/journal.log")" = "log" ]
    [ ! -e "$d/relais" ] && [ ! -e "$d/pris" ] && [ ! -e "$d/verrou" ]
    [[ "$output" == *"$d/relais renamed to $d/relays"* ]] || false
}

@test "rename-legacy-files: an existing relays folder is never overwritten" {
    watcher_tree
    local d="$DEVZONE_ROOT/.devzone.workspace-ports"
    mkdir -p "$d/relays"
    echo "new" >"$d/relays/3000"
    echo "5555" >"$d/relais/9000"
    run --separate-stderr bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(cat "$d/relays/3000")" = "new" ]
    [ "$(cat "$d/relais/3000")" = "4242" ]
    [ "$(cat "$d/relays/9000")" = "5555" ]
    [[ "$stderr" == *"$d/relais/3000 kept: $d/relays/3000 already exists"* ]] || false
}

@test "rename-legacy-files: a second run after the watcher folders migration changes nothing" {
    watcher_tree
    bash "$SCRIPT" >/dev/null
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(cat "$DEVZONE_ROOT/.devzone.workspace-ports/relays/3000")" = "4242" ]
}

@test "rename-legacy-files: a running port watcher is stopped before its folders are renamed" {
    watcher_tree
    local d="$DEVZONE_ROOT/.devzone.workspace-ports"
    fake_watcher "$d"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    ! kill -0 "$WATCHER" 2>/dev/null || false
    [[ "$output" == *"port watcher stopped to rename its folders, restart it: devzone workspace ports start"* ]] || false
    [ "$(cat "$d/relays/3000")" = "4242" ]
    [ ! -e "$d/relais" ]
    [ ! -e "$d/pid" ]
    run bash "$SCRIPT"
    [ -z "$output" ]
}

@test "rename-legacy-files: a port watcher that does not stop leaves its folders untouched" {
    watcher_tree
    local d="$DEVZONE_ROOT/.devzone.workspace-ports"
    fake_watcher "$d" ignore
    run --separate-stderr bash "$SCRIPT"
    kill -9 "$WATCHER" 2>/dev/null || true
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"port watcher (pid $WATCHER) still running"* ]] || false
    [ "$(cat "$d/relais/3000")" = "4242" ]
    [ ! -e "$d/relays" ]
}

@test "rename-legacy-files: a pid file of another process is never signalled" {
    watcher_tree
    local d="$DEVZONE_ROOT/.devzone.workspace-ports"
    sleep 30 &
    local other=$!
    echo "$other" >"$d/pid"
    run bash "$SCRIPT"
    local alive=0
    kill -0 "$other" 2>/dev/null && alive=1
    kill "$other" 2>/dev/null || true
    [ "$status" -eq 0 ]
    [ "$alive" -eq 1 ]
    [ "$(cat "$d/relays/3000")" = "4242" ]
}

@test "rename-legacy-files: the state backup .prec becomes .prev with its content" {
    printf 'ai=on\n' >"$DEVZONE_ROOT/.devzone.modules.prec"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$output" = "devzone : $DEVZONE_ROOT/.devzone.modules.prec renamed to $DEVZONE_ROOT/.devzone.modules.prev" ]
    [ "$(cat "$DEVZONE_ROOT/.devzone.modules.prev")" = "ai=on" ]
    [ ! -e "$DEVZONE_ROOT/.devzone.modules.prec" ]
    run bash "$SCRIPT"
    [ -z "$output" ]
}

@test "rename-legacy-files: an existing .devzone.modules.prev is never overwritten" {
    echo "old" >"$DEVZONE_ROOT/.devzone.modules.prec"
    echo "new" >"$DEVZONE_ROOT/.devzone.modules.prev"
    run --separate-stderr bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(cat "$DEVZONE_ROOT/.devzone.modules.prev")" = "new" ]
    [ "$(cat "$DEVZONE_ROOT/.devzone.modules.prec")" = "old" ]
    [[ "$stderr" == *"kept, $DEVZONE_ROOT/.devzone.modules.prev already exists"* ]] || false
}

@test "rename-legacy-files: ia-mesures.json becomes ai-measures.json with its content" {
    mkdir -p "$HOME/.config/devzone"
    echo '{"m":{"reussite":1}}' >"$HOME/.config/devzone/ia-mesures.json"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(cat "$HOME/.config/devzone/ai-measures.json")" = '{"m":{"reussite":1}}' ]
    [ ! -e "$HOME/.config/devzone/ia-mesures.json" ]
    run bash "$SCRIPT"
    [ -z "$output" ]
}

@test "rename-legacy-files: an existing ai-measures.json is never overwritten" {
    mkdir -p "$HOME/.config/devzone"
    echo old >"$HOME/.config/devzone/ia-mesures.json"
    echo new >"$HOME/.config/devzone/ai-measures.json"
    run --separate-stderr bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(cat "$HOME/.config/devzone/ai-measures.json")" = new ]
    [ "$(cat "$HOME/.config/devzone/ia-mesures.json")" = old ]
    [[ "$stderr" == *"kept"* ]] || false
}

@test "rename-legacy-files: the packages marker devzone-paquets.maj becomes devzone-packages.updated" {
    echo "2026-11-22" >"$DEVZONE_TMP_DIR/devzone-paquets.maj"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(cat "$DEVZONE_TMP_DIR/devzone-packages.updated")" = "2026-11-22" ]
    [ ! -e "$DEVZONE_TMP_DIR/devzone-paquets.maj" ]
    run bash "$SCRIPT"
    [ -z "$output" ]
}

@test "rename-legacy-files: an existing devzone-packages.updated is never overwritten" {
    echo old >"$DEVZONE_TMP_DIR/devzone-paquets.maj"
    echo new >"$DEVZONE_TMP_DIR/devzone-packages.updated"
    run --separate-stderr bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(cat "$DEVZONE_TMP_DIR/devzone-packages.updated")" = new ]
    [ "$(cat "$DEVZONE_TMP_DIR/devzone-paquets.maj")" = old ]
}
