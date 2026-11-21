#!/usr/bin/env bats
# Startup (#429): each script run by .devcontainer/startup.sh exists
# under .devcontainer/. The script is only read, never executed.

setup() {
    load commun
    kube_isole
    ICI="$(cd "$BATS_TEST_DIRNAME/../../.devcontainer" && pwd)"
    DEMARRAGE="$ICI/startup.sh"
}

@test "startup : each path \$ICI/….sh exists under .devcontainer" {
    [ -f "$DEMARRAGE" ] || false
    trouves=0
    manquants=""
    while IFS= read -r chemin; do
        [ -n "$chemin" ] || continue
        trouves=$((trouves + 1))
        chemin="${chemin#\"}"
        chemin="${chemin%\"}"
        chemin="${chemin#\$ICI/}"
        [ -f "$ICI/$chemin" ] || manquants="${manquants}${manquants:+, }$chemin"
    done <<<"$(grep -oE '"\$ICI/[^"]+\.sh"' "$DEMARRAGE" || true)"
    [ "$trouves" -gt 0 ] || {
        echo "no path \$ICI/….sh found in startup.sh"
        false
    }
    [ -z "$manquants" ] || {
        echo "scripts missing under .devcontainer: $manquants"
        false
    }
}

@test "startup : no deprecated line on stdout nor stderr (#532)" {
    # Fake environment: no real docker, kubectl, gh nor socat; the state
    # and the HOME stay under $BATS_TEST_TMPDIR. Each failing step passes
    # to the next one (startup.sh), the summary ends.
    bats_require_minimum_version 1.5.0
    mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/racine/workspace" \
        "$BATS_TEST_TMPDIR/ports-auto" "$BATS_TEST_TMPDIR/home"
    for outil in docker kubectl gh socat; do
        printf '#!/usr/bin/env bash\nexit 1\n' >"$BATS_TEST_TMPDIR/bin/$outil"
        chmod +x "$BATS_TEST_TMPDIR/bin/$outil"
    done
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    export DEVZONE_ROOT="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_STATE="$BATS_TEST_TMPDIR/racine/.devzone.modules"
    export DEVZONE_PORTS_AUTO_DIR="$BATS_TEST_TMPDIR/ports-auto"
    export HOME="$BATS_TEST_TMPDIR/home"
    export GIT_CONFIG_NOSYSTEM=1
    run --separate-stderr bash "$DEMARRAGE"
    [ "$status" -eq 0 ]
    [[ "$output" != *"deprecated"* ]] || false
    [[ "$stderr" != *"deprecated"* ]] || false
}

@test "startup : Kubernetes workspace, no auto ports watcher (#517)" {
    # Same fake environment as the previous test. Under bats the watcher
    # refuses (code 2): the « not started » message only shows outside Kubernetes.
    mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/racine/workspace" \
        "$BATS_TEST_TMPDIR/ports-auto" "$BATS_TEST_TMPDIR/home"
    for outil in docker kubectl gh socat; do
        printf '#!/usr/bin/env bash\nexit 1\n' >"$BATS_TEST_TMPDIR/bin/$outil"
        chmod +x "$BATS_TEST_TMPDIR/bin/$outil"
    done
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    export DEVZONE_ROOT="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_STATE="$BATS_TEST_TMPDIR/racine/.devzone.modules"
    export DEVZONE_PORTS_AUTO_DIR="$BATS_TEST_TMPDIR/ports-auto"
    export HOME="$BATS_TEST_TMPDIR/home"
    export GIT_CONFIG_NOSYSTEM=1
    DEVZONE_WORKSPACE=kubernetes run bash "$DEMARRAGE"
    [ "$status" -eq 0 ]
    [[ "$output" != *"auto ports watcher not started"* ]] || false
    run bash "$DEMARRAGE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"auto ports watcher not started"* ]] || false
}
