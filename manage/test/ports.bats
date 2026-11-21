#!/usr/bin/env bats
# Port relays (#290): one alpine/socat container per port, on the host's Docker,
# from 127.0.0.1 of the workstation to the IP of the devzone container. Fake docker
# and curl in the PATH: no container started, arguments logged.

setup() {
    load commun
    kind_vide
    kube_isole
    PORTS="$BATS_TEST_DIRNAME/../../.devcontainer/ports.sh"
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    export HOME="$BATS_TEST_TMPDIR/home"
    export DEVZONE_RACINE="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_ETAT="$BATS_TEST_TMPDIR/etat"
    export DEVZONE_INSTANCE=devzone
    mkdir -p "$HOME" "$DEVZONE_RACINE/workspace" "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/relays"
    # the automatic port watcher stays under the test folder (#394)
    export DEVZONE_PORTS_AUTO_DIR="$BATS_TEST_TMPDIR/ports-auto"
    : >"$DEVZONE_ETAT"
    : >"$BATS_TEST_TMPDIR/docker.log"
    : >"$BATS_TEST_TMPDIR/curl.log"

    cat >"$BATS_TEST_TMPDIR/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
echo "docker $*" >>"$T/docker.log"
case "${1:-}" in
    inspect)
        case "$*" in
            *NetworkSettings.Networks*)
                [ "${FAKE_SANS_CONTENEUR:-0}" = 1 ] && exit 1
                echo "devzone_default 172.18.0.5"
                ;;
            *)
                name="${2:-}"
                [ -f "$T/relays/$name" ] || exit 1
                case "$*" in *State.Running*) echo true ;; esac
                ;;
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
            allocation)
                echo "docker: Error response from daemon: Bind for 127.0.0.1:8080 failed: port is already allocated." >&2
                exit 1
                ;;
            adresse)
                echo "docker: Error response from daemon: address already in use" >&2
                exit 1
                ;;
            autre)
                echo "docker: daemon error" >&2
                exit 1
                ;;
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
            if [ "$name" = "$m" ]; then
                if [ "$show_all" = 1 ] || [ ! -s "$f" ]; then
                    echo "$name"
                fi
            fi
        done
        ;;
    stop)
        name="${2:-}"
        [ -f "$T/relays/$name" ] && echo stopped >"$T/relays/$name"
        ;;
    rm)
        name="${3:-${2:-}}"
        rm -f "$T/relays/$name"
        ;;
esac
exit 0
DOCKER

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

@test "open: socat relay to the container IP, labelled, sorted state" {
    run bash "$PORTS" 8080
    [ "$status" -eq 0 ]
    grep -q 'docker run -d --restart unless-stopped --name devzone-devzone-port-8080' "$BATS_TEST_TMPDIR/docker.log"
    grep -q -- '--label devzone.instance=devzone' "$BATS_TEST_TMPDIR/docker.log"
    grep -q -- '--label devzone.port=8080' "$BATS_TEST_TMPDIR/docker.log"
    grep -q -- '--network devzone_default' "$BATS_TEST_TMPDIR/docker.log"
    grep -q -- '-p 127.0.0.1:8080:8080' "$BATS_TEST_TMPDIR/docker.log"
    grep -q 'alpine/socat:1.8.0.3 tcp-listen:8080,fork,reuseaddr tcp-connect:172.18.0.5:8080' "$BATS_TEST_TMPDIR/docker.log"
    grep -qx 'ports=8080' "$DEVZONE_ETAT"
    [[ "$output" == *"127.0.0.1:8080 on the workstation"*"8080 in the container"* ]] || false
}

@test "open: relay already open is idempotent, state completed without a second docker run" {
    bash "$PORTS" 8080
    run bash "$PORTS" 8080
    [ "$status" -eq 0 ]
    [ "$(grep -c 'docker run' "$BATS_TEST_TMPDIR/docker.log")" -eq 1 ]
    [[ "$output" == *"already open"* ]] || false
    grep -qx 'ports=8080' "$DEVZONE_ETAT"
}

@test "open: stopped relay -> rm -f then run toward the current IP" {
    printf 'ports=8080\n' >"$DEVZONE_ETAT"
    bash "$PORTS" 8080 >/dev/null
    run "$BATS_TEST_TMPDIR/bin/docker" stop devzone-devzone-port-8080
    [ "$status" -eq 0 ]
    : >"$BATS_TEST_TMPDIR/docker.log"
    run bash "$PORTS" 8080
    [ "$status" -eq 0 ]
    grep -q 'docker rm -f devzone-devzone-port-8080' "$BATS_TEST_TMPDIR/docker.log"
    grep -q 'docker run -d --restart unless-stopped --name devzone-devzone-port-8080' "$BATS_TEST_TMPDIR/docker.log"
    grep -q 'tcp-connect:172.18.0.5:8080' "$BATS_TEST_TMPDIR/docker.log"
    [ "$(grep -c 'docker run' "$BATS_TEST_TMPDIR/docker.log")" -eq 1 ]
    grep -qx 'ports=8080' "$DEVZONE_ETAT"
    [[ "$output" == *"127.0.0.1:8080 on the workstation"*"8080 in the container"* ]] || false
}

@test "open: the state keeps the other lines and sorts the ports" {
    printf 'ia=on\nports=3000\n' >"$DEVZONE_ETAT"
    run bash "$PORTS" 8080
    [ "$status" -eq 0 ]
    grep -qx 'ia=on' "$DEVZONE_ETAT"
    grep -qx 'ports=3000,8080' "$DEVZONE_ETAT"
}

@test "open: invalid port refused (code 1), no relay, state intact" {
    printf 'ports=3000\n' >"$DEVZONE_ETAT"
    for p in "" 0 65536 abc 80a -1 999999999999999999999; do
        run bash "$PORTS" open "$p"
        [ "$status" -eq 1 ]
        [[ "$output" == *"invalid port"* ]] || false
    done
    ! grep -q 'docker run' "$BATS_TEST_TMPDIR/docker.log" || false
    grep -qx 'ports=3000' "$DEVZONE_ETAT"
}

@test "open: devzone container not found (host Docker absent) -> refused, code 1" {
    FAKE_SANS_CONTENEUR=1 run bash "$PORTS" 8080
    [ "$status" -eq 1 ]
    [[ "$output" == *"devzone container not found"* ]] || false
    [ ! -s "$DEVZONE_ETAT" ]
}

@test "open: port already taken on the workstation -> clear refusal, state unchanged" {
    for case_name in allocation adresse; do
        : >"$DEVZONE_ETAT"
        FAKE_RUN_ECHEC="$case_name" run bash "$PORTS" 8080
        [ "$status" -eq 1 ]
        [[ "$output" == *"port already in use on the workstation : 8080"* ]] || false
        [ ! -s "$DEVZONE_ETAT" ]
    done
}

@test "open: other docker run failure -> relay message, code 1" {
    FAKE_RUN_ECHEC=autre run bash "$PORTS" 8080
    [ "$status" -eq 1 ]
    [[ "$output" == *"relay on port 8080 failed"*"daemon error"* ]] || false
    [ ! -s "$DEVZONE_ETAT" ]
}

@test "list: sorted without duplicate, ● active, ○ stopped, application behind" {
    printf 'ports=3000,8080,8080\n' >"$DEVZONE_ETAT"
    : >"$BATS_TEST_TMPDIR/relays/devzone-devzone-port-8080"
    FAKE_REPOND=8080 run bash "$PORTS" list
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c '^')" -eq 2 ]
    printf '%s\n' "$output" | sed -n '1p' | grep -q '3000 *○ stopped *no application'
    printf '%s\n' "$output" | sed -n '2p' | grep -q '8080 *● active *application responds'
    grep -q -- '--max-time 2 http://127.0.0.1:3000' "$BATS_TEST_TMPDIR/curl.log"
    grep -q -- '--max-time 2 http://127.0.0.1:8080' "$BATS_TEST_TMPDIR/curl.log"
}

@test "list: no relay" {
    run bash "$PORTS"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no relay"* ]] || false
}

@test "close: relay removed, port removed from the state, other ports kept" {
    bash "$PORTS" 8080
    bash "$PORTS" 3000
    run bash "$PORTS" --close 8080
    [ "$status" -eq 0 ]
    grep -q 'docker rm -f devzone-devzone-port-8080' "$BATS_TEST_TMPDIR/docker.log"
    [ ! -e "$BATS_TEST_TMPDIR/relays/devzone-devzone-port-8080" ]
    grep -qx 'ports=3000' "$DEVZONE_ETAT"
    run bash "$PORTS" close 3000
    [ "$status" -eq 0 ]
    grep -qx 'ports=' "$DEVZONE_ETAT"
}

@test "close: invalid port refused (code 1)" {
    run bash "$PORTS" --close 70000
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid port"* ]] || false
}

@test "restart: each relay recreated toward the current IP, state unchanged" {
    printf 'ports=3000,8080\n' >"$DEVZONE_ETAT"
    : >"$BATS_TEST_TMPDIR/relays/devzone-devzone-port-3000"
    : >"$BATS_TEST_TMPDIR/relays/devzone-devzone-port-8080"
    run bash "$PORTS" restart
    [ "$status" -eq 0 ]
    grep -q 'docker rm -f devzone-devzone-port-3000' "$BATS_TEST_TMPDIR/docker.log"
    grep -q 'docker rm -f devzone-devzone-port-8080' "$BATS_TEST_TMPDIR/docker.log"
    [ "$(grep -c 'docker run' "$BATS_TEST_TMPDIR/docker.log")" -eq 2 ]
    grep -q 'tcp-connect:172.18.0.5:3000' "$BATS_TEST_TMPDIR/docker.log"
    grep -q 'tcp-connect:172.18.0.5:8080' "$BATS_TEST_TMPDIR/docker.log"
    grep -qx 'ports=3000,8080' "$DEVZONE_ETAT"
}

@test "restart: a failure warns without blocking the others, code 1" {
    printf 'ports=3000,8080\n' >"$DEVZONE_ETAT"
    FAKE_ECHEC_PORT=3000 run bash "$PORTS" restart
    [ "$status" -eq 1 ]
    [[ "$output" == *"port already in use on the workstation : 3000"* ]] || false
    [ "$(grep -c 'docker run' "$BATS_TEST_TMPDIR/docker.log")" -eq 2 ]
    grep -q 'tcp-connect:172.18.0.5:8080' "$BATS_TEST_TMPDIR/docker.log"
    grep -qx 'ports=3000,8080' "$DEVZONE_ETAT"
}

@test "restart: container not found -> warning, code 1, state intact" {
    printf 'ports=8080\n' >"$DEVZONE_ETAT"
    FAKE_SANS_CONTENEUR=1 run bash "$PORTS" restart
    [ "$status" -eq 1 ]
    [[ "$output" == *"relays not restarted"* ]] || false
    grep -qx 'ports=8080' "$DEVZONE_ETAT"
}

@test "instance: name and label specific to DEVZONE_INSTANCE" {
    export DEVZONE_INSTANCE=mon-devzone
    run bash "$PORTS" 8080
    [ "$status" -eq 0 ]
    grep -q -- '--name devzone-mon-devzone-port-8080' "$BATS_TEST_TMPDIR/docker.log"
    grep -q -- '--label devzone.instance=mon-devzone' "$BATS_TEST_TMPDIR/docker.log"
}

@test "devzone port: open, list and close through the command routing" {
    run bash "$DEVZONE" port 8080
    [ "$status" -eq 0 ]
    grep -qx 'ports=8080' "$DEVZONE_ETAT"
    : >"$BATS_TEST_TMPDIR/relays/devzone-devzone-port-8080"

    run bash "$DEVZONE" port
    [ "$status" -eq 0 ]
    [[ "$output" == *"8080"*"● active"* ]] || false

    run bash "$DEVZONE" port --close 8080
    [ "$status" -eq 0 ]
    grep -qx 'ports=' "$DEVZONE_ETAT"
}

@test "devzone: ports recap for the workstation, active then none" {
    printf 'ports=8080\n' >"$DEVZONE_ETAT"
    : >"$BATS_TEST_TMPDIR/relays/devzone-devzone-port-8080"
    run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"✔ ports to the workstation 8080 ●"* ]] || false

    printf 'ports=\n' >"$DEVZONE_ETAT"
    run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"○ ports to the workstation none (devzone port <n>)"* ]] || false
}

@test "devzone --help cites devzone port" {
    run bash "$DEVZONE" --help
    [[ "$output" == *"devzone port [<n>|--close <n>]"* ]] || false
}

@test "open without DEVZONE_ETAT nor DEVZONE_RACINE" {
    unset DEVZONE_ETAT DEVZONE_RACINE
    mkdir -p "$BATS_TEST_TMPDIR/repo"
    cp -r "$BATS_TEST_DIRNAME/../../.devcontainer" "$BATS_TEST_TMPDIR/repo/.devcontainer"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    run bash "$BATS_TEST_TMPDIR/repo/.devcontainer/ports.sh" 8080
    [ "$status" -eq 0 ]
    grep -qx 'ports=8080' "$BATS_TEST_TMPDIR/repo/.devzone.modules"
    [[ "$output" == *"127.0.0.1:8080 on the workstation"*"8080 in the container"* ]] || false
}

@test "write_ports: write failure on stderr, code 1" {
    unset DEVZONE_ETAT DEVZONE_RACINE
    mkdir -p "$BATS_TEST_TMPDIR/repo"
    cp -r "$BATS_TEST_DIRNAME/../../.devcontainer" "$BATS_TEST_TMPDIR/repo/.devcontainer"
    export TMPDIR="/nonexistent"
    # Since #417 the temporary file is created in the state folder (never in
    # TMPDIR): that folder is the one that becomes unusable, the write fails
    printf 'block\n' >"$BATS_TEST_TMPDIR/repo/block"
    export DEVZONE_ETAT="$BATS_TEST_TMPDIR/repo/block/.devzone.modules"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    run bash "$BATS_TEST_TMPDIR/repo/.devcontainer/ports.sh" open 8080
    [[ "$output" == *"devzone : port : state not saved"* ]] || false
    [ "$status" -eq 1 ]
}
