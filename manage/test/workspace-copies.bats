#!/usr/bin/env bats
# Stale copies in the pod (#558): copy-to guard and legacy copies in status.
# Fake kubectl runs the script sent to the pod on a fake pod folder with a fake
# git: nothing real is touched.

setup() {
    load commun
    relais_docker_isole
    kube_isole
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CLI="$ROOT/manage/devzone"
    T="$BATS_TEST_TMPDIR"
    mkdir -p "$T/bin" "$T/pod" "$T/podbin"
    cat >"$T/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
echo "kubectl $*" >>"$T/kubectl.log"
case "$*" in
    "config get-contexts -o name") for c in $FAKE_CONTEXTS; do echo "$c"; done ;;
    *" get pods "*) echo "devzone-workspace-0 Running" ;;
    *" exec -i "*)
        shift
        while [ "$1" != "--" ]; do shift; done
        shift
        args=()
        for a in "${@:4}"; do args+=("${a/#\/workspaces\/projets/$T/pod}"); done
        PATH="$T/podbin:$PATH" bash -s -- "${args[@]}"
        ;;
esac
KUBE
    cat >"$T/podbin/git" <<'GIT'
#!/usr/bin/env bash
case "$*" in
    *"remote get-url origin"*) echo "${FAKE_REMOTE:-}" ;;
esac
GIT
    chmod +x "$T"/bin/kubectl "$T"/podbin/git
    export PATH="$T/bin:$PATH" FAKE_CONTEXTS="devzone docker-desktop"
    mkdir -p "$T/mine"
    git init -q "$T/mine"
    git -C "$T/mine" remote add origin https://github.com/acme/mine.git
}

@test "copy-to: pod clone of another remote is refused, no copy" {
    mkdir -p "$T/pod/mine/.git"
    export FAKE_REMOTE="https://github.com/other/mine.git"
    run bash "$CLI" workspace copy-to "$T/mine"
    [ "$status" -eq 1 ]
    [[ "$output" == *"another remote (https://github.com/other/mine.git"* ]] || false
    ! grep -q " cp " "$T/kubectl.log" || false
}

@test "copy-to: pod clone of the same remote is copied over" {
    mkdir -p "$T/pod/mine/.git"
    export FAKE_REMOTE="https://github.com/acme/mine"
    run bash "$CLI" workspace copy-to "$T/mine"
    [ "$status" -eq 0 ]
    grep -q " cp $T/mine " "$T/kubectl.log" || false
}

@test "copy-to: pod folder without .git is copied over" {
    mkdir -p "$T/pod/mine"
    run bash "$CLI" workspace copy-to "$T/mine"
    [ "$status" -eq 0 ]
    grep -q " cp $T/mine " "$T/kubectl.log" || false
}

@test "status: legacy repogarde and wt copies reported with the removal command" {
    mkdir -p "$T/pod/repogarde" "$T/pod/wt/dz-1"
    echo "gitdir: /Users/someone/repogarde/.git" >"$T/pod/repogarde/.git"
    echo "gitdir: /Users/someone/repogarde/.git/worktrees/dz-1" >"$T/pod/wt/dz-1/.git"
    run bash "$CLI" workspace status
    [ "$status" -eq 0 ]
    [[ "$output" == *"legacy copies in the pod"*"/workspaces/projets/repogarde /workspaces/projets/wt"* ]] || false
    [[ "$output" == *"rm -rf /workspaces/projets/repogarde /workspaces/projets/wt"* ]] || false
    [[ "$output" == *"copy-from"* ]] || false
}

@test "status: healthy copies in the pod are not reported" {
    mkdir -p "$T/pod/repogarde" "$T/pod/real"
    echo "gitdir: $T/pod/repogarde/.real" >"$T/pod/repogarde/.git"
    mkdir -p "$T/pod/repogarde/.real"
    run bash "$CLI" workspace status
    [ "$status" -eq 0 ]
    [[ "$output" != *"legacy copies"* ]] || false
}
