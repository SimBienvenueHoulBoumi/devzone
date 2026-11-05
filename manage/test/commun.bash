#!/usr/bin/env bash
# Aide commune des tests du relais Docker (#346) : isolation du relais sous
# $BATS_TEST_TMPDIR, jamais sur le vrai socket ni ses fichiers.

relais_docker_isole() {
    export DEVZONE_RELAIS_SOCKET="$BATS_TEST_TMPDIR/docker.sock"
    export DEVZONE_RELAIS_SOURCE="$BATS_TEST_TMPDIR/docker-host.sock"
    export DEVZONE_RELAIS_PID="$BATS_TEST_TMPDIR/socat.pid"
    export DEVZONE_RELAIS_LOG="$BATS_TEST_TMPDIR/socat.log"
    export DEVZONE_RELAIS_MARQUE="$BATS_TEST_TMPDIR/relais.echec"
    export DEVZONE_RELAIS_SUDO=""
}
