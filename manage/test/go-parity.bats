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
    # Since #934 the workspace commands run in the Go program: the bash entry
    # point calls them through DEVZONE_HOST_BIN, the binary of this file
    export DEVZONE_HOST_BIN="$DZ_GO"
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

# parite_ports <args...>: like parite, but ignores only the automatic-start
# status line that the Go command prints and the shell original does not (#901).
parite_ports() {
    local t="$BATS_TEST_TMPDIR" st_bash=0 st_go=0
    bash "$CLI" "$@" >"$t/bash.out" 2>"$t/bash.err" || st_bash=$?
    "$DZ_GO" "$@" >"$t/go.out" 2>"$t/go.err" || st_go=$?
    [ "$st_go" -eq "$st_bash" ] || { echo "status for [$*]: bash $st_bash, go $st_go"; return 1; }
    grep -v '^Port watcher automatic start: ' "$t/bash.out" >"$t/bash.filtered" || true
    grep -v '^Port watcher automatic start: ' "$t/go.out" >"$t/go.filtered" || true
    cmp "$t/bash.filtered" "$t/go.filtered" || { echo "stdout for [$*] differs"; diff "$t/bash.filtered" "$t/go.filtered"; return 1; }
    cmp "$t/bash.err" "$t/go.err" || { echo "stderr for [$*] differs"; diff "$t/bash.err" "$t/go.err"; return 1; }
}

# faux_cluster : fake kubectl and helm first in PATH, no real cluster touched (#712).
# FAKE_NO_POD=yes: no pod; FAKE_LEGACY=yes: a legacy copy in the pod;
# FAKE_KUBE_DOWN=yes: the cluster does not answer; FAKE_NO_RELEASE=yes: no helm
# release to uninstall; FAKE_ARGO=yes: Argo CD holds the workspace Application.
# FAKE_DEVZONE=yes: the devzone context is declared; FAKE_SHELL_STATUS=n: the
# status of "kubectl exec -it" (the shell), 0 by default, which prints its arguments.
# FAKE_OTHER_REMOTE=url: the guard of copy-to finds a pod clone of another remote
# ("kubectl cp" prints its arguments, with the copies).
# FAKE_CLONE_STATUS=n: the status of the pod script of "clone" (0 by default); the
# fake prints its arguments, as "kubectl exec -i" of the clone does.
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
    "cp "* | *" cp "*)
        echo "kubectl $*"
        exit 0
        ;;
    *"exec -it"*)
        echo "kubectl $*"
        exit "${FAKE_SHELL_STATUS:-0}"
        ;;
    *"exec -i"*)
        input="$(cat)"
        case "$input" in
            *"gh auth setup-git"*)
                echo "kubectl $*"
                exit "${FAKE_CLONE_STATUS:-0}"
                ;;
            *"git -C"*)
                if [ -n "${FAKE_OTHER_REMOTE:-}" ]; then
                    echo "$FAKE_OTHER_REMOTE"
                    exit 3
                fi
                exit 0
                ;;
        esac
        if [ -n "${FAKE_NO_POD:-}" ]; then exit 1; fi
        if [ -n "${FAKE_LEGACY:-}" ]; then echo repogarde; fi
        ;;
esac
exit 0
KUBE
    chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# faux_kubectl_services: fake kubectl where "get namespace devzone-postgres" and
# "devzone-argocd" succeed, the other namespaces do not; no context declared.
faux_kubectl_services() {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
case "$*" in
    "config get-contexts -o name")
        echo lab
        ;;
    *"get namespace devzone-gitlab"*)
        exit 1
        ;;
    *"get namespace devzone-postgres"*)
        ;;
    *"get namespace devzone-mysql"*)
        exit 1
        ;;
    *"get namespace devzone-argocd"*)
        ;;
esac
exit 0
KUBE
    chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "go-parity: workspace status with extra words is delegated, same output" {
    faux_cluster
    parite workspace status extra
}

@test "go-parity: workspace alone is delegated, same help" {
    faux_cluster
    parite workspace
}

@test "go-parity: workspace services status, two installed: same output and status" {
    faux_kubectl_services
    parite workspace services status
    run "$DZ_GO" workspace services status
    [ "$status" -eq 0 ]
    [[ "$output" == *"devzone workspace services disable postgres"* ]] || false
    [[ "$output" == *"devzone workspace services enable gitlab"* ]] || false
}

@test "go-parity: workspace services, two installed: same output and status" {
    faux_kubectl_services
    parite workspace services
    run "$DZ_GO" workspace services
    [ "$status" -eq 0 ]
    [[ "$output" == *"devzone workspace services disable argocd"* ]] || false
    [[ "$output" == *"devzone workspace services enable mysql"* ]] || false
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
    mkdir -p "$state/relays" "$state/taken" "$state/lock"
    echo 999999 >"$state/pid"
    echo 999998 >"$state/relays/5432"
    touch "$state/taken/5432"
    bash "$CLI" workspace stop >/dev/null
    [ ! -e "$state/pid" ] && [ ! -e "$state/lock" ] && [ ! -e "$state/relays/5432" ]
    mkdir -p "$state/relays" "$state/taken" "$state/lock"
    echo 999999 >"$state/pid"
    echo 999998 >"$state/relays/5432"
    touch "$state/taken/5432"
    run "$DZ_GO" workspace stop
    [ "$status" -eq 0 ]
    [ ! -e "$state/pid" ] && [ ! -e "$state/lock" ] && [ ! -e "$state/relays/5432" ]
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

# ports_state DIR: a state folder with a live sleep watcher and relay, one taken
# port, one relayed application and one without a ready pod. Prints the pid of
# the sleep, alive until the end of the test.
ports_state() {
    local d="$1" pid
    mkdir -p "$d/relays" "$d/taken" "$d/apps" "$d/no-ready-pod" "$d/lock"
    # Detached from the output of the command substitution that calls this function:
    # otherwise it waits for the sleep to end and the watcher is dead when checked.
    sleep 60 </dev/null >/dev/null 2>&1 &
    pid=$!
    echo "$pid" >"$d/pid"
    echo "$pid" >"$d/relays/5432"
    : >"$d/taken/3000"
    printf '8080' >"$d/apps/default.web.80"
    echo "$pid" >"$d/relays/8080"
    : >"$d/no-ready-pod/team.api.9000"
    printf '9000' >"$d/apps/team.api.9000"
    printf '7070' >"$d/apps/team.guestbook.ui.80"
    echo "$pid" >"$d/relays/7070"
    echo "$pid" >"$d/relays/.6000"
    : >"$d/restart"
    echo "$pid"
}

@test "go-parity: workspace ports status, watcher running: go reports state" {
    local state pid
    state="$BATS_TEST_TMPDIR/state"
    pid="$(ports_state "$state")"
    export DEVZONE_PORTS_WORKSPACE_DIR="$state"
    run "$DZ_GO" workspace ports status
    [ "$status" -eq 0 ]
    [[ "$output" == *"Port watcher: running (pid $pid)"* ]] || false
    [[ "$output" == *"127.0.0.1:5432 relayed"* ]] || false
    kill "$pid" 2>/dev/null || true
}

@test "go-parity: workspace ports stop: go clears watcher state" {
    local dgo="$BATS_TEST_TMPDIR/go-state"
    local st_go=0 pidg
    pidg="$(ports_state "$dgo")"
    DEVZONE_PORTS_WORKSPACE_DIR="$dgo" "$DZ_GO" workspace ports stop \
        >"$BATS_TEST_TMPDIR/go.out" 2>"$BATS_TEST_TMPDIR/go.err" || st_go=$?
    [ "$st_go" -eq 0 ]
    [ ! -s "$BATS_TEST_TMPDIR/go.out" ]
    [ ! -s "$BATS_TEST_TMPDIR/go.err" ]
    [ ! -e "$dgo/pid" ] && [ ! -e "$dgo/lock" ] && [ ! -e "$dgo/restart" ]
    [ ! -e "$dgo/relays/5432" ] && [ ! -e "$dgo/relays/8080" ] && [ ! -e "$dgo/relays/7070" ]
    [ -f "$dgo/relays/.6000" ] && process_dead "$(cat "$dgo/relays/.6000")" || false
    [ -e "$dgo/taken/3000" ]
    process_dead "$pidg" || false
}

# process_dead PID: true when the process is gone, or zombie and not reaped yet,
# as a process stopped by ports stop can be under bats.
process_dead() {
    kill -0 "$1" 2>/dev/null || return 0
    [ "$(ps -o stat= -p "$1" 2>/dev/null | cut -c1)" = Z ]
}

# git_clone DIR URL : a git folder whose origin is URL (the guard of copy-to reads it)
git_clone() {
    git init -q "$1"
    git -C "$1" remote add origin "$2"
}

