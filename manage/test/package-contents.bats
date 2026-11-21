#!/usr/bin/env bats
# Contents of the npm package, read with npm pack --dry-run (no network, nothing
# published, no lifecycle script). Skipped without npm. See "Package contents"
# in manage/docs/contributing.md.

# Ceilings: measured on the package at #772 (159 files, 792412 bytes unpacked),
# plus 10 %, rounded up. Raise one only with a reason in the commit.
MAX_FILES=175
MAX_UNPACKED=872000

setup() {
    command -v npm >/dev/null 2>&1 || skip "npm absent: package contents not checked"
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    PACK_JSON="$BATS_TEST_TMPDIR/pack.json"
    PACK_FILES="$BATS_TEST_TMPDIR/files.txt"
    (cd "$RACINE" && npm_config_update_notifier=false npm pack --dry-run --json --ignore-scripts >"$PACK_JSON" 2>/dev/null)
    [ -s "$PACK_JSON" ] || { echo "npm pack --dry-run produced no report"; return 1; }
    pack_value files >"$PACK_FILES"
    PACK_COUNT="$(pack_value count)"
    PACK_UNPACKED="$(pack_value unpacked)"
}

# Reads one value of the npm report, with jq when present, else with node.
# $1: files (one path per line), count (number of files) or unpacked (bytes)
pack_value() {
    if command -v jq >/dev/null 2>&1; then
        case "$1" in
            files) jq -r '.[0].files[].path' "$PACK_JSON" ;;
            count) jq -r '.[0].files | length' "$PACK_JSON" ;;
            unpacked) jq -r '.[0].unpackedSize' "$PACK_JSON" ;;
        esac
    else
        node -e 'const p = JSON.parse(require("fs").readFileSync(process.argv[1]))[0]; const v = { files: p.files.map((f) => f.path).join("\n"), count: p.files.length, unpacked: p.unpackedSize }; console.log(v[process.argv[2]])' "$PACK_JSON" "$1"
    fi
}

@test "package: no development, test or internal file is shipped" {
    interdits=""
    while IFS= read -r f; do
        case "$f" in
            manage/test/* | manage/docs/* | cmd/* | internal/* | .github/* | .claude/* | .opencode/*)
                interdits="$interdits $f" ;;
            go.mod | go.sum | .english | .repowarden.conf | CLAUDE.md | AGENTS.md | CONTRIBUTING.md)
                interdits="$interdits $f" ;;
        esac
    done <"$PACK_FILES"
    [ -z "$interdits" ] || { echo "files that must not ship:$interdits"; return 1; }
}

@test "package: the files a devzone needs are shipped" {
    # isolation.sh and ticket.sh are used at run time (not only by the tests)
    for f in manage/devzone manage/workspace.sh .devcontainer/devzone .devcontainer/Dockerfile \
        .devcontainer/isolation.sh .devcontainer/ticket.sh Makefile README.md LICENSE; do
        grep -qxF -- "$f" "$PACK_FILES" || { echo "missing from the package: $f"; return 1; }
    done
    grep -q '^charts/[^/]*/' "$PACK_FILES" || { echo "no chart in charts/"; return 1; }
}

@test "package: file count and unpacked size stay under the ceilings" {
    [ "$PACK_COUNT" -le "$MAX_FILES" ] || { echo "$PACK_COUNT files, ceiling $MAX_FILES"; return 1; }
    [ "$PACK_UNPACKED" -le "$MAX_UNPACKED" ] || { echo "$PACK_UNPACKED bytes unpacked, ceiling $MAX_UNPACKED"; return 1; }
}
