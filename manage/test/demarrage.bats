#!/usr/bin/env bats
# Démarrage (#429) : chaque script lancé par .devcontainer/demarrage.sh existe
# sous .devcontainer/. Le script est seulement lu, jamais exécuté.

setup() {
    load commun
    relais_docker_isole
    kube_isole
    ICI="$(cd "$BATS_TEST_DIRNAME/../../.devcontainer" && pwd)"
    DEMARRAGE="$ICI/demarrage.sh"
}

@test "demarrage : chaque chemin \$ICI/….sh existe sous .devcontainer" {
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
        echo "aucun chemin \$ICI/….sh trouvé dans demarrage.sh"
        false
    }
    [ -z "$manquants" ] || {
        echo "scripts absents sous .devcontainer : $manquants"
        false
    }
}

@test "demarrage : aucune ligne deprecated sur stdout ni stderr (#532)" {
    # Environnement factice : aucun docker, kubectl, gh ni socat réels ; l'état
    # et le HOME restent sous $BATS_TEST_TMPDIR. Chaque étape en échec passe
    # à la suivante (demarrage.sh), le récapitulatif termine.
    bats_require_minimum_version 1.5.0
    mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/racine/workspace" \
        "$BATS_TEST_TMPDIR/ports-auto" "$BATS_TEST_TMPDIR/home"
    for outil in docker kubectl gh socat; do
        printf '#!/usr/bin/env bash\nexit 1\n' >"$BATS_TEST_TMPDIR/bin/$outil"
        chmod +x "$BATS_TEST_TMPDIR/bin/$outil"
    done
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    export DEVZONE_RACINE="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_ETAT="$BATS_TEST_TMPDIR/racine/.devzone.modules"
    export DEVZONE_PORTS_AUTO_DIR="$BATS_TEST_TMPDIR/ports-auto"
    export HOME="$BATS_TEST_TMPDIR/home"
    export GIT_CONFIG_NOSYSTEM=1
    run --separate-stderr bash "$DEMARRAGE"
    [ "$status" -eq 0 ]
    [[ "$output" != *"deprecated"* ]] || false
    [[ "$stderr" != *"deprecated"* ]] || false
}
