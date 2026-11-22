#!/usr/bin/env bats
# Applications of the workspace relayed on workstation localhost (#611): one Service per
# relay, local port attributed and kept. Fake kubectl (get svc -A, ss, port-forward) and
# fake lsof under $BATS_TEST_TMPDIR/bin: no cluster or workstation port is touched.

setup() {
    load commun
    kube_isole
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CLI="$ROOT/manage/devzone"
    SCRIPT="$ROOT/manage/scripts/workspace/ports-workspace.sh"
    T="$BATS_TEST_TMPDIR"
    mkdir -p "$T/bin" "$T/workstation"
    : >"$T/ss"
    : >"$T/svc"
    : >"$T/taken"
    cat >"$T/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
# Fake kubectl: get svc -A reads $T/svc, ss reads $T/ss, port-forward stays alive (sleep) and logs.
# get endpointslices -A (#638): every Service of $T/svc has a ready endpoint.
T="$BATS_TEST_TMPDIR"
echo "kubectl $*" >>"$T/kubectl.log"
case "$*" in
    "config get-contexts -o name") echo docker-desktop ;;
    *" exec "*" ss "*) cat "$T/ss" ;;
    "get svc -A "*) cat "$T/svc" ;;
    "get endpointslices -A "*) awk -F'|' '{print $1 "|" $2 "|true,"}' "$T/svc" ;;
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
    export DEVZONE_PORTS_WORKSPACE_REAL=yes
    export DEVZONE_PORTS_WORKSPACE_STEP=0.2
    export DEVZONE_WORKSPACE_WAIT=1 DEVZONE_WORKSPACE_STEP=0.1
    : >"$T/kubectl.log"
}

teardown() {
    ( cd "$T/workstation" && DEVZONE_PORTS_WORKSPACE_REAL=yes bash "$CLI" workspace ports stop >/dev/null 2>&1 ) || true
}

# Cluster Services: one "namespace|name|clusterIP|type|annotation|port/TCP," line per argument.
services() {
    : >"$T/svc"
    local l
    for l in "$@"; do echo "$l" >>"$T/svc"; done
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

@test "apps: guestbook-ui port 80 relayed on local 8080" {
    services "default|guestbook-ui|10.96.0.10|ClusterIP||80/TCP,"
    round
    [ "$status" -eq 0 ]
    [[ "$output" == *"port 8080 relayed"* ]] || false
    sleep 0.3
    grep -q -- "--namespace default port-forward --address 127.0.0.1 svc/guestbook-ui 8080:80" "$T/kubectl.log" || false
}

@test "apps: port >= 1024 free keeps the same local port" {
    services "default|web|10.96.0.11|ClusterIP||3000/TCP,"
    round
    [[ "$output" == *"port 3000 relayed"* ]] || false
    sleep 0.3
    grep -q -- "svc/web 3000:3000" "$T/kubectl.log" || false
}

@test "apps: port >= 1024 already taken on the workstation gets another port" {
    echo 3000 >"$T/taken"
    services "default|web|10.96.0.11|ClusterIP||3000/TCP,"
    round
    [[ "$output" == *"port 11000 relayed"* ]] || false
    sleep 0.3
    grep -q -- "svc/web 11000:3000" "$T/kubectl.log" || false
}

@test "apps: two Services on the same port get two local ports" {
    services "default|a|10.96.0.12|ClusterIP||80/TCP," "team|b|10.96.0.13|ClusterIP||80/TCP,"
    round
    [[ "$output" == *"port 8080 relayed"* ]] || false
    [[ "$output" == *"port 8081 relayed"* ]] || false
    sleep 0.3
    grep -q -- "svc/a 8080:80" "$T/kubectl.log" || false
    grep -q -- "svc/b 8081:80" "$T/kubectl.log" || false
}

@test "apps: kubernetes Service of default not relayed" {
    services "default|kubernetes|10.96.0.1|ClusterIP||443/TCP,"
    round
    sleep 0.3
    ! grep -q "svc/kubernetes" "$T/kubectl.log" || false
}

@test "apps: headless Service not relayed" {
    services "default|db|None|ClusterIP||5432/TCP,"
    round
    sleep 0.3
    ! grep -q "svc/db" "$T/kubectl.log" || false
}

@test "apps: ExternalName Service not relayed" {
    services "default|ext|||ExternalName||80/TCP,"
    round
    sleep 0.3
    ! grep -q "svc/ext" "$T/kubectl.log" || false
}

@test "apps: Service annotated devzone.io/relay=false not relayed" {
    services "app|quiet|10.96.0.20|ClusterIP|false|3000/TCP,"
    round
    sleep 0.3
    ! grep -q "svc/quiet" "$T/kubectl.log" || false
}

@test "apps: kube-system namespace not relayed" {
    services "kube-system|dns|10.96.0.10|ClusterIP||53/TCP,"
    round
    sleep 0.3
    ! grep -q "svc/dns" "$T/kubectl.log" || false
}

@test "apps: ports_exclus= of .devzone.modules respected" {
    echo "ports_exclus=3000" >"$T/workstation/.devzone.modules"
    services "default|web|10.96.0.11|ClusterIP||3000/TCP,"
    round
    [[ "$output" == *"port 11000 relayed"* ]] || false
    sleep 0.3
    grep -q -- "svc/web 11000:3000" "$T/kubectl.log" || false
}

@test "apps: Service gone, its relay and its attribution removed" {
    services "default|web|10.96.0.11|ClusterIP||3000/TCP,"
    round
    pid="$(cat "$T/workstation/.devzone.workspace-ports/relays/3000")"
    alive "$pid" || false
    [ -e "$T/workstation/.devzone.workspace-ports/apps/default.web.3000" ]
    services
    round
    sleep 0.3
    ! alive "$pid" || false
    [ ! -e "$T/workstation/.devzone.workspace-ports/relays/3000" ]
    [ ! -e "$T/workstation/.devzone.workspace-ports/apps/default.web.3000" ]
}

@test "apps: Service back with the same name and port gets the same local port" {
    services "default|guestbook-ui|10.96.0.10|ClusterIP||80/TCP,"
    round
    services
    round
    services "default|guestbook-ui|10.96.0.10|ClusterIP||80/TCP,"
    round
    [[ "$output" == *"port 8080 relayed"* ]] || false
}

@test "apps: cap of 30 relays, the 31st not relayed and warned once" {
    local i
    : >"$T/svc"
    for i in $(seq 31); do echo "default|s$i|10.96.1.$i|ClusterIP||$((3000 + i))/TCP," >>"$T/svc"; done
    round
    [[ "$output" == *"cap of 30"* ]] || false
    sleep 0.3
    [ "$(grep -c port-forward "$T/kubectl.log")" -eq 30 ]
    ! grep -q "svc/s31 " "$T/kubectl.log" || false
    round
    [[ "$output" != *"cap of"* ]] || false
    [ "$(grep -c port-forward "$T/kubectl.log")" -eq 30 ]
}

@test "apps: ports status shows the URL of each relayed application" {
    services "default|guestbook-ui|10.96.0.10|ClusterIP||80/TCP,"
    round
    cd "$T/workstation"
    run bash "$CLI" workspace ports status
    [[ "$output" == *"http://127.0.0.1:8080  default/guestbook-ui:80"* ]] || false
}
