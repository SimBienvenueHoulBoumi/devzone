#!/usr/bin/env bash
# Tests du conteneur exigés pour merger (workflow fonctionnel.yml) :
#   bash manage/test/ci-container.sh a-tester < fichiers-changés
#       « true » si la PR touche le conteneur, les tests, la CLI,
#       .gitattributes ou package.json (fonctionnel, cli, windows et ia-arm64 tournent),
#       « false » sinon (une PR de docs seule n'attend pas 25 min)
#   bash manage/test/ci-container.sh synthese <tester> <changements> <fonctionnel> <cli> <windows> <ia-arm64> <bats>
#       vérification tests-conteneur (exigée pour merger) : code 0 si les
#       tests bats ont réussi et si rien d'autre n'était à tester, ou si les
#       quatre jobs du conteneur ont réussi ; 1 sinon (échec, annulation, job
#       sauté alors qu'il devait tourner)
#   bash manage/test/ci-container.sh diagnostic <repo> <run_id>
#       pour chaque job bats annulé : « never started » si aucun runner ni
#       étape (relance conseillée), « cancelled while running » si des étapes
#       ont tourné (#636) ; le verdict de synthese ne change pas ; code 0 toujours
#   bash manage/test/ci-container.sh relancer <repo> <run_id> <tentative>
#       relance automatique, une seule fois (#656) : « gh run rerun --failed »
#       seulement à la première tentative, quand au moins un job est « jamais
#       démarré » (annulé, sans runner ni étape) et qu'aucun autre job (hors
#       tests-conteneur) n'a échoué, expiré ou été annulé en cours d'exécution ;
#       un vrai échec n'est jamais masqué ; code 0 toujours
# Arguments de synthese : sortie tester du job changements, puis résultat
# (needs.<job>.result) de changements, fonctionnel, cli, windows, ia-arm64
# (assistants IA installés sur arm64, Mac Apple Silicon, #194) et bats
# (bats manage/test/, ubuntu et macOS, lancé sur chaque PR, #192).
# Compatible bash 3.2 (macOS).
set -euo pipefail

# Chemins qui lancent les tests du conteneur : mêmes que l'ancien filtre paths
CHEMINS='^(\.devcontainer/|manage/(devzone|scripts|test)|Makefile$|\.gitattributes$|package\.json$|\.github/workflows/fonctionnel\.yml$)'

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
    elif [ "$2" = cancelled ]; then
        # A job past its timeout also ends as cancelled (#522)
        echo "✖ $1 : cancelled (timeout or cancelled run: see the job duration)"
        return 1
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

# Diagnostic des jobs bats annulés (#636) : affiche une ligne par job bats
# annulé qui n'a jamais eu de runner (aucune étape), ou qui a été annulé
# pendant son exécution. N'influe pas sur le verdict de synthese. Sort toujours
# avec 0 : si gh échoue ou est absent, rien n'est affiché. Le TSV est lu par
# awk et non par read : IFS traite la tabulation comme un blanc, et une
# colonne vide (runner_name) serait alors décalée
diagnostic() {
    local repo="$1" run_id="$2" lignes
    lignes="$(gh api "repos/$repo/actions/runs/$run_id/jobs" --jq '.jobs[] | select(.name | startswith("bats")) | [.name, .conclusion, (.runner_name // ""), (.steps | length)] | @tsv' 2>/dev/null)" || return 0
    printf '%s\n' "$lignes" | awk -F '\t' -v run="$run_id" '
        $2 == "cancelled" && $3 == "" && $4 + 0 == 0 {
            print "✖ " $1 " : never started, no GitHub runner was available ; rerun with : gh run rerun " run " --failed"
            next
        }
        $2 == "cancelled" && $4 + 0 > 0 {
            print "✖ " $1 " : cancelled while running (a newer run on the same ref ?)"
        }
    ' || true
    return 0
}

# Relance automatique des jobs jamais démarrés (#656), appelée par le workflow
# relance-ci.yml quand le run fonctionnel est terminé en échec. Une seule
# relance : seulement à la tentative 1. tests-conteneur (le résumé) est ignoré :
# il échoue justement à cause du job jamais démarré. Sort toujours avec 0.
relancer() {
    local repo="$1" run_id="$2" tentative="$3" lignes verdict
    if [ "$tentative" != 1 ]; then
        echo "relance : tentative $tentative, une seule relance automatique : rien à faire"
        return 0
    fi
    lignes="$(gh api "repos/$repo/actions/runs/$run_id/jobs" --jq '.jobs[] | [.name, .conclusion, (.runner_name // ""), (.steps | length)] | @tsv' 2>/dev/null)" || {
        echo "relance : jobs illisibles, aucune relance"
        return 0
    }
    verdict="$(printf '%s\n' "$lignes" | awk -F '\t' '
        $1 == "tests-conteneur" { next }
        $2 == "cancelled" && $3 == "" && $4 + 0 == 0 { jamais++; next }
        $2 == "failure" || $2 == "cancelled" || $2 == "timed_out" { autre++ }
        END {
            if (jamais > 0 && autre == 0) print "relancer"
            else if (jamais > 0) print "echec-reel"
            else print "rien"
        }
    ')" || verdict=rien
    case "$verdict" in
        relancer)
            echo "relance : job jamais démarré (aucun runner, aucune étape) : gh run rerun $run_id --failed"
            gh run rerun "$run_id" --failed || echo "relance : gh run rerun a échoué, rien de plus à faire"
            ;;
        echec-reel) echo "relance : un job n'a pas démarré, mais un autre a échoué ou été annulé en cours : pas de relance automatique" ;;
        *) echo "relance : aucun job jamais démarré : rien à relancer" ;;
    esac
    return 0
}

usage() {
    echo "usage : bash manage/test/ci-container.sh a-tester < fichiers | synthese <tester> <changements> <fonctionnel> <cli> <windows> <ia-arm64> <bats> | diagnostic <repo> <run_id> | relancer <repo> <run_id> <tentative>" >&2
    exit 2
}

case "${1:-}" in
    a-tester) a_tester ;;
    synthese)
        [ "$#" -eq 8 ] || usage
        shift
        synthese "$@"
        ;;
    diagnostic)
        # Toujours code 0 (#636) : un échec ici interromprait la synthèse qui suit
        [ "$#" -eq 3 ] || { echo "usage : bash manage/test/ci-container.sh diagnostic <repo> <run_id>" >&2; exit 0; }
        diagnostic "$2" "$3"
        ;;
    relancer)
        # Toujours code 0, comme diagnostic : jamais un second échec par-dessus le premier
        [ "$#" -eq 4 ] || { echo "usage : bash manage/test/ci-container.sh relancer <repo> <run_id> <tentative>" >&2; exit 0; }
        relancer "$2" "$3" "$4"
        ;;
    *) usage ;;
esac
