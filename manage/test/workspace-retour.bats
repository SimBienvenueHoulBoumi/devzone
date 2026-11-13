#!/usr/bin/env bats
# Rollback and Docker cleanup of the Kubernetes workspace (#403). Fake docker and
# kubectl (see migration.bash): no real Docker volume or cluster is touched.

setup() {
    load migration
    migration_isolate
}

@test "revert: workspace=docker, Docker workstation intact, reminds make shell" {
    echo "workspace=kubernetes" >>"$T/workstation/.devzone.modules"
    ws revert
    [ "$status" -eq 0 ]
    grep -qx "workspace=docker" "$T/workstation/.devzone.modules" || false
    ! grep -q "workspace=kubernetes" "$T/workstation/.devzone.modules" || false
    [[ "$output" == *"make shell"* ]] || false
    [ ! -s "$T/docker.log" ]
    [ ! -s "$T/kubectl.log" ]
    [ -f "$T/workstation/workspace/alpha/a.txt" ]
}

@test "revert and revenir with --bring-back/--rapatrier are equivalent" {
    mkdir -p "$T/pod/workspaces/projets/gamma"
    echo "g" >"$T/pod/workspaces/projets/gamma/g.txt"
    ws revenir --rapatrier
    [ "$status" -eq 0 ]
    [ -f "$T/workstation/workspace/gamma/g.txt" ]
    grep -qx "workspace=docker" "$T/workstation/.devzone.modules" || false
}

@test "revert --bring-back: pod projects copied into ./workspace" {
    mkdir -p "$T/pod/workspaces/projets/gamma" "$T/pod/workspaces/projets/alpha"
    echo "g" >"$T/pod/workspaces/projets/gamma/g.txt"
    echo "changed on pod" >"$T/pod/workspaces/projets/alpha/a.txt"
    ws revert --bring-back
    [ "$status" -eq 0 ]
    [ "$(cat "$T/workstation/workspace/alpha/a.txt")" = "changed on pod" ]
    [ -f "$T/workstation/workspace/gamma/g.txt" ]
    grep -qx "workspace=docker" "$T/workstation/.devzone.modules" || false
    ! grep -q "volume rm" "$T/docker.log" || false
}

@test "revert --bring-back: workstation version saved before being replaced" {
    echo "local work" >"$T/workstation/workspace/alpha/local.txt"
    mkdir -p "$T/pod/workspaces/projets/alpha"
    echo "changed on pod" >"$T/pod/workspaces/projets/alpha/a.txt"
    ws revert --bring-back
    [ "$status" -eq 0 ]
    [[ "$output" == *"project alpha: workstation version saved in .devzone.sauvegarde/"* ]] || false
    backup="$(find "$T/workstation/.devzone.sauvegarde" -mindepth 1 -maxdepth 1 -type d | head -1)"
    [[ "$(basename "$backup")" =~ ^[0-9]{8}-[0-9]{6}$ ]] || false
    [ "$(cat "$backup/workspace/alpha/local.txt")" = "local work" ]
    [ "$(cat "$backup/workspace/alpha/a.txt")" = "a" ]
    [ "$(cat "$T/workstation/workspace/alpha/a.txt")" = "changed on pod" ]
    ! [ -e "$T/workstation/workspace/alpha/local.txt" ] || false
    [ -f "$T/workstation/workspace/beta/b.txt" ]
}

@test "revert --bring-back: copy failed, no switch" {
    echo "workspace=kubernetes" >>"$T/workstation/.devzone.modules"
    mkdir -p "$T/pod/workspaces/projets/alpha"
    export FAKE_CP_FAIL=1
    ws revert --bring-back
    [ "$status" -eq 1 ]
    grep -qx "workspace=kubernetes" "$T/workstation/.devzone.modules" || false
}

@test "revert: unknown option refused" {
    ws revert --all
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown option"* ]] || false
}

@test "clean-docker: without terminal or --yes, refuses, no volume removed" {
    fake_volumes
    ws clean-docker </dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"no terminal"* ]] || false
    [[ "$output" == *"devzone-gh"* ]] || false
    ! grep -q "volume rm" "$T/docker.log" || false
    [ -d "$T/volumes/devzone-gh" ]
    [ -d "$T/volumes/devzone-m2" ]
}

@test "clean-docker --yes: removes only devzone-* volumes" {
    fake_volumes
    mkdir -p "$T/volumes/other-volume"
    ws clean-docker --yes
    [ "$status" -eq 0 ]
    [ ! -d "$T/volumes/devzone-gh" ]
    [ ! -d "$T/volumes/devzone-m2" ]
    [ -d "$T/volumes/other-volume" ]
    ! grep -q "volume rm other-volume" "$T/docker.log" || false
}

@test "clean-docker and nettoyer-docker with --oui/--yes are equivalent" {
    fake_volumes
    ws nettoyer-docker --oui
    [ "$status" -eq 0 ]
    [ ! -d "$T/volumes/devzone-gh" ]
}

@test "clean-docker: no volume, nothing to do" {
    ws clean-docker --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"No devzone Docker volume to remove."* ]] || false
    ! grep -q "volume rm" "$T/docker.log" || false
}

@test "migrate, revert: never call destructive docker or kubectl" {
    fake_volumes
    ws migrate --yes
    [ "$status" -eq 0 ]
    ws revert --bring-back
    [ "$status" -eq 0 ]
    ! grep -qE "volume rm|volume prune|system prune|rm -f| rm " "$T/docker.log" || false
    ! grep -qE " delete |uninstall" "$T/kubectl.log" || false
}

@test "help: migrate, revert and clean-docker listed" {
    ws --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"migrate [--yes]"* ]] || false
    [[ "$output" == *"revert [--bring-back]"* ]] || false
    [[ "$output" == *"clean-docker"* ]] || false
}
