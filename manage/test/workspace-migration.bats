#!/usr/bin/env bats
# Docker workstation to Kubernetes workspace migration (#403). Fake docker and
# kubectl (see migration.bash): no real Docker volume or cluster is touched.

setup() {
    load migration
    migration_isolate
    export DEVZONE_WORKSPACE_WAIT=1 DEVZONE_WORKSPACE_STEP=0.1
}

@test "migrate: five steps, projects, identities, state, switch" {
    fake_volumes
    ws migrate --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"[1/5]"*"[2/5]"*"[3/5]"*"[4/5]"*"[5/5]"* ]] || false
    [ -f "$T/pod/workspaces/projets/alpha/a.txt" ]
    [ -f "$T/pod/workspaces/projets/beta/b.txt" ]
    [ -f "$T/pod/home/vscode/.config/gh/hosts.yml" ]
    [ -f "$T/pod/home/vscode/.m2/a.jar" ]
    [ -f "$T/pod/workspaces/projets/.devzone.modules" ]
    [ -f "$T/pod/workspaces/projets/.devzone.paquets" ]
    grep -qx "workspace=kubernetes" "$T/workstation/.devzone.modules" || false
    grep -qx "ia=on" "$T/workstation/.devzone.modules" || false
}

@test "migrate: volumes read read-only, never removed" {
    fake_volumes
    ws migrate --yes
    [ "$status" -eq 0 ]
    grep -q "docker run --rm -v devzone-gh:/src:ro" "$T/docker.log" || false
    ! grep -q "volume rm" "$T/docker.log" || false
    [ -f "$T/volumes/devzone-gh/hosts.yml" ]
    [ -f "$T/workstation/workspace/alpha/a.txt" ]
}

@test "migrate: missing volume ignored, config without chart path ignored" {
    ws migrate --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"devzone-gh: missing, ignored"* ]] || false
    [[ "$output" == *"devzone-config: no path in chart, skipped"* ]] || false
}

@test "migrate: without --yes and without terminal, refuses and touches nothing" {
    ws migrate </dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"no terminal"* ]] || false
    [ ! -s "$T/kubectl.log" ]
    ! grep -q "workspace=" "$T/workstation/.devzone.modules" || false
}

@test "migrate and migrer with --oui/--yes are equivalent" {
    ws migrer --oui
    [ "$status" -eq 0 ]
    grep -qx "workspace=kubernetes" "$T/workstation/.devzone.modules" || false
}

@test "migrate step 1: unreachable cluster, stop before any copy" {
    export FAKE_CLUSTER_KO=1
    ws migrate --yes
    [ "$status" -eq 1 ]
    [[ "$output" == *"unreachable cluster"* ]] || false
    ! grep -q " cp " "$T/kubectl.log" || false
    ! grep -q "workspace=" "$T/workstation/.devzone.modules" || false
}

@test "migrate step 1: workspace not started, suggests devzone workspace start" {
    export FAKE_PHASE=Pending
    ws migrate --yes
    [ "$status" -eq 1 ]
    [[ "$output" == *"devzone workspace start"* ]] || false
    ! grep -q " cp " "$T/kubectl.log" || false
}

@test "migrate step 1: not enough space" {
    export FAKE_DF_KO=1
    ws migrate --yes
    [ "$status" -eq 1 ]
    [[ "$output" == *"not enough space"* ]] || false
    ! grep -q " cp " "$T/kubectl.log" || false
}

@test "migrate step 2: copy failed, stop without next steps or switch" {
    export FAKE_CP_FAIL=1
    ws migrate --yes
    [ "$status" -eq 1 ]
    [[ "$output" == *"project alpha copy failed"* ]] || false
    [[ "$output" != *"[3/5]"* ]] || false
    ! grep -q "workspace=" "$T/workstation/.devzone.modules" || false
}

@test "migrate step 2: incomplete copy detected by verification" {
    export FAKE_CP_TRUNCATE=1
    ws migrate --yes
    [ "$status" -eq 1 ]
    [[ "$output" == *"different copy"* ]] || false
    [[ "$output" != *"[3/5]"* ]] || false
    ! grep -q "workspace=" "$T/workstation/.devzone.modules" || false
}

@test "migrate step 3: volume read failed, stop before state and switch" {
    fake_volumes
    export FAKE_DOCKER_RUN_KO=1
    ws migrate --yes
    [ "$status" -eq 1 ]
    [[ "$output" == *"volume devzone-gh read failed"* ]] || false
    [[ "$output" != *"[4/5]"* ]] || false
    ! grep -q "workspace=" "$T/workstation/.devzone.modules" || false
}

@test "migrate: unknown option refused" {
    ws migrate --all
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown option"* ]] || false
    [ ! -s "$T/kubectl.log" ]
}

@test "migrate: volume paths identical to persistence.state.paths in chart" {
    run grep -oE '^        [a-z0-9-]+\) echo \.[A-Za-z0-9_./-]+' "$RACINE/manage/scripts/migrer.sh"
    [ "$status" -eq 0 ]
    [ "$(wc -l <<<"$output")" -eq 9 ]
    while read -r path; do
        grep -qx "      - $path" "$RACINE/charts/devzone-workspace/values.yaml" || false
    done < <(sed -E 's/.*echo //' <<<"$output")
}
