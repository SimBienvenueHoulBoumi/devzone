#!/usr/bin/env bats
# Port relay state (#290): list, close and summary of the relays kept in the
# state of devzone. Fake tools in the PATH: no container started.

setup() {
    load commun
    kind_vide
    kube_isole
    PORTS="$BATS_TEST_DIRNAME/../../.devcontainer/ports.sh"
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    export HOME="$BATS_TEST_TMPDIR/home"
    export DEVZONE_ROOT="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_STATE="$BATS_TEST_TMPDIR/etat"
    export DEVZONE_INSTANCE=devzone
    mkdir -p "$HOME" "$DEVZONE_ROOT/workspace" "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/relays"
    : >"$DEVZONE_STATE"
    : >"$BATS_TEST_TMPDIR/docker.log"
    : >"$BATS_TEST_TMPDIR/curl.log"

    cat >"$BATS_TEST_TMPDIR/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
echo "docker $*" >>"$T/docker.log"
case "${1:-}" in
    ps)
        pattern=""; prec=""
        for a in "$@"; do
            [ "$prec" = --filter ] && pattern="$a"
            prec="$a"
        done
        for f in "$T"/relays/*; do
            [ -e "$f" ] || continue
            name="$(basename "$f")"
            m="${pattern#name=}"
            m="${m#^}"
            m="${m%$}"
            [ "$name" = "$m" ] && echo "$name"
        done
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

@test "list: sorted without duplicate, ● active, ○ stopped, application behind" {
    printf 'ports=3000,8080,8080\n' >"$DEVZONE_STATE"
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

@test "list --json: port, activity and application" {
    printf 'ports=8080\n' >"$DEVZONE_STATE"
    : >"$BATS_TEST_TMPDIR/relays/devzone-devzone-port-8080"
    FAKE_REPOND=8080 run bash "$PORTS" list --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | jq -e '.[0] | select(.port == 8080 and .active == true and (.application | startswith("application")))' >/dev/null
}

@test "close: relay removed, port removed from the state, other ports kept" {
    printf 'ports=3000,8080\n' >"$DEVZONE_STATE"
    : >"$BATS_TEST_TMPDIR/relays/devzone-devzone-port-3000"
    : >"$BATS_TEST_TMPDIR/relays/devzone-devzone-port-8080"
    run bash "$PORTS" --close 8080
    [ "$status" -eq 0 ]
    grep -q 'docker rm -f devzone-devzone-port-8080' "$BATS_TEST_TMPDIR/docker.log"
    [ ! -e "$BATS_TEST_TMPDIR/relays/devzone-devzone-port-8080" ]
    grep -qx 'ports=3000' "$DEVZONE_STATE"
    run bash "$PORTS" close 3000
    [ "$status" -eq 0 ]
    grep -qx 'ports=' "$DEVZONE_STATE"
}

@test "close: invalid port refused (code 1)" {
    run bash "$PORTS" --close 70000
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid port"* ]] || false
}

@test "devzone port: list and close through the command routing" {
    printf 'ports=8080\n' >"$DEVZONE_STATE"
    : >"$BATS_TEST_TMPDIR/relays/devzone-devzone-port-8080"

    run bash "$DEVZONE" port
    [ "$status" -eq 0 ]
    [[ "$output" == *"8080"*"● active"* ]] || false

    run bash "$DEVZONE" port --close 8080
    [ "$status" -eq 0 ]
    grep -qx 'ports=' "$DEVZONE_STATE"
}

@test "devzone: ports recap for the workstation, active then none" {
    printf 'ports=8080\n' >"$DEVZONE_STATE"
    : >"$BATS_TEST_TMPDIR/relays/devzone-devzone-port-8080"
    run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"✔ ports to the workstation 8080 ●"* ]] || false

    printf 'ports=\n' >"$DEVZONE_STATE"
    run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"○ ports to the workstation none"* ]] || false
}

@test "devzone --help cites devzone port" {
    run bash "$DEVZONE" --help
    [[ "$output" == *"devzone port [--close <n>]"* ]] || false
}

@test "write_ports: write failure on stderr, code 1" {
    unset DEVZONE_STATE DEVZONE_ROOT
    mkdir -p "$BATS_TEST_TMPDIR/repo"
    cp -r "$BATS_TEST_DIRNAME/../../.devcontainer" "$BATS_TEST_TMPDIR/repo/.devcontainer"
    export TMPDIR="/nonexistent"
    # Since #417 the temporary file is created in the state folder (never in
    # TMPDIR): that folder is the one that becomes unusable, the write fails
    printf 'block\n' >"$BATS_TEST_TMPDIR/repo/block"
    export DEVZONE_STATE="$BATS_TEST_TMPDIR/repo/block/.devzone.modules"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    run bash "$BATS_TEST_TMPDIR/repo/.devcontainer/ports.sh" close 8080
    [[ "$output" == *"devzone : port : state not saved"* ]] || false
    [ "$status" -eq 1 ]
}
