#!/usr/bin/env bats
# Docker socket relay (#293): the feature's socat without -t is replaced
# by the same with -t 86400, then a long docker exec is checked. Fake ps,
# sudo, kill, setsid and docker in the PATH, paths under $BATS_TEST_TMPDIR:
# no real socat, sudo nor kill.

setup() {
    load commun
    relais_docker_isole
    kube_isole
    kind_vide
    RELAIS="$BATS_TEST_DIRNAME/../../.devcontainer/docker-relay.sh"
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    T="$BATS_TEST_TMPDIR"
    export DEVZONE_RELAY_SUDO=sudo
    export DEVZONE_RELAY_WAIT=2
    unset DEVZONE_RELAY_REAL DEVZONE_RELAY_DOCKER DEVZONE_RELAY_USER
    mkdir -p "$T/bin"
    : >"$T/ps.txt"
    : >"$T/outils.log"
    : >"$DEVZONE_RELAY_SOCKET"

    # ps -eo pid=,args=: the test's list
    cat >"$T/bin/ps" <<'OUTIL'
#!/usr/bin/env bash
cat "$BATS_TEST_TMPDIR/ps.txt"
OUTIL
    # sudo: logged, then run without privilege
    cat >"$T/bin/sudo" <<'OUTIL'
#!/usr/bin/env bash
echo "sudo $*" >>"$BATS_TEST_TMPDIR/outils.log"
exec "$@"
OUTIL
    # kill: logged; kill -0 → process already ended
    cat >"$T/bin/kill" <<'OUTIL'
#!/usr/bin/env bash
echo "kill $*" >>"$BATS_TEST_TMPDIR/outils.log"
[ "${1:-}" = -0 ] && exit 1
exit 0
OUTIL

    # setsid -f socat … : logged; the new socat appears in ps
    cat >"$T/bin/setsid" <<'OUTIL'
#!/usr/bin/env bash
echo "setsid $*" >>"$BATS_TEST_TMPDIR/outils.log"
[ "${1:-}" = -f ] && shift
echo "4242 $*" >"$BATS_TEST_TMPDIR/ps.txt"
OUTIL
    # docker: version according to FAKE_VERSION, exec shows FAKE_EXEC
    cat >"$T/bin/docker" <<'OUTIL'
#!/usr/bin/env bash
echo "docker $*" >>"$BATS_TEST_TMPDIR/outils.log"
case "${1:-}" in
    version) exit "${FAKE_VERSION:-0}" ;;
    exec) printf '%s\n' "${FAKE_EXEC-ok}" ;;
esac
OUTIL
    chmod +x "$T/bin/"*
    export PATH="$T/bin:$PATH"
}

relay_feature() {
    printf '39 socat UNIX-LISTEN:%s,fork,mode=660,user=vscode,backlog=128 UNIX-CONNECT:%s\n' \
        "$DEVZONE_RELAY_SOCKET" "$DEVZONE_RELAY_SOURCE" >"$T/ps.txt"
}

@test "guard : real socket refused under bats even with DEVZONE_RELAY_REAL=yes (code 2, nothing touched)" {
    export DEVZONE_RELAY_SOCKET=/var/run/docker.sock
    export DEVZONE_RELAY_REAL=yes
    relay_feature
    run bash "$RELAIS"
    [ "$status" -eq 2 ]
    [[ "$output" == *"docker-relay : refused under bats (tests)"* ]] || false
    [ ! -s "$T/outils.log" ]
    [ ! -e "$DEVZONE_RELAY_MARKER" ]
}

@test "feature relay without -t: replaced by socat -t 86400, same options" {
    relay_feature
    run bash "$RELAIS"
    [ "$status" -eq 0 ]
    grep -qx "sudo kill 39" "$T/outils.log"
    grep -qx "sudo rm -f $DEVZONE_RELAY_SOCKET" "$T/outils.log"
    grep -qx "setsid -f socat -t 86400 -lf $DEVZONE_RELAY_LOG UNIX-LISTEN:$DEVZONE_RELAY_SOCKET,fork,mode=660,user=vscode,backlog=128 UNIX-CONNECT:$DEVZONE_RELAY_SOURCE" "$T/outils.log"
    [ ! -e "$DEVZONE_RELAY_SOCKET" ]
    [ "$(cat "$DEVZONE_RELAY_PID")" = 4242 ]
    [[ "$output" == *"socat -t 86400"* ]] || false
}

@test "relay already with -t: left as is, check done" {
    printf '39 socat -t 86400 UNIX-LISTEN:%s,fork,mode=660,user=vscode,backlog=128 UNIX-CONNECT:%s\n' \
        "$DEVZONE_RELAY_SOCKET" "$DEVZONE_RELAY_SOURCE" >"$T/ps.txt"
    run bash "$RELAIS"
    [ "$status" -eq 0 ]
    ! grep -q "kill\|setsid" "$T/outils.log" || false
    grep -q "docker exec" "$T/outils.log"
}

@test "socat on another socket, or parent sudo: ignored" {
    printf '7 socat UNIX-LISTEN:/other.sock,fork UNIX-CONNECT:/x\n8 sudo socat UNIX-LISTEN:%s,fork UNIX-CONNECT:/x\n' \
        "$DEVZONE_RELAY_SOCKET" >"$T/ps.txt"
    run bash "$RELAIS"
    [ "$status" -eq 0 ]
    ! grep -q "kill\|setsid" "$T/outils.log" || false
}

@test "no socat relay (Linux, socket by group): only the check" {
    run bash "$RELAIS"
    [ "$status" -eq 0 ]
    ! grep -q "kill\|setsid" "$T/outils.log" || false
    grep -q "docker exec .* sh -c sleep 1; echo ok" "$T/outils.log"
}

@test "long docker exec cut: code 1, mark written" {
    export FAKE_EXEC=""
    run bash "$RELAIS"
    [ "$status" -eq 1 ]
    [[ "$output" == *"long docker exec cut"* ]] || false
    grep -q "long docker exec cut" "$DEVZONE_RELAY_MARKER"
}

@test "socket not answering: code 1, mark written" {
    export FAKE_VERSION=1
    run bash "$RELAIS"
    [ "$status" -eq 1 ]
    grep -q "does not answer" "$DEVZONE_RELAY_MARKER"
}

@test "check succeeded: mark of a previous failure erased" {
    echo "previous failure" >"$DEVZONE_RELAY_MARKER"
    run bash "$RELAIS"
    [ "$status" -eq 0 ]
    [ ! -e "$DEVZONE_RELAY_MARKER" ]
}

@test "as root: no sudo" {
    export DEVZONE_RELAY_SUDO=""
    relay_feature
    run bash "$RELAIS"
    [ "$status" -eq 0 ]
    ! grep -q "^sudo" "$T/outils.log" || false
    grep -qx "kill 39" "$T/outils.log"
}

@test "no socket (docker-hote=off): code 0, no Docker check, no mark" {
    rm -f "$DEVZONE_RELAY_SOCKET"
    echo "previous failure" >"$DEVZONE_RELAY_MARKER"
    run bash "$RELAIS"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no host Docker socket"* ]] || false
    ! grep -q docker "$T/outils.log" || false
    [ ! -e "$DEVZONE_RELAY_MARKER" ]
}

@test "docker without host: clear message towards the Kubernetes workspace" {
    run bash "$BATS_TEST_DIRNAME/../../.devcontainer/docker-without-host.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"devzone workspace"* ]] || false
    [[ "$output" == *"docker-hote"* ]] || false
}

@test "devzone : summary ⚠ Docker relay if the mark exists" {
    export HOME="$T/home" DEVZONE_ROOT="$T/racine" DEVZONE_STATE="$T/etat"
    mkdir -p "$HOME" "$DEVZONE_ROOT/workspace"
    : >"$DEVZONE_STATE"
    run bash "$DEVZONE"
    [[ "$output" != *"Docker relay"* ]] || false
    echo "long docker exec cut (output: empty)" >"$DEVZONE_RELAY_MARKER"
    run bash "$DEVZONE"
    [[ "$output" == *"⚠ Docker relay     long docker exec cut"*"devzone repair"* ]] || false
}
