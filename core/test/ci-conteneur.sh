#!/usr/bin/env bash
# Tests du conteneur exigés pour merger (workflow fonctionnel.yml) :
#   bash core/test/ci-conteneur.sh a-tester < fichiers-changés
#       « true » si la PR touche le conteneur, les tests, la CLI,
#       .gitattributes ou package.json (fonctionnel, cli, windows et ia-arm64 tournent),
#       « false » sinon (une PR de docs seule n'attend pas 25 min)
#   bash core/test/ci-conteneur.sh synthese <tester> <changements> <fonctionnel> <cli> <windows> <ia-arm64> <bats>
#       vérification tests-conteneur (exigée pour merger) : code 0 si les
#       tests bats ont réussi et si rien d'autre n'était à tester, ou si les
#       quatre jobs du conteneur ont réussi ; 1 sinon (échec, annulation, job
#       sauté alors qu'il devait tourner)
# Arguments de synthese : sortie tester du job changements, puis résultat
# (needs.<job>.result) de changements, fonctionnel, cli, windows, ia-arm64
# (assistants IA installés sur arm64, Mac Apple Silicon, #194) et bats
# (bats core/test/, ubuntu et macOS, lancé sur chaque PR, #192).
# Compatible bash 3.2 (macOS).
set -euo pipefail

# Chemins qui lancent les tests du conteneur : mêmes que l'ancien filtre paths
CHEMINS='^(\.devcontainer/|core/|Makefile$|\.gitattributes$|package\.json$|\.github/workflows/fonctionnel\.yml$)'

# Lit les fichiers changés sur l'entrée : true si l'un d'eux touche un chemin
# suivi, false sinon
a_tester() {
    if grep -qE "$CHEMINS"; then echo true; else echo false; fi
}

# Affiche le résultat d'un job (✔ ou ✖, avec son nom) ; code 1 s'il n'a pas
# réussi, pour qu'un échec se lise sans ouvrir les autres jobs
job_reussi() {
    if [ "$2" = success ]; then
        echo "✔ $1 : success"
    else
        echo "✖ $1 : $2"
        return 1
    fi
}

# Résultat de la synthèse à partir des résultats des jobs : bats compte
# toujours (lancé sur chaque PR), les quatre jobs du conteneur seulement
# quand la PR les concerne
synthese() {
    local tester="$1" changements="$2" ko=0 paire
    if [ "$changements" != success ]; then
        echo "✖ changements : $changements (détection des fichiers changés)"
        return 1
    fi
    job_reussi bats "$7" || ko=1
    if [ "$tester" != true ]; then
        echo "✔ rien à tester : la PR ne touche ni le conteneur, ni les tests, ni la CLI"
        return "$ko"
    fi
    for paire in "fonctionnel=$3" "cli=$4" "windows=$5" "ia-arm64=$6"; do
        job_reussi "${paire%%=*}" "${paire#*=}" || ko=1
    done
    return "$ko"
}

usage() {
    echo "usage : bash core/test/ci-conteneur.sh a-tester < fichiers | synthese <tester> <changements> <fonctionnel> <cli> <windows> <ia-arm64> <bats>" >&2
    exit 2
}

case "${1:-}" in
    a-tester) a_tester ;;
    synthese)
        [ "$#" -eq 8 ] || usage
        shift
        synthese "$@"
        ;;
    *) usage ;;
esac
