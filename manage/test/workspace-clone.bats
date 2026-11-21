#!/usr/bin/env bats
# devzone workspace clone (#558). Fake kubectl runs the script sent to the pod
# on a fake pod folder with fake git, gh and repowarden: nothing real is touched.

setup() {
    load commun
    kube_isole
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CLI="$ROOT/manage/devzone"
    T="$BATS_TEST_TMPDIR"
    mkdir -p "$T/bin" "$T/pod"
    cat >"$T/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
echo "kubectl $*" >>"$T/kubectl.log"
case "$*" in
    "config get-contexts -o name") for c in $FAKE_CONTEXTS; do echo "$c"; done ;;
    *" exec -i "*)
        shift
        while [ "$1" != "--" ]; do shift; done
        shift
        # bash -s -- <dir> <url> <name> <email>: the pod folder is redirected
        args=()
        for a in "${@:4}"; do args+=("${a/#\/workspaces\/projets/$T/pod}"); done
        POD_BIN="$T/podbin" PATH="$T/podbin:$PATH" bash -s -- "${args[@]}"
        ;;
esac
KUBE
    mkdir -p "$T/podbin"
    cat >"$T/podbin/gh" <<'GH'
#!/usr/bin/env bash
echo "gh $*" >>"$BATS_TEST_TMPDIR/pod.log"
GH
    cat >"$T/podbin/repowarden" <<'RW'
#!/usr/bin/env bash
echo "repowarden $* in $PWD" >>"$BATS_TEST_TMPDIR/pod.log"
RW
    cat >"$T/podbin/git" <<'GIT'
#!/usr/bin/env bash
echo "git $*" >>"$BATS_TEST_TMPDIR/pod.log"
case "$*" in
    clone*) mkdir -p "${@: -1}/.git" ;;
    *"remote get-url origin"*) echo "${FAKE_REMOTE:-}" ;;
esac
GIT
    chmod +x "$T"/bin/kubectl "$T"/podbin/*
    export PATH="$T/bin:$PATH"
    export FAKE_CONTEXTS="devzone docker-desktop"
}

@test "clone: git clone in pod folder, gh credentials, hooks installed" {
    run bash "$CLI" workspace clone https://github.com/acme/devzone.git
    [ "$status" -eq 0 ]
    grep -q -- "exec -i devzone-workspace-0 --namespace devzone-workspace -c workspace" "$T/kubectl.log" || false
    grep -q -- "--context devzone" "$T/kubectl.log" || false
    grep -q "^gh auth setup-git" "$T/pod.log" || false
    grep -q "^git clone https://github.com/acme/devzone.git $T/pod/devzone" "$T/pod.log" || false
    grep -q "^repowarden install in $T/pod/devzone" "$T/pod.log" || false
}

@test "clone: given name is the pod folder" {
    run bash "$CLI" workspace clone https://github.com/acme/devzone.git mine
    [ "$status" -eq 0 ]
    grep -q "^git clone https://github.com/acme/devzone.git $T/pod/mine" "$T/pod.log" || false
}

@test "clone: git identity of the workstation copied into the clone" {
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_CONFIG_GLOBAL="$T/gitconfig"
    printf '[user]\n\tname = Ada\n\temail = ada@example.org\n' >"$GIT_CONFIG_GLOBAL"
    # The identity is read from the current folder: run it outside any repository.
    cd "$T" || return 1
    run bash "$CLI" workspace clone https://github.com/acme/devzone.git
    [ "$status" -eq 0 ]
    grep -q "config user.name Ada" "$T/pod.log" || false
    grep -q "config user.email ada@example.org" "$T/pod.log" || false
}

@test "clone: existing clone of the same remote is kept, no new clone" {
    mkdir -p "$T/pod/devzone/.git"
    export FAKE_REMOTE="https://github.com/acme/devzone"
    run bash "$CLI" workspace clone https://github.com/acme/devzone.git
    [ "$status" -eq 0 ]
    ! grep -q "^git clone" "$T/pod.log" || false
    grep -q "^repowarden install" "$T/pod.log" || false
}

@test "clone: existing folder with another remote is refused" {
    mkdir -p "$T/pod/devzone/.git"
    export FAKE_REMOTE="https://github.com/other/devzone.git"
    run bash "$CLI" workspace clone https://github.com/acme/devzone.git
    [ "$status" -eq 3 ]
    [[ "$output" == *"another remote"* ]] || false
    [ ! -e "$T/pod.log" ] || ! grep -q "^repowarden" "$T/pod.log"
}

@test "clone: non-empty folder without .git is refused" {
    mkdir -p "$T/pod/devzone"
    : >"$T/pod/devzone/file"
    run bash "$CLI" workspace clone https://github.com/acme/devzone.git
    [ "$status" -eq 3 ]
    [[ "$output" == *"not a git clone"* ]] || false
}

@test "clone: without url, usage and no kubectl" {
    run bash "$CLI" workspace clone
    [ "$status" -eq 1 ]
    [[ "$output" == *"devzone workspace clone <url> [<name>]"* ]] || false
    [ ! -e "$T/kubectl.log" ] || ! grep -q " exec " "$T/kubectl.log"
}

@test "clone: invalid folder name is refused, no kubectl" {
    run bash "$CLI" workspace clone https://github.com/acme/devzone.git "../x"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid folder name"* ]] || false
    [ ! -e "$T/kubectl.log" ] || ! grep -q " exec " "$T/kubectl.log"
}

# Guard of the agents (#558): function of the same script, fake kubectl.
guard() {
    run bash -c '
        kubectl_flag() { :; }
        POD=devzone-workspace-0 NAMESPACE=devzone-workspace
        . "$1/manage/scripts/workspace/workspace-clone.sh"
        workspace_agents_guard
    ' _ "$ROOT"
}

@test "agents guard: runs repowarden agents init --global in the pod when ia is on" {
    cat >"$T/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"$BATS_TEST_TMPDIR/kubectl.log"
KUBE
    guard
    [ "$status" -eq 0 ]
    grep -q "exec devzone-workspace-0 .*devzone is-enabled ai && repowarden agents init --global" "$T/kubectl.log" || false
    [[ "$output" == *"guard active"* ]] || false
}

@test "agents guard: silent and harmless when ia is off in the pod" {
    printf '#!/usr/bin/env bash\nexit 1\n' >"$T/bin/kubectl"
    guard
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
