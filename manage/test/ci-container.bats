#!/usr/bin/env bats
# CI tests required to merge: path decision (run or skip fonctionnel, cli,
# windows) and the tests-conteneur summary check
# (manage/test/ci-container.sh, workflow fonctionnel.yml, .repowarden.conf).

setup() {
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$RACINE/manage/test/ci-container.sh"
    WORKFLOW="$RACINE/.github/workflows/fonctionnel.yml"
}

@test "a-tester : documentation seule → false" {
    run bash "$SCRIPT" a-tester <<<$'README.md\nmanage/docs/reference.md\n.github/workflows/release.yml'
    [ "$status" -eq 0 ]
    [ "$output" = false ]
}

@test "a-tester: no file -> false" {
    run bash "$SCRIPT" a-tester </dev/null
    [ "$status" -eq 0 ]
    [ "$output" = false ]
}

@test "a-tester : conteneur, tests, CLI, .gitattributes, package.json, workflow → true" {
    for f in .devcontainer/devzone manage/test/cli.bats manage/devzone Makefile .gitattributes package.json .github/workflows/fonctionnel.yml cmd/devzone/main.go internal/framework/cli/cli.go go.mod go.sum; do
        run bash "$SCRIPT" a-tester <<<$'README.md\n'"$f"
        [ "$status" -eq 0 ]
        [ "$output" = true ] || { echo "not detected: $f"; false; }
    done
}

@test "a-tester : nom proche d'un chemin suivi (manage/docs/Makefile.md, package.json.bak) → false" {
    run bash "$SCRIPT" a-tester <<<$'manage/docs/Makefile.md\npackage.json.bak\nautre/manage/x\nworkspace/projet/internal/x.go\ngo.mod.bak'
    [ "$status" -eq 0 ]
    [ "$output" = false ]
}

@test "synthese: nothing to test (skipped jobs) -> success" {
    run bash "$SCRIPT" synthese false success skipped skipped skipped skipped success
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing to test"* ]] || false
}

@test "synthese: nothing to test but failing bats -> failure with the job name" {
    run bash "$SCRIPT" synthese false success skipped skipped skipped skipped failure
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ bats : failure"* ]] || false
}

@test "synthese: failing bats, everything else passed -> failure" {
    run bash "$SCRIPT" synthese true success success success success success failure
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ bats : failure"* ]] || false
}

@test "synthese: cancelled or skipped bats -> failure" {
    for resultat in cancelled skipped; do
        run bash "$SCRIPT" synthese false success skipped skipped skipped skipped "$resultat"
        [ "$status" -ne 0 ]
        [[ "$output" == *"✖ bats : $resultat"* ]] || false
    done
}

@test "synthese: fonctionnel, cli, windows, ia-arm64 and bats passed -> success" {
    run bash "$SCRIPT" synthese true success success success success success success
    [ "$status" -eq 0 ]
    [[ "$output" == *"✔ ia-arm64 : success"* ]] || false
    [[ "$output" == *"✔ bats : success"* ]] || false
}

@test "synthese: one failed job -> failure with its name" {
    run bash "$SCRIPT" synthese true success success failure success success success
    [ "$status" -ne 0 ]
    [[ "$output" == *"cli"*"failure"* ]] || false
}

@test "synthese: AI assistants not installable on arm64 (ia-arm64 failure) -> failure with its name" {
    run bash "$SCRIPT" synthese true success success success success failure success
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ ia-arm64 : failure"* ]] || false
}

@test "synthese: cancelled or being cancelled job -> failure" {
    run bash "$SCRIPT" synthese true success cancelled success success success success
    [ "$status" -ne 0 ]
    [[ "$output" == *"fonctionnel"*"cancelled"* ]] || false
    # A job past its timeout also ends as cancelled (#522)
    [[ "$output" == *"timeout or cancelled"* ]] || false
}

@test "synthese: job skipped while tests were required -> failure" {
    run bash "$SCRIPT" synthese true success success success skipped success success
    [ "$status" -ne 0 ]
    [[ "$output" == *"windows"*"skipped"* ]] || false
}

@test "synthese: change detection failed -> failure" {
    run bash "$SCRIPT" synthese "" failure skipped skipped skipped skipped success
    [ "$status" -ne 0 ]
    [[ "$output" == *"changes"*"failure"* ]] || false
}

@test "synthese: missing arguments -> usage, failure" {
    run bash "$SCRIPT" synthese true success
    [ "$status" -ne 0 ]
    [[ "$output" == *usage* ]] || false
    run bash "$SCRIPT" synthese true success success success success success
    [ "$status" -ne 0 ]
    [[ "$output" == *usage* ]] || false
}

@test "fonctionnel.yml: ia-arm64 job on ubuntu-24.04-arm, path decision, claude and opencode checked" {
    bloc="$(awk '/^  ia-arm64:/ { inside = 1; print; next } inside && /^  [a-z0-9-]+:/ { exit } inside { print }' "$WORKFLOW")"
    [ -n "$bloc" ]
    [[ "$bloc" == *"runs-on: ubuntu-24.04-arm"* ]] || false
    [[ "$bloc" == *"if: needs.changements.outputs.tester == 'true'"* ]] || false
    [[ "$bloc" == *"devzone enable ai"* ]] || false
    [[ "$bloc" == *"claude --version"* ]] || false
    [[ "$bloc" == *"opencode --version"* ]] || false
}

@test "fonctionnel.yml: no paths filter, run on each PR" {
    run grep -nE '^[[:space:]]*paths:' "$WORKFLOW"
    [ "$status" -ne 0 ]
    grep -qE '^  pull_request:' "$WORKFLOW"
}

@test "fonctionnel.yml: bats job on ubuntu and macOS (bash 3.2), on each PR without path decision" {
    bloc="$(awk '/^  bats:/ { inside = 1; print; next } inside && /^  [a-z0-9-]+:/ { exit } inside { print }' "$WORKFLOW")"
    [ -n "$bloc" ]
    [[ "$bloc" == *"os: ubuntu-latest, shard: 1, total: 4"* ]] || false
    [[ "$bloc" == *"os: ubuntu-latest, shard: 4, total: 4"* ]] || false
    [[ "$bloc" == *"os: macos-latest"* ]] || false
    [[ "$bloc" == *'runs-on: ${{ matrix.os }}'* ]] || false
    [[ "$bloc" != *"needs.changements"* ]] || { echo "bats must run on each PR"; false; }
    [[ "$bloc" == *"bats@"* ]] || false
    # ubuntu: the whole suite in four shards (#522); macOS: /bin/bash (3.2) first in PATH, checked
    [[ "$bloc" == *'manage/test/shard.sh "$SHARD" "$TOTAL"'* ]] || false
    [[ "$bloc" == *"ln -s /bin/bash"* ]] || false
    [[ "$bloc" == *'BASH_VERSINFO[0]}" = 3'* ]] || false
    for f in cli.bats versions.bats ci-container.bats agent.bats agent-gaps.bats; do
        [[ "$bloc" == *"manage/test/$f"* ]] || { echo "not run on macOS: $f"; false; }
    done
}

@test "fonctionnel.yml: also run on each push of develop and main (bats only)" {
    grep -qE '^  push:' "$WORKFLOW"
    grep -qE '^    branches: \[develop, main\]' "$WORKFLOW"
    grep -qE 'push\) tester=false' "$WORKFLOW"
}

@test "fonctionnel.yml: tests-conteneur summary always run, after fonctionnel, cli, windows, ia-arm64 and bats" {
    # tests-conteneur job block: from its line to the end of the file or the next job
    bloc="$(awk '/^  tests-conteneur:/ { inside = 1; print; next } inside && /^  [a-z0-9-]+:/ { exit } inside { print }' "$WORKFLOW")"
    [ -n "$bloc" ]
    [[ "$bloc" == *"if: always()"* ]] || false
    [[ "$bloc" == *"needs: [changements, fonctionnel, cli, windows, ia-arm64, bats]"* ]] || false
    [[ "$bloc" == *"bash manage/test/ci-container.sh synthese"* ]] || false
    [[ "$bloc" == *'"$WINDOWS" "$IA_ARM64" "$BATS"'* ]] || false
    [[ "$bloc" == *'BATS: ${{ needs.bats.result }}'* ]] || false
    for job in fonctionnel cli windows ia-arm64; do
        awk -v j="  $job:" '$0 == j { inside = 1; next } inside && /^  [a-z0-9-]+:/ { exit } inside { print }' "$WORKFLOW" |
            grep -q "if: needs.changements.outputs.tester == 'true'" || { echo "job $job run without the path decision"; false; }
    done
}

# Under bash 3.2 (macOS), a failing [[ ... ]] in the middle of a test does not
# fail it (errexit ignored before bash 4.1), and "! command" never does, on any
# bash: every condition of that kind ends with || false
@test "bats tests: no [[ ... ]] condition nor ! command without || false (bash 3.2)" {
    run grep -nE '^[[:space:]]*\[\[.*\]\][[:space:]]*$' "$RACINE"/manage/test/*.bats
    [ "$status" -ne 0 ] || { echo "$output"; false; }
    run grep -nE '^[[:space:]]*! ' "$RACINE"/manage/test/*.bats
    [ -z "$(grep -v '|| false[[:space:]]*$' <<<"$output")" ] || { echo "$output"; false; }
}

# bash 3.2 reads the apostrophe of a comment inside a multiline $( ... ) as an
# open string: the whole .bats file no longer loads (#210)
@test "bats tests: no apostrophe in a comment inside a multiline \$( ... )" {
    run awk '/\$\($/ { inside = 1; next } inside && /^[[:space:]]*\)/ { inside = 0 } inside && /^[[:space:]]*#.*'\''/ { print FILENAME ":" FNR }' "$RACINE"/manage/test/*.bats
    [ -z "$output" ] || { echo "apostrophe in a \$( ... ) comment: $output"; false; }
}

@test ".repowarden.conf: tests-conteneur required to merge" {
    exigees="$(git config -f "$RACINE/.repowarden.conf" repowarden.requiredChecks)"
    [[ ",$exigees," == *",repowarden,"* ]] || false
    [[ ",$exigees," == *",tests-conteneur,"* ]] || false
}

@test "bash32.sh: list passed to the image runner = macOS job" {
    SCRIPT="$RACINE/manage/test/bash32.sh"
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat > "$BATS_TEST_TMPDIR/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
echo "docker $*" >>"$BATS_TEST_TMPDIR/docker.log"
exit 0
DOCKER
    chmod +x "$BATS_TEST_TMPDIR/bin/docker"
    for c in bash grep tr head; do
        ln -sf "$(command -v "$c")" "$BATS_TEST_TMPDIR/bin/$c"
    done
    export PATH="$BATS_TEST_TMPDIR/bin:/usr/bin:/bin"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q "bash:3.2" "$BATS_TEST_TMPDIR/docker.log"
    grep -q "manage/test/cli.bats manage/test/versions.bats manage/test/ci-container.bats manage/test/agent.bats manage/test/agent-gaps.bats" "$BATS_TEST_TMPDIR/docker.log" || false
}

@test "bash32.sh: without the engine -> code 2 and message" {
    SCRIPT="$RACINE/manage/test/bash32.sh"
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    for c in bash grep tr head rm; do
        ln -sf "$(command -v "$c")" "$BATS_TEST_TMPDIR/bin/$c"
    done
    export PATH="$BATS_TEST_TMPDIR/bin"
    run bash "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Docker requis"* ]] || false
}

@test "bash32.sh: failing fake engine -> code 1" {
    SCRIPT="$RACINE/manage/test/bash32.sh"
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat > "$BATS_TEST_TMPDIR/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
echo "docker $*" >>"$BATS_TEST_TMPDIR/docker.log"
exit 1
DOCKER
    chmod +x "$BATS_TEST_TMPDIR/bin/docker"
    for c in bash grep tr head; do
        ln -sf "$(command -v "$c")" "$BATS_TEST_TMPDIR/bin/$c"
    done
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
}

@test "bash32.sh: macOS job bats version in the runner list" {
    SCRIPT="$RACINE/manage/test/bash32.sh"
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat > "$BATS_TEST_TMPDIR/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
echo "docker $*" >>"$BATS_TEST_TMPDIR/docker.log"
exit 0
DOCKER
    chmod +x "$BATS_TEST_TMPDIR/bin/docker"
    for c in bash grep tr head; do
        ln -sf "$(command -v "$c")" "$BATS_TEST_TMPDIR/bin/$c"
    done
    export PATH="$BATS_TEST_TMPDIR/bin:/usr/bin:/bin"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q "bash:3.2" "$BATS_TEST_TMPDIR/docker.log"
    grep -q "manage/test/cli.bats manage/test/versions.bats manage/test/ci-container.bats manage/test/agent.bats manage/test/agent-gaps.bats" "$BATS_TEST_TMPDIR/docker.log" || false
    grep -q "v1.10.0" "$BATS_TEST_TMPDIR/docker.log" || false
}
