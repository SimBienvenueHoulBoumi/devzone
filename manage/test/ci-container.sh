#!/usr/bin/env bash
# CI tests required to merge (fonctionnel.yml workflow):
#   bash manage/test/ci-container.sh a-tester < changed-files
#       "true" if the PR touches the pod, the tests, the CLI,
#       .gitattributes or package.json (fonctionnel, cli, windows and ia-arm64 run),
#       "false" otherwise (a docs-only PR does not wait 25 min)
#   bash manage/test/ci-container.sh synthese <tester> <changements> <fonctionnel> <cli> <windows> <ia-arm64> <bats>
#       tests-conteneur check (required to merge): exit 0 if the
#       bats tests passed and nothing else had to be tested, or if the
#       four CI jobs passed; 1 otherwise (failure, cancellation, job
#       skipped while it had to run)
#   bash manage/test/ci-container.sh diagnostic <repo> <run_id>
#       for each cancelled bats job: "never started" if no runner nor
#       step (rerun advised), "cancelled while running" if some steps
#       ran (#636); the summary verdict does not change; always exit 0
#   bash manage/test/ci-container.sh relancer <repo> <run_id> <tentative>
#       automatic rerun, once only (#656): "gh run rerun --failed"
#       only at the first attempt, when at least one job is "never
#       started" (cancelled, no runner nor step) and no other job (except
#       tests-conteneur) failed, expired or was cancelled during its run;
#       a real failure is never hidden; always exit 0
# Summary arguments: the tester output of the changes job, then the result
# (needs.<job>.result) of changements, fonctionnel, cli, windows, ia-arm64
# (AI assistants installed on arm64, Apple Silicon Mac, #194) and bats
# (bats manage/test/, ubuntu and macOS, run on each PR, #192).
# Compatible bash 3.2 (macOS).
set -euo pipefail

# Paths that trigger the CI tests: same as the former paths filter
# (+ Go code of the distributed binary, #856: cmd/, internal/, go.mod, go.sum)
CHEMINS='^(\.devcontainer/|manage/(devzone|scripts|test)|Makefile$|\.gitattributes$|package\.json$|\.github/workflows/fonctionnel\.yml$|cmd/|internal/|go\.(mod|sum)$)'

# Reads the changed files on stdin: true if one of them touches a tracked
# path, false otherwise
a_tester() {
    if grep -qE "$CHEMINS"; then echo true; else echo false; fi
}

# Prints the result of a job (✔ or ✖, with its name); exit 1 if it did not
# succeed, so a failure can be read without opening the other jobs
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

# Result of the summary from the job results: bats always
# counts (run on each PR), the four CI jobs only
# when the PR concerns them
synthese() {
    local tester="$1" changements="$2" ko=0 paire
    if [ "$changements" != success ]; then
        echo "✖ changes: $changements (changed file detection)"
        return 1
    fi
    job_reussi bats "$7" || ko=1
    if [ "$tester" != true ]; then
        echo "✔ nothing to test: the PR touches neither the pod, the tests nor the CLI"
        return "$ko"
    fi
    for paire in "fonctionnel=$3" "cli=$4" "windows=$5" "ia-arm64=$6"; do
        job_reussi "${paire%%=*}" "${paire#*=}" || ko=1
    done
    return "$ko"
}

# Diagnosis of cancelled bats jobs (#636): prints one line per bats job
# cancelled that never had a runner (no step), or that was cancelled
# during its run. Does not change the summary verdict. Always exits
# 0: if gh fails or is absent, nothing is printed. The TSV is read by
# awk and not by read: IFS treats the tabulation as a blank, and an
# empty column (runner_name) would then be shifted
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

# Automatic rerun of jobs that never started (#656), called by the
# relance-ci.yml workflow when the functional run ends in failure. One
# rerun only: at attempt 1. tests-conteneur (the summary) is ignored:
# it fails precisely because of the job that never started. Always exits 0.
relancer() {
    local repo="$1" run_id="$2" tentative="$3" lignes verdict
    if [ "$tentative" != 1 ]; then
        echo "rerun: attempt $tentative, a single rerun is allowed: nothing to do"
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
            else if (jamais > 0) print "failed-real"
            else print "rien"
        }
    ')" || verdict=rien
    case "$verdict" in
        relancer)
            echo "rerun: job never started (no runner, no step): gh run rerun $run_id --failed"
            gh run rerun "$run_id" --failed || echo "rerun: gh run rerun failed, nothing more to do"
            ;;
        failed-real) echo "rerun: one job did not start, but another failed or was cancelled during its run: no automatic rerun" ;;
        *) echo "rerun: no job never started: nothing to rerun" ;;
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
        # Always exit 0 (#636): a failure here would interrupt the summary that follows
        [ "$#" -eq 3 ] || { echo "usage : bash manage/test/ci-container.sh diagnostic <repo> <run_id>" >&2; exit 0; }
        diagnostic "$2" "$3"
        ;;
    relancer)
        # Always exit 0, as for diagnosis: never a second failure over the first
        [ "$#" -eq 4 ] || { echo "usage : bash manage/test/ci-container.sh relancer <repo> <run_id> <tentative>" >&2; exit 0; }
        relancer "$2" "$3" "$4"
        ;;
    *) usage ;;
esac
