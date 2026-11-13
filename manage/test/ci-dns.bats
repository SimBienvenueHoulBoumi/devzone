#!/usr/bin/env bats
# manage/scripts/ci-dns.sh (#468): public DNS for runner Docker.
# Everything isolated under $BATS_TEST_TMPDIR: fake sudo, systemctl and docker,
# test daemon.json; never real Docker or /etc/docker.

load commun

setup() {
    relais_docker_isole
    kube_isole
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/ci-dns.sh"
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    for tool in sudo systemctl docker; do
        cat >"$BATS_TEST_TMPDIR/bin/$tool" <<'FAKE'
#!/usr/bin/env bash
echo "$(basename "$0") $*" >>"$BATS_TEST_TMPDIR/calls.log"
[ "$(basename "$0")" = sudo ] && exec "$@"
exit 0
FAKE
        chmod +x "$BATS_TEST_TMPDIR/bin/$tool"
    done
    PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    export PATH
    export DEVZONE_CI_DOCKER_DAEMON="$BATS_TEST_TMPDIR/etc/docker/daemon.json"
}

@test "ci-dns: refuses outside CI, writes nothing and restarts nothing" {
    run env -u CI -u GITHUB_ACTIONS bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [ ! -e "$DEVZONE_CI_DOCKER_DAEMON" ] || false
    [ ! -e "$BATS_TEST_TMPDIR/calls.log" ] || false
}

@test "ci-dns: refuses if GITHUB_ACTIONS is not true" {
    run env -u GITHUB_ACTIONS CI=true bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [ ! -e "$DEVZONE_CI_DOCKER_DAEMON" ] || false
}

@test "ci-dns: keeps daemon.json keys, adds dns, then restarts docker" {
    mkdir -p "$(dirname "$DEVZONE_CI_DOCKER_DAEMON")"
    echo '{"log-driver":"json-file","dns":["10.0.0.1"]}' >"$DEVZONE_CI_DOCKER_DAEMON"
    run env CI=true GITHUB_ACTIONS=true bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(jq -c '."log-driver"' "$DEVZONE_CI_DOCKER_DAEMON")" = '"json-file"' ]
    [ "$(jq -c .dns "$DEVZONE_CI_DOCKER_DAEMON")" = '["1.1.1.1","8.8.8.8"]' ]
    grep -q "systemctl restart docker" "$BATS_TEST_TMPDIR/calls.log"
    grep -q "docker info" "$BATS_TEST_TMPDIR/calls.log"
}

@test "ci-dns: creates daemon.json if missing" {
    run env CI=true GITHUB_ACTIONS=true bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(jq -c . "$DEVZONE_CI_DOCKER_DAEMON")" = '{"dns":["1.1.1.1","8.8.8.8"]}' ]
}
