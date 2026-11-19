#!/usr/bin/env bats
# Automatic rerun of the jobs that never started (#656):
# ci-conteneur.sh relancer. A fake gh on the PATH answers the jobs of the run
# and logs every call; the rerun is only requested for a job that never
# started, on the first attempt, and when no other job really failed.

setup() {
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$RACINE/manage/test/ci-conteneur.sh"
    WORKFLOW="$RACINE/.github/workflows/relance-ci.yml"
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat >"$BATS_TEST_TMPDIR/bin/gh" <<'FAUX'
#!/usr/bin/env bash
echo "gh $*" >>"$FAUX_GH_LOG"
case "$1" in
    api)
        [ -z "${FAUX_GH_ECHEC:-}" ] || { echo "gh: HTTP 403" >&2; exit 1; }
        cat "$FAUX_GH_JOBS"
        ;;
    run) [ "${FAUX_GH_RERUN_ECHEC:-}" != 1 ] ;;
esac
FAUX
    chmod +x "$BATS_TEST_TMPDIR/bin/gh"
    export FAUX_GH_LOG="$BATS_TEST_TMPDIR/gh.log"
    export FAUX_GH_JOBS="$BATS_TEST_TMPDIR/jobs.tsv"
    : >"$FAUX_GH_LOG"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# Fixture: one TSV line per job (name, conclusion, runner, steps)
jobs_tsv() {
    printf '%s\n' "$@" >"$FAUX_GH_JOBS"
}

@test "relancer: job never started on attempt 1 -> rerun --failed requested" {
    jobs_tsv $'bats (macos-latest)\tcancelled\t\t0' $'tests-conteneur\tfailure\tGitHub Actions 2\t5' $'cli\tsuccess\tGitHub Actions 1\t9'
    run bash "$SCRIPT" relancer octo/repo 4242 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"jamais démarré"* ]] || false
    grep -q "^gh run rerun 4242 --failed$" "$FAUX_GH_LOG"
}

@test "relancer: a real test failure -> no rerun" {
    jobs_tsv $'bats (ubuntu-latest 1/4)\tfailure\tGitHub Actions 1\t9' $'tests-conteneur\tfailure\tGitHub Actions 2\t5'
    run bash "$SCRIPT" relancer octo/repo 4242 1
    [ "$status" -eq 0 ]
    ! grep -q "^gh run rerun" "$FAUX_GH_LOG" || false
}

@test "relancer: never started AND another job failed -> no rerun, the failure is not hidden" {
    jobs_tsv $'bats (macos-latest)\tcancelled\t\t0' $'fonctionnel\tfailure\tGitHub Actions 1\t12' $'tests-conteneur\tfailure\tGitHub Actions 2\t5'
    run bash "$SCRIPT" relancer octo/repo 4242 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"pas de relance automatique"* ]] || false
    ! grep -q "^gh run rerun" "$FAUX_GH_LOG" || false
}

@test "relancer: attempt 2 or more -> no rerun, even for a job never started (no loop)" {
    jobs_tsv $'bats (macos-latest)\tcancelled\t\t0'
    run bash "$SCRIPT" relancer octo/repo 4242 2
    [ "$status" -eq 0 ]
    [[ "$output" == *"une seule relance"* ]] || false
    [ ! -s "$FAUX_GH_LOG" ]
}

@test "relancer: job cancelled while running (runner and steps) -> no rerun" {
    jobs_tsv $'bats (macos-latest)\tcancelled\tGitHub Actions 3\t4' $'tests-conteneur\tfailure\tGitHub Actions 2\t5'
    run bash "$SCRIPT" relancer octo/repo 4242 1
    [ "$status" -eq 0 ]
    ! grep -q "^gh run rerun" "$FAUX_GH_LOG" || false
}

@test "relancer: gh cannot read the jobs -> message, code 0, no rerun" {
    jobs_tsv $'bats (macos-latest)\tcancelled\t\t0'
    export FAUX_GH_ECHEC=1
    run bash "$SCRIPT" relancer octo/repo 4242 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"aucune relance"* ]] || false
    ! grep -q "^gh run rerun" "$FAUX_GH_LOG" || false
}

@test "relancer: the rerun itself fails -> message, code 0" {
    jobs_tsv $'bats (macos-latest)\tcancelled\t\t0'
    export FAUX_GH_RERUN_ECHEC=1
    run bash "$SCRIPT" relancer octo/repo 4242 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"gh run rerun a échoué"* ]] || false
}

@test "relancer: wrong number of arguments -> usage, code 0" {
    run bash "$SCRIPT" relancer octo/repo
    [ "$status" -eq 0 ]
    [[ "$output" == *"usage"* ]] || false
}

@test "workflow relance-ci: only on failure and first attempt, minimal permissions, no code of the PR" {
    grep -q "workflows: \[fonctionnel\]" "$WORKFLOW"
    grep -q "run_attempt == 1" "$WORKFLOW"
    grep -q "conclusion == 'failure'" "$WORKFLOW"
    grep -q "actions: write" "$WORKFLOW"
    grep -q "^permissions: {}" "$WORKFLOW"
    # never checks out the head of the pull request
    ! grep -qE "head_sha|head_branch|pull_requests|ref:" "$WORKFLOW" || false
}
