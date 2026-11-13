#!/usr/bin/env bats
# versions.sh script: compares pinned container versions with npm (mocked)
# and applies a targeted upgrade.

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin" \
        "$BATS_TEST_TMPDIR/dz/manage/scripts" "$BATS_TEST_TMPDIR/dz/.devcontainer"
    cp "$ROOT/manage/scripts/versions.sh" "$BATS_TEST_TMPDIR/dz/manage/scripts/"
    VERSIONS="$BATS_TEST_TMPDIR/dz/manage/scripts/versions.sh"
    VERSIONS_ENV="$BATS_TEST_TMPDIR/dz/.devcontainer/versions.env"
    DEVZONE="$BATS_TEST_TMPDIR/dz/.devcontainer/devzone"
    cat >"$VERSIONS_ENV" <<'EOFENV'
# repowarden, pinned version
REPOWARDEN_VERSION=4.12.0
EOFENV
    cat >"$DEVZONE" <<'EOFDZ'
#!/usr/bin/env bash
# Claude Code
IA_CLAUDE=@anthropic-ai/claude-code@2.1.286
# opencode
IA_OPENCODE=opencode-ai@1.18.34
IA_PAQUETS=("$IA_CLAUDE" "$IA_OPENCODE")
IA_NOMS=("${IA_CLAUDE%@*}" "${IA_OPENCODE%@*}")
EOFDZ
    chmod +x "$DEVZONE"
    export NPM_VERSIONS="$BATS_TEST_TMPDIR/versions"
    export NPM_INSTALLED="$BATS_TEST_TMPDIR/installed"
    : >"$NPM_INSTALLED"
    cat >"$BATS_TEST_TMPDIR/bin/npm" <<'EOFNPM'
#!/usr/bin/env bash
if [ "${1:-}" = view ] && [ "${3:-}" = version ]; then
    awk -v p="$2" '$1 == p { print $2; found = 1 } END { exit found ? 0 : 1 }' "$NPM_VERSIONS"
elif [ "${1:-}" = ls ] && [ "${2:-}" = -g ]; then
    printf '{"dependencies":{'
    sep=""
    while read -r p v; do
        [ -n "$p" ] || continue
        printf '%s"%s":{"version":"%s"}' "$sep" "$p" "$v"
        sep=","
    done <"$NPM_INSTALLED"
    printf '}}\n'
else
    exit 2
fi
EOFNPM
    chmod +x "$BATS_TEST_TMPDIR/bin/npm"
    export GH_TICKETS="$BATS_TEST_TMPDIR/tickets.json"
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

npm_versions() {
    : >"$NPM_VERSIONS"
    while [ "$#" -gt 0 ]; do
        printf '%s %s\n' "$1" "$2" >>"$NPM_VERSIONS"
        shift 2
    done
}

npm_installed() {
    : >"$NPM_INSTALLED"
    while [ "$#" -gt 0 ]; do
        printf '%s %s\n' "$1" "$2" >>"$NPM_INSTALLED"
        shift 2
    done
}

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

@test "all up to date: no line" {
    npm_versions repowarden 4.12.0 @anthropic-ai/claude-code 2.1.286 opencode-ai 1.18.34
    run bash "$VERSIONS"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "--installed all up to date: no line" {
    npm_installed repowarden 4.12.0 @anthropic-ai/claude-code 2.1.286 opencode-ai 1.18.34
    run bash "$VERSIONS" --installed
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "--installed and --installees are equivalent" {
    npm_installed repowarden 4.9.2 @anthropic-ai/claude-code 2.1.286 opencode-ai 1.18.34
    run bash "$VERSIONS" --installed
    [ "$status" -eq 0 ]
    [ "$output" = "repowarden 4.12.0 4.9.2" ]
    run bash "$VERSIONS" --installees
    [ "$status" -eq 0 ]
    [ "$output" = "repowarden 4.12.0 4.9.2" ]
}

@test "--installed: not installed AI tool not listed" {
    npm_installed repowarden 4.12.0
    run bash "$VERSIONS" --installed
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "one outdated package: one package old new line" {
    npm_versions repowarden 4.13.0 @anthropic-ai/claude-code 2.1.286 opencode-ai 1.18.34
    run bash "$VERSIONS"
    [ "$status" -eq 0 ]
    [ "$output" = "repowarden 4.12.0 4.13.0" ]
}

@test "scoped AI package outdated: recognized on its IA_CLAUDE line" {
    npm_versions repowarden 4.12.0 @anthropic-ai/claude-code 2.2.0 opencode-ai 1.18.34
    run bash "$VERSIONS"
    [ "$status" -eq 0 ]
    [ "$output" = "@anthropic-ai/claude-code 2.1.286 2.2.0" ]
}

@test "unscoped AI package outdated: recognized on its IA_OPENCODE line" {
    npm_versions repowarden 4.12.0 @anthropic-ai/claude-code 2.1.286 opencode-ai 1.19.0
    run bash "$VERSIONS"
    [ "$status" -eq 0 ]
    [ "$output" = "opencode-ai 1.18.34 1.19.0" ]
}

@test "npm version older than pinned version: no downgrade" {
    npm_versions repowarden 4.11.0 @anthropic-ai/claude-code 2.1.286 opencode-ai 1.18.34
    run bash "$VERSIONS"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "--apply repowarden: only versions.env version changes" {
    before="$(cat "$DEVZONE")"
    run bash "$VERSIONS" --apply repowarden 4.13.0
    [ "$status" -eq 0 ]
    grep -qx 'REPOWARDEN_VERSION=4.13.0' "$VERSIONS_ENV"
    [ "$(cat "$DEVZONE")" = "$before" ]
}

@test "--apply and --appliquer are equivalent" {
    run bash "$VERSIONS" --appliquer opencode-ai 1.19.0
    [ "$status" -eq 0 ]
    grep -qx 'IA_OPENCODE=opencode-ai@1.19.0' "$DEVZONE"
}

@test "--apply AI package: only its version changes, other stays" {
    run bash "$VERSIONS" --apply @anthropic-ai/claude-code 2.2.0
    [ "$status" -eq 0 ]
    grep -qx 'IA_CLAUDE=@anthropic-ai/claude-code@2.2.0' "$DEVZONE"
    grep -qx 'IA_OPENCODE=opencode-ai@1.18.34' "$DEVZONE"
    grep -qxF 'IA_PAQUETS=("$IA_CLAUDE" "$IA_OPENCODE")' "$DEVZONE"
    grep -qx 'REPOWARDEN_VERSION=4.12.0' "$VERSIONS_ENV"
}

@test "--apply opencode-ai: scoped version remains intact" {
    run bash "$VERSIONS" --apply opencode-ai 1.19.0
    [ "$status" -eq 0 ]
    grep -qx 'IA_CLAUDE=@anthropic-ai/claude-code@2.1.286' "$DEVZONE"
    grep -qx 'IA_OPENCODE=opencode-ai@1.19.0' "$DEVZONE"
}

@test "real devzone file: both AI assistants read by versions.sh" {
    npm_versions repowarden 999.0.0 @anthropic-ai/claude-code 999.0.0 opencode-ai 999.0.0
    run bash "$ROOT/manage/scripts/versions.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"@anthropic-ai/claude-code "*" 999.0.0"* ]] || false
    [[ "$output" == *"opencode-ai "*" 999.0.0"* ]] || false
}

@test "two simultaneous upgrades (Claude Code, opencode): merged one after another without conflict" {
    # Real devzone file, to check its layout
    cp "$ROOT/.devcontainer/devzone" "$DEVZONE"
    export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid \
        GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
    cd "$BATS_TEST_TMPDIR/dz"
    git init -q
    base="$(git branch --show-current)"
    git add .devcontainer manage
    git commit -qm base
    git checkout -qb claude
    bash "$VERSIONS" --apply @anthropic-ai/claude-code 999.0.0
    git commit -qam claude
    git checkout -q "$base"
    git checkout -qb opencode
    bash "$VERSIONS" --apply opencode-ai 999.1.0
    git commit -qam opencode
    git checkout -q "$base"
    git merge -q --no-ff -m "merge claude" claude
    run git merge --no-ff -m "merge opencode" opencode
    [ "$status" -eq 0 ]
    grep -qx 'IA_CLAUDE=@anthropic-ai/claude-code@999.0.0' "$DEVZONE"
    grep -qx 'IA_OPENCODE=opencode-ai@999.1.0' "$DEVZONE"
}

@test "--apply keeps devzone executable bit" {
    [ -x "$DEVZONE" ]
    run bash "$VERSIONS" --apply opencode-ai 1.19.0
    [ "$status" -eq 0 ]
    [ -x "$DEVZONE" ]
}

@test "--apply: unknown package refused, files unchanged" {
    before_env="$(cat "$VERSIONS_ENV")"
    before_devzone="$(cat "$DEVZONE")"
    run bash "$VERSIONS" --apply notfound 1.0.0
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown package"* ]] || false
    [ "$(cat "$VERSIONS_ENV")" = "$before_env" ]
    [ "$(cat "$DEVZONE")" = "$before_devzone" ]
}

@test "--apply without version: usage shown" {
    run bash "$VERSIONS" --apply repowarden
    [ "$status" -ne 0 ]
    [[ "$output" == *"--apply"* ]] || false
}

@test "--existing-ticket: App ticket found (number and title)" {
    open_tickets 42 "repowarden 9.9.9 in container" "app/repowarden-devzone"
    run bash "$VERSIONS" --existing-ticket repowarden "app/repowarden-devzone"
    [ "$status" -eq 0 ]
    [ "$output" = $'42	repowarden 9.9.9 in container' ]
}

@test "--existing-ticket and --ticket-existant are equivalent" {
    open_tickets 42 "repowarden 9.9.9 in container" "app/repowarden-devzone"
    run bash "$VERSIONS" --ticket-existant repowarden "app/repowarden-devzone"
    [ "$status" -eq 0 ]
    [ "$output" = $'42	repowarden 9.9.9 in container' ]
}

@test "--existing-ticket: same title opened by another author ignored" {
    open_tickets 43 "repowarden 9.9.9 in container" "intruder"
    run bash "$VERSIONS" --existing-ticket repowarden "app/repowarden-devzone"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "--existing-ticket: [bot] author form ignored" {
    open_tickets 45 "repowarden 9.9.9 in container" "repowarden-devzone[bot]"
    run bash "$VERSIONS" --existing-ticket repowarden "app/repowarden-devzone"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "--existing-ticket: title of another package ignored" {
    open_tickets 44 "opencode-ai 9.9.9 in container" "app/repowarden-devzone"
    run bash "$VERSIONS" --existing-ticket repowarden "app/repowarden-devzone"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "--existing-ticket: ticket already opened by App is updated" {
    open_tickets 42 "repowarden 9.9.9 in container" "app/repowarden-devzone"
    run bash "$VERSIONS" --existing-ticket repowarden "app/repowarden-devzone"
    [ "$status" -eq 0 ]
    [ "$output" = $'42	repowarden 9.9.9 in container' ]
}

@test "versions workflow: proposed design, never retained (maintainer rewrites)" {
    workflow="$ROOT/.github/workflows/versions.yml"
    grep -q 'Conception propos' "$workflow"
    ! grep -q '^ *## Conception retenue' "$workflow" || false
}

@test "versions workflow: hourly cron and conditional repowarden install" {
    workflow="$ROOT/.github/workflows/versions.yml"
    grep -Eq 'cron: *"17 \* \* \* \*"' "$workflow"
    run awk '
        /- name: Repowarden at the same pinned version as the container/ { in_step = 1; next }
        in_step && /^      - / { exit }
        in_step { print }
    ' "$workflow"
    [ "$status" -eq 0 ]
    [[ "$output" == *"if: steps.retards.outputs.present == 'true'"* ]] || false
    [[ "$output" == *'npm install -g "repowarden'* ]] || false
    [[ "$output" == *'@$version"'* ]] || false
}
