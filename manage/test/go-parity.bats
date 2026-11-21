#!/usr/bin/env bats
# Parity of the Go binary (cmd/devzone) with the bash entry point (#711): for
# each command ported to Go, the standard output, the standard error and the
# exit status are the same as those of manage/devzone. The binary is built once
# for the file; without go, the file is skipped.

setup_file() {
    if ! command -v go >/dev/null 2>&1; then
        skip "go is not installed"
    fi
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export DZ_GO="$BATS_FILE_TMPDIR/dz"
    (cd "$RACINE" && go build -o "$DZ_GO" ./cmd/devzone) || { echo "go build failed"; return 1; }
}

setup() {
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CLI="$RACINE/manage/devzone"
    # Absolute path: the binary finds the package.json of the checkout through it
    export DEVZONE_BASH_ENTRY="$CLI"
    cd "$BATS_TEST_TMPDIR" || return 1
}

# parite <args...> : runs manage/devzone, then the binary, with the same
# arguments; fails when the status, the standard output or the standard error differ
parite() {
    local t="$BATS_TEST_TMPDIR" st_bash=0 st_go=0
    bash "$CLI" "$@" >"$t/bash.out" 2>"$t/bash.err" || st_bash=$?
    "$DZ_GO" "$@" >"$t/go.out" 2>"$t/go.err" || st_go=$?
    [ "$st_go" -eq "$st_bash" ] || { echo "status for [$*]: bash $st_bash, go $st_go"; return 1; }
    cmp "$t/bash.out" "$t/go.out" || { echo "stdout for [$*] differs"; diff "$t/bash.out" "$t/go.out"; return 1; }
    cmp "$t/bash.err" "$t/go.err" || { echo "stderr for [$*] differs"; diff "$t/bash.err" "$t/go.err"; return 1; }
}

@test "go-parity: --version" {
    parite --version
    run "$DZ_GO" --version
    [ "$status" -eq 0 ]
}

@test "go-parity: -v" {
    parite -v
}

@test "go-parity: help" {
    parite help
    run "$DZ_GO" help
    [ "$status" -eq 0 ]
}

@test "go-parity: -h" {
    parite -h
}

@test "go-parity: --help" {
    parite --help
}

@test "go-parity: no argument shows the help" {
    parite
}

@test "go-parity: help with an argument is delegated, same output" {
    parite help extra
}

@test "go-parity: renamed option refused by bash, same message and status" {
    parite --version --oui
}

# faux_cluster : fake kubectl and helm first in PATH, no real cluster touched (#712).
# FAKE_NO_POD=yes: no pod; FAKE_LEGACY=yes: a legacy copy in the pod;
# FAKE_KUBE_DOWN=yes: the cluster does not answer; FAKE_NO_RELEASE=yes: no helm
# release to uninstall; FAKE_ARGO=yes: Argo CD holds the workspace Application.
# FAKE_DEVZONE=yes: the devzone context is declared; FAKE_SHELL_STATUS=n: the
# status of "kubectl exec -it" (the shell), 0 by default, which prints its arguments.
faux_cluster() {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat >"$BATS_TEST_TMPDIR/bin/helm" <<'HELM'
#!/usr/bin/env bash
echo "helm $*"
if [ -n "${FAKE_KUBE_DOWN:-}" ]; then
    echo "Error: Kubernetes cluster unreachable" >&2
    exit 1
fi
if [ -n "${FAKE_NO_RELEASE:-}" ]; then
    echo "Error: uninstall: Release not loaded: devzone-workspace: release: not found" >&2
    exit 1
fi
echo 'release "devzone-workspace" uninstalled'
exit 0
HELM
    chmod +x "$BATS_TEST_TMPDIR/bin/helm"
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
case "$*" in
    "config get-contexts -o name")
        echo lab
        [ -z "${FAKE_DEVZONE:-}" ] || echo devzone
        ;;
    *"get namespace"*)
        [ -n "${FAKE_ARGO:-}" ] || exit 1
        ;;
    *"get application"*)
        [ -n "${FAKE_ARGO:-}" ] || exit 1
        ;;
    *"get pods"*)
        if [ -n "${FAKE_KUBE_DOWN:-}" ]; then
            echo "Unable to connect to the server" >&2
            exit 1
        fi
        if [ -n "${FAKE_NO_POD:-}" ]; then
            echo "No resources found in devzone-workspace namespace." >&2
            exit 0
        fi
        echo "NAME                 READY   STATUS    RESTARTS   AGE"
        echo "devzone-workspace-0  1/1     Running   0          2d"
        ;;
    *"exec -it"*)
        echo "kubectl $*"
        exit "${FAKE_SHELL_STATUS:-0}"
        ;;
    *"exec -i"*)
        cat >/dev/null
        if [ -n "${FAKE_NO_POD:-}" ]; then exit 1; fi
        if [ -n "${FAKE_LEGACY:-}" ]; then echo repogarde; fi
        ;;
esac
exit 0
KUBE
    chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "go-parity: workspace status, pod listed: same output and status" {
    faux_cluster
    parite workspace status
    run "$DZ_GO" workspace status
    [ "$status" -eq 0 ]
    [[ "$output" == *"devzone-workspace-0"* ]] || false
}

@test "go-parity: workspace status, no pod: same message and status" {
    faux_cluster
    export FAKE_NO_POD=yes
    parite workspace status
}

@test "go-parity: workspace status, legacy copy in the pod: same warning" {
    faux_cluster
    export FAKE_LEGACY=yes
    parite workspace status
    run "$DZ_GO" workspace status
    [[ "$output" == *"rm -rf /workspaces/projets/repogarde"* ]] || false
}

@test "go-parity: workspace status, cluster down: same error and status" {
    faux_cluster
    export FAKE_KUBE_DOWN=yes
    parite workspace status
}

@test "go-parity: workspace status with extra words is delegated, same output" {
    faux_cluster
    parite workspace status extra
}

@test "go-parity: workspace alone is delegated, same help" {
    faux_cluster
    parite workspace
}

@test "go-parity: workspace stop, release uninstalled: same output and status" {
    faux_cluster
    parite workspace stop
    run "$DZ_GO" workspace stop
    [ "$status" -eq 0 ]
    [[ "$output" == *"uninstall devzone-workspace --namespace devzone-workspace"* ]] || false
}

@test "go-parity: workspace stop, no release: same error and status" {
    faux_cluster
    export FAKE_NO_RELEASE=yes
    parite workspace stop
}

@test "go-parity: workspace stop, cluster down: same error and status" {
    faux_cluster
    export FAKE_KUBE_DOWN=yes
    parite workspace stop
}

@test "go-parity: workspace stop with extra words is delegated, same output" {
    faux_cluster
    parite workspace stop extra
}

@test "go-parity: workspace stop, Argo CD holds the workspace: bash removes it, same output" {
    faux_cluster
    export FAKE_ARGO=yes
    parite workspace stop
}

@test "go-parity: workspace stop cleans the port state, bash and go alike" {
    faux_cluster
    local state="$BATS_TEST_TMPDIR/.devzone.workspace-ports"
    mkdir -p "$state/relais" "$state/pris" "$state/verrou"
    echo 999999 >"$state/pid"
    echo 999998 >"$state/relais/5432"
    touch "$state/pris/5432"
    bash "$CLI" workspace stop >/dev/null
    [ ! -e "$state/pid" ] && [ ! -e "$state/verrou" ] && [ ! -e "$state/relais/5432" ]
    mkdir -p "$state/relais" "$state/pris" "$state/verrou"
    echo 999999 >"$state/pid"
    echo 999998 >"$state/relais/5432"
    touch "$state/pris/5432"
    run "$DZ_GO" workspace stop
    [ "$status" -eq 0 ]
    [ ! -e "$state/pid" ] && [ ! -e "$state/verrou" ] && [ ! -e "$state/relais/5432" ]
}

@test "go-parity: workspace vscode: same guide, same status" {
    faux_cluster
    parite workspace vscode
    run "$DZ_GO" workspace vscode
    [ "$status" -eq 0 ]
    [[ "$output" == *"namespace devzone-workspace, pod devzone-workspace-0, container workspace"* ]] || false
}

@test "go-parity: workspace vscode with extra words is delegated, same output" {
    faux_cluster
    parite workspace vscode extra
}

@test "go-parity: workspace shell, current context: same kubectl arguments and status" {
    faux_cluster
    parite workspace shell
    run "$DZ_GO" workspace shell
    [ "$status" -eq 0 ]
    [ "$output" = "kubectl exec -it devzone-workspace-0 --namespace devzone-workspace -c workspace -- bash" ] || false
}

@test "go-parity: workspace shell, devzone context declared: same kubectl arguments" {
    faux_cluster
    export FAKE_DEVZONE=yes
    parite workspace shell
    run "$DZ_GO" workspace shell
    [ "$status" -eq 0 ]
    [ "$output" = "kubectl --context devzone exec -it devzone-workspace-0 --namespace devzone-workspace -c workspace -- bash" ] || false
}

@test "go-parity: workspace shell, kubectl exits 130: same status" {
    faux_cluster
    export FAKE_SHELL_STATUS=130
    parite workspace shell
    run "$DZ_GO" workspace shell
    [ "$status" -eq 130 ]
}

@test "go-parity: workspace shell with extra words is delegated, same output" {
    faux_cluster
    parite workspace shell extra
}
