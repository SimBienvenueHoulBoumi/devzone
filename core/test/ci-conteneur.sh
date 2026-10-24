#!/usr/bin/env bash
# Tests du conteneur exigés pour merger (workflow fonctionnel.yml) :
#   bash core/test/ci-conteneur.sh a-tester < fichiers-changés
#       « true » si la PR touche le conteneur, les tests, la CLI,
#       .gitattributes ou package.json (fonctionnel, cli et windows tournent),
#       « false » sinon (une PR de docs seule n'attend pas 25 min)
#   bash core/test/ci-conteneur.sh synthese <tester> <changements> <fonctionnel> <cli> <windows>
#       vérification tests-conteneur (exigée pour merger) : code 0 si rien
#       n'était à tester, ou si les trois jobs ont réussi ; 1 sinon (échec,
#       annulation, job sauté alors qu'il devait tourner)
# Arguments de synthese : sortie tester du job changements, puis résultat
# (needs.<job>.result) de changements, fonctionnel, cli et windows.
# Compatible bash 3.2 (macOS).
set -euo pipefail

# Chemins qui lancent les tests du conteneur : mêmes que l'ancien filtre paths
CHEMINS='^(\.devcontainer/|core/|Makefile$|\.gitattributes$|package\.json$|\.github/workflows/fonctionnel\.yml$)'

# Lit les fichiers changés sur l'entrée : true si l'un d'eux touche un chemin
# suivi, false sinon
a_tester() {
    if grep -qE "$CHEMINS"; then echo true; else echo false; fi
}

# Résultat de la synthèse à partir des résultats des jobs ; chaque problème
# est nommé, pour qu'un échec se lise sans ouvrir les autres jobs
synthese() {
    local tester="$1" changements="$2" ko=0 paire job resultat
    if [ "$changements" != success ]; then
        echo "✖ changements : $changements (détection des fichiers changés)"
        return 1
    fi
    if [ "$tester" != true ]; then
        echo "✔ rien à tester : la PR ne touche ni le conteneur, ni les tests, ni la CLI"
        return 0
    fi
    for paire in "fonctionnel=$3" "cli=$4" "windows=$5"; do
        job="${paire%%=*}"
        resultat="${paire#*=}"
        if [ "$resultat" = success ]; then
            echo "✔ $job : success"
        else
            echo "✖ $job : $resultat"
            ko=1
        fi
    done
    return "$ko"
}

usage() {
    echo "usage : bash core/test/ci-conteneur.sh a-tester < fichiers | synthese <tester> <changements> <fonctionnel> <cli> <windows>" >&2
    exit 2
}

case "${1:-}" in
    a-tester) a_tester ;;
    synthese)
        [ "$#" -eq 6 ] || usage
        shift
        synthese "$@"
        ;;
    *) usage ;;
esac
