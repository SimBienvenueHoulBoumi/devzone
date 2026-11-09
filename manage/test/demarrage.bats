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
