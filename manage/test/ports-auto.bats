#!/usr/bin/env bats
# Automatic port watcher (#394): one testable pass of the loop, without an endless
# loop; fake ss, docker and socat in the PATH, no container started.

setup() {
    load commun
    kube_isole
    PORTS_AUTO="$BATS_TEST_DIRNAME/../../.devcontainer/ports-auto.sh"
    PORTS="$BATS_TEST_DIRNAME/../../.devcontainer/ports.sh"
    export DEVZONE_ROOT="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_STATE="$BATS_TEST_TMPDIR/etat"
    export DEVZONE_INSTANCE=devzone
    export DEVZONE_PORTS_AUTO_DIR="$BATS_TEST_TMPDIR/ports-auto"
    export DEVZONE_PORTS_AUTO_DELAY=1
    mkdir -p "$BATS_TEST_TMPDIR/bin" "$DEVZONE_ROOT/workspace"
    : >"$DEVZONE_STATE"
    : >"$BATS_TEST_TMPDIR/docker.log"
    : >"$BATS_TEST_TMPDIR/socat.log"
    : >"$BATS_TEST_TMPDIR/ss.listen"

    cat >"$BATS_TEST_TMPDIR/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
echo "docker $*" >>"$T/docker.log"
case "${1:-}" in
    inspect)
        case "$*" in
            *NetworkSettings.Networks*)
                echo "devzone_default 172.18.0.5"
                ;;
            *) exit 1 ;;
        esac
        ;;
    run)
        name=""; prec=""
        for a in "$@"; do
            [ "$prec" = --name ] && name="$a"
            prec="$a"
        done
        if [ "${FAKE_ECHEC_PORT:-}" = "${name##*-}" ]; then
            echo "docker: Error response from daemon: Bind for 127.0.0.1:${name##*-} failed: port is already allocated." >&2
            exit 1
        fi
        case "${FAKE_RUN_ECHEC:-}" in
            allocation) echo "docker: Error response from daemon: Bind for 127.0.0.1:8080 failed: port is already allocated." >&2; exit 1 ;;
            adresse) echo "docker: Error response from daemon: address already in use" >&2; exit 1 ;;
            autre) echo "docker: daemon error" >&2; exit 1 ;;
        esac
        mkdir -p "$T/relays"
        : >"$T/relays/$name"
        echo "id-$name"
        ;;
    ps)
        pattern=""; prec=""; show_all=0
        for a in "$@"; do
            [ "$a" = "-a" ] && show_all=1
            [ "$prec" = --filter ] && pattern="$a"
            prec="$a"
        done
        for f in "$T"/relays/*; do
            [ -e "$f" ] || continue
            name="$(basename "$f")"
            m="${pattern#name=}"
            m="${m#^}"
            m="${m%$}"
            if [ "$name" = "$m" ] || [ "${name#"$m"}" != "$name" ]; then
                if [ "$show_all" = 1 ] || [ ! -s "$f" ]; then
                    echo "$name"
                fi
            fi
        done
        ;;
    rm)
        name="${3:-${2:-}}"
        rm -f "$T/relays/$name"
        ;;
esac
exit 0
DOCKER

    cat >"$BATS_TEST_TMPDIR/bin/socat" <<'SOCAT'
#!/usr/bin/env bash
echo "socat $*" >>"$BATS_TEST_TMPDIR/socat.log"
exit 0
SOCAT

    cat >"$BATS_TEST_TMPDIR/bin/ss" <<'SS'
#!/usr/bin/env bash
cat "$BATS_TEST_TMPDIR/ss.listen"
SS

    cat >"$BATS_TEST_TMPDIR/bin/curl" <<'CURL'
#!/usr/bin/env bash
echo "curl $*" >>"$BATS_TEST_TMPDIR/curl.log"
for p in ${FAKE_REPOND:-}; do
    case "$*" in *":$p"*) exit 0 ;; esac
done
exit 7
CURL

    chmod +x "$BATS_TEST_TMPDIR/bin/"*
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "auto: port listening on 0.0.0.0 -> workstation relay, no bridge" {
    printf 'LISTEN 0 511 0.0.0.0:8080 0.0.0.0:*\n' >"$BATS_TEST_TMPDIR/ss.listen"
    run bash "$PORTS_AUTO" tour
    [ "$status" -eq 0 ]
    grep -q 'docker run -d --restart unless-stopped --name devzone-devzone-auto-8080' "$BATS_TEST_TMPDIR/docker.log"
    grep -q -- '-p 127.0.0.1:8080:8080' "$BATS_TEST_TMPDIR/docker.log"
    grep -q 'tcp-connect:172.18.0.5:8080' "$BATS_TEST_TMPDIR/docker.log"
    [ ! -s "$BATS_TEST_TMPDIR/socat.log" ]
}

@test "auto: port listening on 127.0.0.1 -> bridge on the container IP, then relay" {
    printf 'LISTEN 0 511 127.0.0.1:8080 127.0.0.1:*\n' >"$BATS_TEST_TMPDIR/ss.listen"
    run bash "$PORTS_AUTO" tour
    [ "$status" -eq 0 ]
    grep -q 'socat TCP-LISTEN:8080,bind=172.18.0.5,fork,reuseaddr' "$BATS_TEST_TMPDIR/socat.log"
    grep -q 'TCP:127.0.0.1:8080' "$BATS_TEST_TMPDIR/socat.log"
    grep -q 'docker run -d --restart unless-stopped --name devzone-devzone-auto-8080' "$BATS_TEST_TMPDIR/docker.log"
}

@test "auto: vanished port -> bridge and relay removed after the delay" {
    printf 'LISTEN 0 511 127.0.0.1:8080 127.0.0.1:*\n' >"$BATS_TEST_TMPDIR/ss.listen"
    run bash "$PORTS_AUTO" tour
    [ "$status" -eq 0 ]
    grep -q 'docker run -d --restart unless-stopped --name devzone-devzone-auto-8080' "$BATS_TEST_TMPDIR/docker.log"
    : >"$BATS_TEST_TMPDIR/ss.listen"
    run bash "$PORTS_AUTO" tour
    [ "$status" -eq 0 ]
    sleep 2
    run bash "$PORTS_AUTO" tour
    [ "$status" -eq 0 ]
    grep -q 'docker rm -f devzone-devzone-auto-8080' "$BATS_TEST_TMPDIR/docker.log"
}

@test "auto: ports below 1024, Docker DNS, devzone services, manual, excluded are ignored" {
    printf 'ports=3000\nports_exclus=8080\n' >"$DEVZONE_STATE"
    cat >"$BATS_TEST_TMPDIR/ss.listen" <<'SS'
LISTEN 0 511 127.0.0.1:80 127.0.0.1:*
LISTEN 0 511 127.0.0.1:5432 127.0.0.1:*
LISTEN 0 511 127.0.0.1:8080 127.0.0.1:*
LISTEN 0 511 127.0.0.1:8929 127.0.0.1:*
LISTEN 0 511 127.0.0.1:2224 127.0.0.1:*
LISTEN 0 511 127.0.0.1:3000 127.0.0.1:*
SS
    run bash "$PORTS_AUTO" tour
    [ "$status" -eq 0 ]
    [ "$(grep -c 'docker run' "$BATS_TEST_TMPDIR/docker.log")" -eq 0 ]
}

@test "auto: port taken on the workstation -> busy, no new try" {
    printf 'LISTEN 0 511 0.0.0.0:8080 0.0.0.0:*\n' >"$BATS_TEST_TMPDIR/ss.listen"
    FAKE_ECHEC_PORT=8080 run bash "$PORTS_AUTO" tour
    [ "$status" -eq 0 ]
    [ "$(grep -c 'docker run' "$BATS_TEST_TMPDIR/docker.log")" -eq 1 ]
    FAKE_ECHEC_PORT=8080 run bash "$PORTS_AUTO" tour
    [ "$(grep -c 'docker run' "$BATS_TEST_TMPDIR/docker.log")" -eq 1 ]
    run bash "$PORTS_AUTO" list_auto
    [ "$status" -eq 0 ]
    [[ "$output" == *"8080"*"busy on the workstation"* ]] || false
}

@test "auto off: no relay on the next pass, automatic relays removed" {
    printf 'LISTEN 0 511 127.0.0.1:8080 127.0.0.1:*\n' >"$BATS_TEST_TMPDIR/ss.listen"
    run bash "$PORTS_AUTO" tour
    [ "$status" -eq 0 ]
    grep -q 'docker run -d --restart unless-stopped --name devzone-devzone-auto-8080' "$BATS_TEST_TMPDIR/docker.log"
    run bash "$PORTS" auto off
    [ "$status" -eq 0 ]
    grep -qx 'ports_auto=off' "$DEVZONE_STATE"
    [[ "$output" == *"automatic ports disabled"* ]] || false
    : >"$BATS_TEST_TMPDIR/docker.log"
    run bash "$PORTS_AUTO" tour
    [ "$status" -eq 0 ]
    [ "$(grep -c 'docker run' "$BATS_TEST_TMPDIR/docker.log")" -eq 0 ]
}

@test "watcher: loop and demarrer refuse under bats (code 2), nothing started" {
    run bash "$PORTS_AUTO" boucle
    [ "$status" -eq 2 ]
    [[ "$output" == *"refused"* ]] || false
    run bash "$PORTS_AUTO" demarrer
    [ "$status" -eq 2 ]
    [[ "$output" == *"refused"* ]] || false
    # The guard acts first: no lock, no relay, no bridge.
    [ ! -e "$DEVZONE_PORTS_AUTO_DIR/devzone/verrou" ]
    [ "$(grep -c 'docker run' "$BATS_TEST_TMPDIR/docker.log")" -eq 0 ]
    [ ! -s "$BATS_TEST_TMPDIR/socat.log" ]
}

@test "watcher: refusal without the real context, devzone repair message (code 2)" {
    # bats is also unset here: guarantees that the real refusal message is reached
    run env -u BATS_TEST_TMPDIR bash "$PORTS_AUTO" boucle
    [ "$status" -eq 2 ]
    [[ "$output" == *"devzone repair"* ]] || false
    run env -u BATS_TEST_TMPDIR bash "$PORTS_AUTO" demarrer
    [ "$status" -eq 2 ]
    [[ "$output" == *"devzone repair"* ]] || false
    [ ! -e "$DEVZONE_PORTS_AUTO_DIR/devzone/verrou" ]
}

@test "watcher: refused even with the real context set, under bats (code 2)" {
    DEVZONE_PORTS_AUTO_REAL=yes run bash "$PORTS_AUTO" boucle
    [ "$status" -eq 2 ]
    DEVZONE_PORTS_AUTO_REAL=yes run bash "$PORTS_AUTO" demarrer
    [ "$status" -eq 2 ]
    [ ! -e "$DEVZONE_PORTS_AUTO_DIR/devzone/verrou" ]
    [ "$(grep -c 'docker run' "$BATS_TEST_TMPDIR/docker.log")" -eq 0 ]
}

@test "kubernetes: demarrer exits 0 without watcher nor docker relay (#517)" {
    # Before the guard: even under bats, Kubernetes mode does not refuse, it starts nothing
    DEVZONE_WORKSPACE=kubernetes run bash "$PORTS_AUTO" demarrer
    [ "$status" -eq 0 ]
    [[ "$output" == *"ports go through devzone workspace ports"* ]] || false
    [ ! -s "$BATS_TEST_TMPDIR/docker.log" ] || false
    [ ! -s "$BATS_TEST_TMPDIR/socat.log" ] || false
    [ ! -e "$DEVZONE_PORTS_AUTO_DIR/devzone/verrou" ] || false
}

@test "watcher: lock recycled from a dead instance, held by a live one that refreshes it, stolen when stale" {
    run bash -c '
    . "$1"
    mkdir -p "$LOCK"
    echo 4194303 >"$LOCK/pid" # pid beyond the kernel limit: holder dead
    lock_take; echo "rc_dead=$?"
    echo $$ >"$LOCK/pid"      # live holder (this shell), lock old
    touch -d "2 minutes ago" "$LOCK"
    lock_refresh
    lock_take; echo "rc_alive=$?"
    touch -d "2 minutes ago" "$LOCK"
    lock_take; echo "rc_stale=$?"
    ' x "$PORTS_AUTO"
    [ "$status" -eq 0 ]
    [[ "$output" == *"rc_dead=0"* ]] || false
    [[ "$output" == *"rc_alive=1"* ]] || false
    [[ "$output" == *"rc_stale=0"* ]] || false
}

@test "isolation: a real watcher in another folder is neither read nor changed" {
    # Fake state of a real watcher, set outside the test folder (#394).
    local real="$BATS_TEST_TMPDIR/real"
    mkdir -p "$real/devzone/bridges" "$real/devzone/verrou"
    echo $$ >"$real/devzone/verrou/pid"
    printf '8081\n' >"$real/devzone/occupes"
    printf 'LISTEN 0 511 127.0.0.1:8081 127.0.0.1:*\n' >"$real/devzone/actifs"
    before="$(find "$real" -printf '%p %s %T@\n' | sort; cat "$real/devzone/verrou/pid" "$real/devzone/occupes" "$real/devzone/actifs")"
    printf 'LISTEN 0 511 127.0.0.1:8080 127.0.0.1:*\n' >"$BATS_TEST_TMPDIR/ss.listen"
    # The test folder is the one of the test, not the one of the real watcher.
    run bash -c '. "$1"; echo "$BASE"' x "$PORTS_AUTO"
    [ "$status" -eq 0 ]
    [ "$output" = "$BATS_TEST_TMPDIR/ports-auto/devzone" ]
    run bash "$PORTS_AUTO" tour
    [ "$status" -eq 0 ]
    grep -q 'docker run -d --restart unless-stopped --name devzone-devzone-auto-8080' "$BATS_TEST_TMPDIR/docker.log"
    [ -d "$BATS_TEST_TMPDIR/ports-auto/devzone/bridges" ]
    after="$(find "$real" -printf '%p %s %T@\n' | sort; cat "$real/devzone/verrou/pid" "$real/devzone/occupes" "$real/devzone/actifs")"
    [ "$before" = "$after" ]
}

@test "teardown: only a watcher started by the test is orphaned, never the real one" {
    # Fake watcher started by the test: same command name, BATS_TEST_TMPDIR inherited.
    bash -c 'exec -a "bash .devcontainer/ports-auto.sh boucle" sleep 60' >/dev/null 2>&1 &
    fake=$!
    # Fake watcher without BATS_TEST_TMPDIR: stands for the real watcher of the container.
    env -u BATS_TEST_TMPDIR bash -c 'exec -a "bash .devcontainer/ports-auto.sh boucle" sleep 60' >/dev/null 2>&1 &
    real=$!
    run orphans_of_test
    [ "$status" -eq 0 ]
    echo "$output" | grep -qx "$fake"
    [ "$(echo "$output" | grep -cx "$real")" -eq 0 ]
    kill "$fake" "$real"
    wait "$fake" 2>/dev/null || true
    wait "$real" 2>/dev/null || true
    run orphans_of_test
    [ -z "$output" ]
}

# Pids of the ports-auto.sh watchers (boucle or demarrer) whose environment
# carries BATS_TEST_TMPDIR of this test; the real watcher of the container has none.
orphans_of_test() {
    local pid
    for pid in $(pgrep -f "bash +[^ ]*ports-auto[.]sh (boucle|demarrer)" 2>/dev/null); do
        if tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep -qxF "BATS_TEST_TMPDIR=$BATS_TEST_TMPDIR"; then
            echo "$pid"
        fi
    done
}

teardown() {
    # Incident #394: no watcher started by a test may survive the test.
    local orphans
    orphans="$(orphans_of_test)"
    if [ -n "$orphans" ]; then
        echo "orphan watchers of the test: $orphans" >&2
        return 1
    fi
    return 0
}
