#!/usr/bin/env bats
# devzone agent --pod: projects root (DEVZONE_RACINE) and path checks (#222).
# Third file, so agent-pod.bats stays under 250 lines. The root is a folder under
# BATS_TEST_TMPDIR: no test needs /workspaces, and no real cluster is used.

load commun
load agent-pod-racine

setup() {
    load commun
    agent_isole
    racine_test
    unset DEVZONE_WORKSPACE
    export DEVZONE_WORKSPACE=kubernetes
    export DEVZONE_AGENT_POD_MODULES_FILE="$BATS_TEST_TMPDIR/modules"; : >"$DEVZONE_AGENT_POD_MODULES_FILE"
    T="$BATS_TEST_TMPDIR"
    mkdir -p "$T/bin"
    : >"$T/kubectl.log"
    cat >"$T/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"${BATS_TEST_TMPDIR:-/tmp}/kubectl.log"
exit 0
KUBE
    chmod +x "$T/bin/kubectl"
    printf 'build the feature\n' >"$T/consigne.txt"
    OUTSIDE="$T/hors/dz-222"
    mkdir -p "$OUTSIDE"
}

source_agent_pod() {
    source "$BATS_TEST_DIRNAME/../../.devcontainer/agent-pod.sh"
}

@test "agent-pod-root : without DEVZONE_RACINE the launcher root is /workspaces/projets" {
    run env -u DEVZONE_RACINE bash -c '. "$1"; printf "%s" "$AGENT_POD_ROOT"' _ "$BATS_TEST_DIRNAME/../../.devcontainer/agent-pod.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "/workspaces/projets" ]
}

@test "agent-pod-root : folder outside the projects root is refused without a pod" {
    source_agent_pod
    run agent_pod_validate_folder "$OUTSIDE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"outside the projects root $DEVZONE_RACINE"* ]] || false
}

@test "agent-pod-root : launcher refuses a folder outside the root before any object" {
    run bash "$DEVZONE" agent --pod "$OUTSIDE" "$T/consigne.txt"
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid folder path"* ]] || false
    ! grep -q "create" "$T/kubectl.log" || false
}

@test "agent-pod-root : folder without .git is refused without a pod" {
    NO_GIT="$DEVZONE_RACINE/dz-222-no-git"
    mkdir -p "$NO_GIT"
    source_agent_pod
    run agent_pod_validate_folder "$NO_GIT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no .git file"* ]] || false
}

@test "agent-pod-root : path with space is refused" {
    source_agent_pod
    run agent_pod_validate_folder "$DEVZONE_RACINE/devzone-wt/dz 222"
    [ "$status" -ne 0 ]
}

@test "agent-pod-root : path with semicolon is refused" {
    source_agent_pod
    run agent_pod_validate_folder "$DEVZONE_RACINE/devzone-wt/dz;222"
    [ "$status" -ne 0 ]
}

@test "agent-pod-root : path with a .. part is refused" {
    FOLDER="$(faux_worktree devzone dz-222)"
    source_agent_pod
    run agent_pod_validate_folder "$DEVZONE_RACINE/devzone-wt/../devzone-wt/dz-222"
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid folder path"* ]] || false
}

@test "agent-pod-root : worktree depot outside the root is refused" {
    folder="$DEVZONE_RACINE/devzone-wt/dz-222"
    mkdir -p "$folder" "$T/hors/depot/.git/worktrees/dz-222"
    printf 'gitdir: %s/hors/depot/.git/worktrees/dz-222\n' "$T" >"$folder/.git"
    source_agent_pod
    run agent_pod_validate_folder "$folder"
    [ "$status" -ne 0 ]
    [[ "$output" == *"outside the projects root"* ]] || false
}

@test "agent-pod-root : two folders give different names and labels" {
    source_agent_pod
    FOLDER="$(faux_worktree devzone dz-222)"
    other="$(faux_worktree other foo)"
    agent_pod_validate_folder "$other"
    [ "$?" -eq 0 ]
    [ "$AGENT_POD_SESSION_LABEL" = "foo" ]
    [[ "$(agent_pod_name "$FOLDER")" == agent-dz-222-* ]] || false
    [[ "$(agent_pod_name "$other")" == agent-foo-* ]] || false
}
