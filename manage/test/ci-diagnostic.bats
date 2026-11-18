#!/usr/bin/env bats
# Diagnostic of the bats jobs cancelled before they ran (#636):
# ci-conteneur.sh diagnostic prints one line per cancelled bats job. A fake gh
# on the PATH answers the jobs of the run. The verdict of synthese does not
# change: a cancelled bats job still fails.

setup() {
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$RACINE/manage/test/ci-conteneur.sh"
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    # The fake gh logs its arguments, then prints the fixture (already filtered
    # by jq in the real command), or fails when FAUX_GH_ECHEC is set
    cat > "$BATS_TEST_TMPDIR/bin/gh" <<'FAUX'
#!/usr/bin/env bash
echo "gh $*" >>"$FAUX_GH_LOG"
if [ -n "${FAUX_GH_ECHEC:-}" ]; then
    echo "gh: HTTP 403" >&2
    exit 1
fi
cat "$FAUX_GH_JOBS"
FAUX
    chmod +x "$BATS_TEST_TMPDIR/bin/gh"
    export FAUX_GH_LOG="$BATS_TEST_TMPDIR/gh.log"
    export FAUX_GH_JOBS="$BATS_TEST_TMPDIR/jobs.tsv"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# Writes the fixture: one TSV line per job (name, conclusion, runner, steps)
jobs_tsv() {
    printf '%s\n' "$@" >"$FAUX_GH_JOBS"
}

@test "diagnostic : never started (cancelled, no runner, no step) → message with the rerun command" {
    jobs_tsv $'bats (macos-latest)\tcancelled\t\t0'
    run bash "$SCRIPT" diagnostic octo/repo 4242
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [ "$output" = "✖ bats (macos-latest) : never started, no GitHub runner was available ; rerun with : gh run rerun 4242 --failed" ]
    grep -q "^gh api repos/octo/repo/actions/runs/4242/jobs" "$FAUX_GH_LOG"
}

@test "diagnostic : cancelled while running (runner and steps) → cancelled while running" {
    jobs_tsv $'bats (macos-latest)\tcancelled\tGitHub Actions 3\t4'
    run bash "$SCRIPT" diagnostic octo/repo 4242
    [ "$status" -eq 0 ]
    [ "$output" = "✖ bats (macos-latest) : cancelled while running (a newer run on the same ref ?)" ]
}

@test "diagnostic : all bats jobs succeeded → no output, code 0" {
    jobs_tsv $'bats (ubuntu-latest 1/4)\tsuccess\tGitHub Actions 1\t9' \
        $'bats (macos-latest)\tsuccess\tGitHub Actions 2\t7'
    run bash "$SCRIPT" diagnostic octo/repo 4242
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "diagnostic : gh fails → no output, code 0" {
    jobs_tsv $'bats (macos-latest)\tcancelled\t\t0'
    export FAUX_GH_ECHEC=1
    run bash "$SCRIPT" diagnostic octo/repo 4242
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "diagnostic : gh absent from the PATH → no output, code 0" {
    mkdir -p "$BATS_TEST_TMPDIR/vide"
    for c in bash awk; do
        ln -sf "$(command -v "$c")" "$BATS_TEST_TMPDIR/vide/$c"
    done
    # Only the script sees this PATH (no gh, no rm for bats itself)
    run env PATH="$BATS_TEST_TMPDIR/vide" bash "$SCRIPT" diagnostic octo/repo 4242
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "diagnostic : ubuntu succeeded, macOS never started → one message, for macOS only" {
    jobs_tsv $'bats (ubuntu-latest 1/4)\tsuccess\tGitHub Actions 1\t9' \
        $'bats (ubuntu-latest 2/4)\tsuccess\tGitHub Actions 2\t9' \
        $'bats (ubuntu-latest 3/4)\tsuccess\tGitHub Actions 3\t9' \
        $'bats (ubuntu-latest 4/4)\tsuccess\tGitHub Actions 4\t9' \
        $'bats (macos-latest)\tcancelled\t\t0'
    run bash "$SCRIPT" diagnostic octo/repo 4242
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [[ "$output" == *"✖ bats (macos-latest) : never started"* ]] || false
    [[ "$output" == *"gh run rerun 4242 --failed"* ]] || false
}

@test "diagnostic : missing arguments → usage on the output, code 0 (the summary still runs)" {
    run bash "$SCRIPT" diagnostic octo/repo
    [ "$status" -eq 0 ]
    [[ "$output" == *"diagnostic <repo> <run_id>"* ]] || false
}

@test "synthese : bats cancelled still fails, with or without container tests (verdict unchanged)" {
    run bash "$SCRIPT" synthese false success skipped skipped skipped skipped cancelled
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ bats : cancelled"* ]] || false
    run bash "$SCRIPT" synthese true success success success success success cancelled
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ bats : cancelled"* ]] || false
}
