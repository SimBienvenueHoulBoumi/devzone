#!/usr/bin/env bats
# manage/scripts/ci-dns.sh (#468) : DNS publics pour le Docker des runners.
# Tout est isolé sous $BATS_TEST_TMPDIR : faux sudo, systemctl et docker,
# daemon.json de test ; jamais le vrai Docker ni /etc/docker.

load commun

setup() {
    relais_docker_isole
    kube_isole
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/ci-dns.sh"
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    for outil in sudo systemctl docker; do
        cat >"$BATS_TEST_TMPDIR/bin/$outil" <<'FAUX'
#!/usr/bin/env bash
echo "$(basename "$0") $*" >>"$BATS_TEST_TMPDIR/appels.log"
[ "$(basename "$0")" = sudo ] && exec "$@"
exit 0
FAUX
        chmod +x "$BATS_TEST_TMPDIR/bin/$outil"
    done
    PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    export PATH
    export DEVZONE_CI_DOCKER_DAEMON="$BATS_TEST_TMPDIR/etc/docker/daemon.json"
}

@test "ci-dns : refuse hors CI, sans rien écrire ni redémarrer" {
    run env -u CI -u GITHUB_ACTIONS bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [ ! -e "$DEVZONE_CI_DOCKER_DAEMON" ] || false
    [ ! -e "$BATS_TEST_TMPDIR/appels.log" ] || false
}

@test "ci-dns : refuse si GITHUB_ACTIONS n'est pas true" {
    run env -u GITHUB_ACTIONS CI=true bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [ ! -e "$DEVZONE_CI_DOCKER_DAEMON" ] || false
}

@test "ci-dns : garde les clés de daemon.json et ajoute dns, puis redémarre docker" {
    mkdir -p "$(dirname "$DEVZONE_CI_DOCKER_DAEMON")"
    echo '{"log-driver":"json-file","dns":["10.0.0.1"]}' >"$DEVZONE_CI_DOCKER_DAEMON"
    run env CI=true GITHUB_ACTIONS=true bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(jq -c '."log-driver"' "$DEVZONE_CI_DOCKER_DAEMON")" = '"json-file"' ]
    [ "$(jq -c .dns "$DEVZONE_CI_DOCKER_DAEMON")" = '["1.1.1.1","8.8.8.8"]' ]
    grep -q "systemctl restart docker" "$BATS_TEST_TMPDIR/appels.log"
    grep -q "docker info" "$BATS_TEST_TMPDIR/appels.log"
}

@test "ci-dns : crée daemon.json s'il n'existe pas" {
    run env CI=true GITHUB_ACTIONS=true bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(jq -c . "$DEVZONE_CI_DOCKER_DAEMON")" = '{"dns":["1.1.1.1","8.8.8.8"]}' ]
}
