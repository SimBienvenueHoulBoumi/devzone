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
