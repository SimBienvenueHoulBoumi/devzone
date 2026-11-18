#!/usr/bin/env bats
# Applications relayed only when a Service has a ready pod (#638). Fake kubectl (get svc -A,
# get endpointslices -A, ss, port-forward) and fake lsof under $BATS_TEST_TMPDIR/bin: no
# cluster or workstation port is touched. Endpoint slices read $T/endpoints, one
# "namespace|service|ready," line per slice as the real jsonpath prints it.

setup() {
    load commun
    relais_docker_isole
    kube_isole
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CLI="$ROOT/manage/devzone"
    SCRIPT="$ROOT/manage/scripts/ports-workspace.sh"
    T="$BATS_TEST_TMPDIR"
    D="$T/workstation/.devzone.ports-workspace"
    mkdir -p "$T/bin" "$T/workstation"
    : >"$T/ss"
    : >"$T/svc"
    : >"$T/endpoints"
    : >"$T/taken"
    cat >"$T/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
# Fake kubectl: get endpointslices fails while $T/endpoints-fail exists (fallback test).
T="$BATS_TEST_TMPDIR"
echo "kubectl $*" >>"$T/kubectl.log"
case "$*" in
    "config get-contexts -o name") echo docker-desktop ;;
    *" exec "*" ss "*) cat "$T/ss" ;;
    "get svc -A "*) cat "$T/svc" ;;
    "get endpointslices -A "*) [ ! -e "$T/endpoints-fail" ] || exit 1; cat "$T/endpoints" ;;
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

# Cluster Services: one "namespace|name|clusterIP|type|annotation|port/TCP," line per argument.
services() {
    : >"$T/svc"
    local l
    for l in "$@"; do echo "$l" >>"$T/svc"; done
}

# Endpoint slices: one "namespace|service|ready," line per argument (none: no ready pod).
endpoints() {
    : >"$T/endpoints"
    local l
    for l in "$@"; do echo "$l" >>"$T/endpoints"; done
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

@test "ready: Service with a ready endpoint is relayed" {
    services "default|web|10.96.0.11|ClusterIP||3000/TCP,"
    endpoints "default|web|true,true,"
    round
    [ "$status" -eq 0 ]
    [[ "$output" == *"port 3000 relayed"* ]] || false
    sleep 0.3
    grep -q -- "svc/web 3000:3000" "$T/kubectl.log" || false
}

@test "ready: Service without endpoint is not relayed, marked no ready pod" {
    services "default|web|10.96.0.11|ClusterIP||3000/TCP,"
    endpoints
    round
    [ "$status" -eq 0 ]
    [[ "$output" != *"relayed"* ]] || false
    sleep 0.3
    ! grep -q "svc/web" "$T/kubectl.log" || false
    [ -e "$D/no-ready-pod/default.web.3000" ]
    [ "$(cat "$D/apps/default.web.3000")" -eq 3000 ]
}

@test "ready: slice line with an empty ready field (real kubectl format) is not relayed" {
    services "default|web|10.96.0.11|ClusterIP||3000/TCP,"
    endpoints "default|web|"
    round
    [ "$status" -eq 0 ]
    sleep 0.3
    ! grep -q "svc/web" "$T/kubectl.log" || false
    [ -e "$D/no-ready-pod/default.web.3000" ]
}

@test "ready: Service with several slices, one of them ready, is relayed" {
    services "default|web|10.96.0.11|ClusterIP||3000/TCP,"
    endpoints "default|web|false," "default|web|true,"
    round
    [[ "$output" == *"port 3000 relayed"* ]] || false
}

@test "ready: a single endpoint false is not relayed" {
    services "default|web|10.96.0.11|ClusterIP||3000/TCP,"
    endpoints "default|web|false,"
    round
    [[ "$output" != *"relayed"* ]] || false
    [ -e "$D/no-ready-pod/default.web.3000" ]
}

@test "ready: pod appears then disappears over two rounds, same local port" {
    services "default|web|10.96.0.11|ClusterIP||3000/TCP,"
    endpoints "default|web|true,"
    round
    [[ "$output" == *"port 3000 relayed"* ]] || false
    sleep 0.3
    pid="$(cat "$D/relais/3000")"
    alive "$pid" || false
    endpoints
    round
    [[ "$output" != *"relayed"* ]] || false
    [ "$(cat "$D/apps/default.web.3000")" -eq 3000 ]
    [ -e "$D/no-ready-pod/default.web.3000" ]
    sleep 0.3
    ! alive "$pid" || false
    [ ! -e "$D/relais/3000" ]
}

@test "ready: endpointslices unreadable relays every Service, warned once over two rounds" {
    services "default|web|10.96.0.11|ClusterIP||3000/TCP,"
    endpoints "default|web|false,"
    : >"$T/endpoints-fail"
    round
    [ "$status" -eq 0 ]
    [[ "$output" == *"port 3000 relayed"* ]] || false
    [[ "$output" == *"endpointslices unreadable, ready pods not checked"* ]] || false
    round
    [[ "$output" != *"endpointslices unreadable"* ]] || false
    sleep 0.3
    alive "$(cat "$D/relais/3000")" || false
    [ -e "$D/endpoints-unreadable" ]
}

@test "ready: the unreadable warning is cleared once endpointslices read again" {
    services "default|web|10.96.0.11|ClusterIP||3000/TCP,"
    endpoints "default|web|true,"
    : >"$T/endpoints-fail"
    round
    [ -e "$D/endpoints-unreadable" ]
    rm -f "$T/endpoints-fail"
    round
    [ ! -e "$D/endpoints-unreadable" ]
}

@test "ready: one endpointslices call per round" {
    services "default|a|10.96.0.12|ClusterIP||3001/TCP," "team|b|10.96.0.13|ClusterIP||3002/TCP," "team|c|10.96.0.14|ClusterIP||3003/TCP,"
    endpoints "default|a|true," "team|b|true," "team|c|false,"
    round
    round
    [ "$(grep -c "get endpointslices" "$T/kubectl.log")" -eq 2 ]
}

@test "ready: Services without ready pod do not count against the cap of 30" {
    local i
    : >"$T/svc"
    : >"$T/endpoints"
    echo "default|pending|10.96.2.1|ClusterIP||9000/TCP," >>"$T/svc"
    for i in $(seq 30); do
        echo "default|s$i|10.96.1.$i|ClusterIP||$((3000 + i))/TCP," >>"$T/svc"
        echo "default|s$i|true," >>"$T/endpoints"
    done
    round
    [[ "$output" != *"cap of"* ]] || false
    sleep 0.3
    [ "$(grep -c port-forward "$T/kubectl.log")" -eq 30 ]
    ! grep -q "svc/pending" "$T/kubectl.log" || false
    [ -e "$D/no-ready-pod/default.pending.9000" ]
}

@test "ready: ports status lists a Service without ready pod with its local URL" {
    services "default|web|10.96.0.11|ClusterIP||3000/TCP,"
    endpoints
    round
    cd "$T/workstation"
    run bash "$CLI" workspace ports status
    [[ "$output" == *"http://127.0.0.1:3000  default/web:3000  no ready pod"* ]] || false
}
