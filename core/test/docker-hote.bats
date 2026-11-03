#!/usr/bin/env bats
# Tests de désinstallation filtrée par instance (doublures docker/kind).

setup() {
    export BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-/tmp/bats}"
    mkdir -p "$BATS_TEST_TMPDIR/bin"
}

@test "docker-hote : placeholder" {
    true
}
