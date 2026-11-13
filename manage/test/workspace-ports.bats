#!/usr/bin/env bats
# Applications and services of the workspace on workstation localhost (#401). Fake kubectl
# (ss, port-forward) and fake lsof under $BATS_TEST_TMPDIR/bin: no cluster or
# workstation port is touched. The watcher runs only under DEVZONE_PORTS_WORKSPACE_REEL=oui.

setup() {
    load commun
    relais_docker_isole
    kube_isole
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CLI="$ROOT/manage/devzone"
    SCRIPT="$ROOT/manage/scripts/ports-workspace.sh"
    T="$BATS_TEST_TMPDIR"
    mkdir -p "$T/bin" "$T/workstation"
    : >"$T/ss"
    : >"$T/taken"
    cat >"$T/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
# Fake kubectl: ss reads $T/ss, port-forward stays alive (sleep) and logs.
T="$BATS_TEST_TMPDIR"
echo "kubectl $*" >>"$T/kubectl.log"
case "$*" in
    "config get-contexts -o name") echo docker-desktop ;;
    *" exec "*" ss "*) cat "$T/ss" ;;
    *" get svc pgadmin "*) [ -f "$T/pgadmin" ] && cat "$T/pgadmin" ;;
    *"get pod devzone-workspace-0 "*) echo "${FAKE_POD:-Running}" ;;
    *" port-forward "*) exec sleep 120 ;;
esac
exit 0
KUBE
    cat >"$T/bin/lsof" <<'LSOF'
#!/usr/bin/env bash
echo "lsof $*" >>"$BATS_TEST_TMPDIR/lsof.log"
for a in "$@"; do
    case "$a" in -iTCP:*) ;; *) continue ;; esac
    grep -qx -- "${a#-iTCP:}" "$BATS_TEST_TMPDIR/taken" 2>/dev/null && exit 0
done
exit 1
LSOF
    chmod +x "$T/bin/kubectl" "$T/bin/lsof"
    export PATH="$T/bin:$PATH"
    export DEVZONE_PORTS_WORKSPACE_REEL=oui
    export DEVZONE_PORTS_WORKSPACE_PAS=0.2
    export DEVZONE_WORKSPACE_ATTENTE=1 DEVZONE_WORKSPACE_PAS=0.1
    : >"$T/kubectl.log"
}

teardown() {
    ( cd "$T/workstation" && DEVZONE_PORTS_WORKSPACE_REEL=oui bash "$CLI" workspace ports stop >/dev/null 2>&1 ) || true
}

# Simulated listening in the pod: one ss -ltnH line per given port.
listening() {
    : >"$T/ss"
    local p
    for p in "$@"; do echo "LISTEN 0 511 0.0.0.0:$p 0.0.0.0:*" >>"$T/ss"; done
}

# One watcher round, from the test workstation folder.
round() {
    cd "$T/workstation" && run bash "$SCRIPT" round
}

# Is process $1 alive? A zombie (dead, not yet reaped by container PID 1) is dead.
alive() {
    kill -0 "$1" 2>/dev/null || return 1
    [ "$(ps -o stat= -p "$1" 2>/dev/null | cut -c1)" != Z ]
}

# Waits up to 5 s for the watcher pid file to exist.
wait_watcher_pid() {
    local i
    for i in $(seq 50); do
        [ -s "$T/workstation/.devzone.ports-workspace/pid" ] && return 0
        sleep 0.1
    done
    return 1
}

# Waits up to 5 s for process $1 to be gone and pid file removed.
wait_stopped() {
    local i
    for i in $(seq 50); do
        if ! alive "$1" && [ ! -e "$T/workstation/.devzone.ports-workspace/pid" ]; then return 0; fi
        sleep 0.1
    done
    return 1
}

@test "ports: new pod port relayed on 127.0.0.1 only" {
    listening 5173
    round
    [ "$status" -eq 0 ]
    [[ "$output" == *"port 5173 relayed"* ]] || false
    sleep 0.3
    grep -q -- "port-forward --address 127.0.0.1 pod/devzone-workspace-0 5173:5173" "$T/kubectl.log" || false
}

@test "ports: ports below 1024 and internal ports ignored" {
    listening 80 1023 2475 1234 3000
    round
    sleep 0.3
    [ "$(grep -c port-forward "$T/kubectl.log")" -eq 1 ]
    grep -q "3000:3000" "$T/kubectl.log" || false
}

@test "ports: already relayed port, no second port-forward" {
    listening 5173
    round
    round
    sleep 0.3
    [ "$(grep -c port-forward "$T/kubectl.log")" -eq 1 ]
}

@test "ports: disappeared port, port-forward stopped" {
    listening 5173
    round
    pid="$(cat "$T/workstation/.devzone.ports-workspace/relais/5173")"
    kill -0 "$pid"
    listening
    round
    sleep 0.3
    ! kill -0 "$pid" 2>/dev/null || false
    [ ! -e "$T/workstation/.devzone.ports-workspace/relais/5173" ]
}

@test "ports: port taken on workstation, reported once, not relayed" {
    echo 5173 >"$T/taken"
    listening 5173
    round
    [[ "$output" == *"⚠ port 5173 already in use on the workstation, not relayed"* ]] || false
    round
    [[ "$output" != *"already in use"* ]] || false
    ! grep -q port-forward "$T/kubectl.log" || false
}

@test "ports: devzone services relayed when postgres is active" {
    echo "postgres=on" >"$T/workstation/.devzone.modules"
    echo 5433 >"$T/pgadmin"
    round
    sleep 0.3
    grep -q -- "--namespace devzone-postgres port-forward --address 127.0.0.1 svc/postgres 5432:5432" "$T/kubectl.log" || false
    grep -q -- "port-forward --address 127.0.0.1 svc/pgadmin 5433:5433" "$T/kubectl.log" || false
}

@test "ports: without postgres module, no service relayed" {
    round
    ! grep -q port-forward "$T/kubectl.log" || false
}

@test "ports: mysql service relayed on 3306 when mysql is active" {
    echo "mysql=on" >"$T/workstation/.devzone.modules"
    round
    sleep 0.3
    grep -q -- "--namespace devzone-mysql port-forward --address 127.0.0.1 svc/mysql 3306:3306" "$T/kubectl.log" || false
}

@test "ports: without mysql module, no 3306 port relayed" {
    echo "postgres=on" >"$T/workstation/.devzone.modules"
    round
    sleep 0.3
    ! grep -q "svc/mysql" "$T/kubectl.log" || false
}

@test "ports start: only one watcher, stop removes it with its port-forwards" {
    listening 5173
    cd "$T/workstation"
    run bash "$CLI" workspace ports start
    [ "$status" -eq 0 ]
    wait_watcher_pid || false
    watcher="$(cat .devzone.ports-workspace/pid)"
    kill -0 "$watcher" || false
    run bash "$CLI" workspace ports start
    [[ "$output" == *"already running (pid $watcher)"* ]] || false
    sleep 1
    pid="$(cat .devzone.ports-workspace/relais/5173)"
    run bash "$CLI" workspace ports status
    [[ "$output" == *"running"*"127.0.0.1:5173 relayed"* ]] || false
    run bash "$CLI" workspace ports stop
    [ "$status" -eq 0 ]
    wait_stopped "$watcher" || false
    ! alive "$pid" || false
    run bash "$CLI" workspace ports status
    [[ "$output" == *"stopped"* ]] || false
}

@test "ports start and demarrer: same behavior" {
    listening 5173
    cd "$T/workstation"
    run bash "$CLI" workspace ports demarrer
    [ "$status" -eq 0 ]
    wait_watcher_pid || false
    watcher="$(cat .devzone.ports-workspace/pid)"
    run bash "$CLI" workspace ports arreter
    [ "$status" -eq 0 ]
    wait_stopped "$watcher" || false
}

@test "ports start: refused under bats without DEVZONE_PORTS_WORKSPACE_REEL" {
    unset DEVZONE_PORTS_WORKSPACE_REEL
    cd "$T/workstation"
    run bash "$CLI" workspace ports start
    [[ "$output" == *"refused under bats"* ]] || false
    [ ! -e .devzone.ports-workspace/pid ]
    [ -z "$(ps -eo args | grep "[p]orts-workspace.sh loop" || true)" ]
}

@test "workspace start and stop: watcher started then stopped" {
    export PATH="$T/bin:$PATH"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$T/bin/helm"
    chmod +x "$T/bin/helm"
    listening 3000
    cd "$T/workstation"
    run bash "$CLI" workspace start
    [ "$status" -eq 0 ]
    wait_watcher_pid || false
    watcher="$(cat .devzone.ports-workspace/pid)"
    kill -0 "$watcher" || false
    run bash "$CLI" workspace stop
    [ "$status" -eq 0 ]
    wait_stopped "$watcher" || false
}
