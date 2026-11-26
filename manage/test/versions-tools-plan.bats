#!/usr/bin/env bats
# versions-tools-plan.sh: plan of the image tools to bump, from a simulated
# "versions.sh --tools" output. The GitHub CLI is faked (open tickets), so no
# test reaches the network.

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/dz/manage/scripts/ci"
    cp "$ROOT/manage/scripts/ci/versions.sh" "$ROOT/manage/scripts/ci/tools-image.sh" \
        "$ROOT/manage/scripts/ci/versions-tools-plan.sh" "$BATS_TEST_TMPDIR/dz/manage/scripts/ci/"
    PLAN="$BATS_TEST_TMPDIR/dz/manage/scripts/ci/versions-tools-plan.sh"
    INPUT="$BATS_TEST_TMPDIR/tools.txt"
    export GH_TICKETS="$BATS_TEST_TMPDIR/tickets.json"
    open_tickets
    cat >"$BATS_TEST_TMPDIR/bin/gh" <<'EOFGH'
#!/usr/bin/env bash
if [ "${1:-}" = issue ] && [ "${2:-}" = list ]; then
    expression='.[]'
    while [ "$#" -gt 0 ]; do
        if [ "$1" = --jq ]; then
            expression="$2"
            shift
        fi
        shift
    done
    jq -r "$expression" "$GH_TICKETS"
else
    exit 2
fi
EOFGH
    chmod +x "$BATS_TEST_TMPDIR/bin/gh"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# Writes the arguments, one per line, as the input of the plan (--tools output)
tools() {
    : >"$INPUT"
    for line in "$@"; do
        printf '%s\n' "$line" >>"$INPUT"
    done
}

# Runs the plan for the App author, with the optional limit $1 (3 by default)
plan() {
    run bash "$PLAN" app/repowarden-devzone "${1:-3}" <"$INPUT"
}

# Field $1 of the first output line
field() {
    printf '%s\n' "$output" | awk -F'\t' -v n="$1" 'NR == 1 { print $n }'
}

# Number of output lines whose kind (first field) is $1
count_kind() {
    printf '%s\n' "$output" | awk -F'\t' -v k="$1" '$1 == k' | wc -l | tr -d ' '
}

# Open tickets as the fake gh lists them: number, title, author login (triples)
open_tickets() {
    local sep=""
    printf '[' >"$GH_TICKETS"
    while [ "$#" -gt 0 ]; do
        printf '%s{"number":%s,"title":"%s","author":{"login":"%s"}}' "$sep" "$1" "$2" "$3" >>"$GH_TICKETS"
        sep=","
        shift 3
    done
    printf ']\n' >>"$GH_TICKETS"
}

@test "minor upgrade: one plan line with the versions, notes and no ticket" {
    tools "go 1.27.1 1.28.0"
    plan
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = 1 ]
    [ "$(field 1)" = plan ]
    [ "$(field 2)" = go ]
    [ "$(field 3)" = 1.27.1 ]
    [ "$(field 4)" = 1.28.0 ]
    [ "$(field 6)" = https://go.dev/doc/devel/release#go1.28.0 ]
    [ "$(field 7)" = - ]
}

@test "title has the form: tool old → new in the image" {
    tools "k9s 0.51.0 0.52.0"
    plan
    [ "$status" -eq 0 ]
    [ "$(field 5)" = "k9s 0.51.0 → 0.52.0 in the image" ]
}

@test "GitHub tool notes point to its release tag" {
    tools "gitleaks 8.28.0 8.29.0"
    plan
    [ "$(field 6)" = https://github.com/gitleaks/gitleaks/releases/tag/v8.29.0 ]
}

@test "next major version listed as majeure, never planned" {
    tools "actionlint 1.7.7 2.0.0 majeure"
    plan
    [ "$status" -eq 0 ]
    [ "$(count_kind majeure)" = 1 ]
    [ "$(count_kind plan)" = 0 ]
    [ "$(field 2)" = actionlint ]
    [ "$(field 4)" = 2.0.0 ]
}

@test "major versions do not use the limit of plans" {
    tools "actionlint 1.7.7 2.0.0 majeure" "go 1.27.1 1.28.0" "kind 0.30.0 0.31.0" "k9s 0.51.0 0.52.0" "gitleaks 8.28.0 8.29.0"
    plan
    [ "$status" -eq 0 ]
    [ "$(count_kind majeure)" = 1 ]
    [ "$(count_kind plan)" = 3 ]
}

@test "more than three tools: three plans and a deferred message" {
    tools "go 1.27.1 1.28.0" "k9s 0.51.0 0.52.0" "kind 0.30.0 0.31.0" "gitleaks 8.28.0 8.29.0"
    plan
    [ "$status" -eq 0 ]
    [ "$(count_kind plan)" = 3 ]
    [[ "$output" == *"deferred"* ]] || false
    [[ "$output" == *"gitleaks"* ]] || false
}

@test "limit given as argument" {
    tools "go 1.27.1 1.28.0" "k9s 0.51.0 0.52.0"
    plan 1
    [ "$status" -eq 0 ]
    [ "$(count_kind plan)" = 1 ]
    [[ "$output" == *"deferred"* ]] || false
}

@test "nothing to do: no output" {
    tools
    plan
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "open ticket of the App with the same title: not planned again" {
    open_tickets 50 "go 1.27.1 → 1.28.0 in the image" "app/repowarden-devzone"
    tools "go 1.27.1 1.28.0"
    plan
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "open ticket of the App with another title: existant, with its number" {
    open_tickets 51 "go 1.26.0 → 1.27.1 in the image" "app/repowarden-devzone"
    tools "go 1.27.1 1.28.0"
    plan
    [ "$status" -eq 0 ]
    [ "$(count_kind plan)" = 0 ]
    [ "$(field 1)" = existant ]
    [ "$(field 7)" = 51 ]
    [ "$(field 5)" = "go 1.27.1 → 1.28.0 in the image" ]
}

@test "same title opened by another author: ignored, planned" {
    open_tickets 52 "go 1.27.1 → 1.28.0 in the image" "intruder"
    tools "go 1.27.1 1.28.0"
    plan
    [ "$status" -eq 0 ]
    [ "$(count_kind plan)" = 1 ]
}

@test "unknown tool refused" {
    tools "foo 1.0.0 2.0.0"
    plan
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown tool"* ]] || false
}

@test "line without upstream version refused" {
    tools "go 1.27.1"
    plan
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid line"* ]] || false
}

@test "missing author: usage, status 2" {
    run bash "$PLAN" </dev/null
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage"* ]] || false
}
