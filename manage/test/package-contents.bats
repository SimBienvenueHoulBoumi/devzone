#!/usr/bin/env bats
# Contents of the npm package, read with npm pack --dry-run (no network, nothing
# published, no lifecycle script). Skipped without npm. See "Package contents"
# in manage/docs/contributing.md.

# Ceilings: measured on the package at #772 (159 files, 792412 bytes unpacked),
# plus 10 %, rounded up. Raise one only with a reason in the commit.
MAX_FILES=175
MAX_UNPACKED=872000
# With bin/ built by prepack: measured 127 files, 23762428 bytes unpacked and
# 10052425 bytes packed after the merge of #883, plus 10 %, rounded up to the
# next thousand. Raised from 22843000 and 9631000 because of the Windows port
# watcher in Go: 22289243 -> 23266139 bytes unpacked and 9379707 -> 9777216
# bytes packed when it was ported (measured with build-binaries.sh and
# npm pack --dry-run on the two revisions). See contributing.md.
MAX_FILES_BIN=185
MAX_UNPACKED_BIN=26139000
MAX_PACKED_BIN=11058000
# The only files bin/ may hold
BIN_FILES="bin/SHA256SUMS bin/devzone-linux-amd64 bin/devzone-linux-arm64 bin/devzone-darwin-amd64 bin/devzone-darwin-arm64 bin/devzone-windows-amd64.exe bin/devzone-windows-arm64.exe"

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
    PACK_PACKED="$(pack_value packed)"
}

# Reads one value of the npm report, with jq when present, else with node.
# $1: files (one path per line), count (number of files), unpacked or packed (bytes)
pack_value() {
    if command -v jq >/dev/null 2>&1; then
        case "$1" in
            files) jq -r '.[0].files[].path' "$PACK_JSON" ;;
            count) jq -r '.[0].files | length' "$PACK_JSON" ;;
            unpacked) jq -r '.[0].unpackedSize' "$PACK_JSON" ;;
            packed) jq -r '.[0].size' "$PACK_JSON" ;;
        esac
    else
        node -e 'const p = JSON.parse(require("fs").readFileSync(process.argv[1]))[0]; const v = { files: p.files.map((f) => f.path).join("\n"), count: p.files.length, unpacked: p.unpackedSize, packed: p.size }; console.log(v[process.argv[2]])' "$PACK_JSON" "$1"
    fi
}

@test "package: no development, test or internal file is shipped" {
    interdits=""
    while IFS= read -r f; do
        case "$f" in
            manage/test/* | manage/docs/* | cmd/* | internal/* | .github/* | .claude/* | .opencode/*)
                interdits="$interdits $f" ;;
            go.mod | go.sum | .repowarden.conf | CLAUDE.md | AGENTS.md | CONTRIBUTING.md)
                interdits="$interdits $f" ;;
        esac
    done <"$PACK_FILES"
    [ -z "$interdits" ] || { echo "files that must not ship:$interdits"; return 1; }
}

@test "package: the files a devzone needs are shipped" {
    for f in manage/devzone manage/workspace.sh .devcontainer/devzone .devcontainer/Dockerfile \
        .devcontainer/versions.env Makefile README.md LICENSE; do
        grep -qxF -- "$f" "$PACK_FILES" || { echo "missing from the package: $f"; return 1; }
    done
    grep -q '^charts/[^/]*/' "$PACK_FILES" || { echo "no chart in charts/"; return 1; }
}

@test "package: file count and unpacked size stay under the ceilings" {
    if grep -q '^bin/' "$PACK_FILES"; then
        max_files=$MAX_FILES_BIN
        max_unpacked=$MAX_UNPACKED_BIN
        [ "$PACK_PACKED" -le "$MAX_PACKED_BIN" ] || { echo "$PACK_PACKED bytes packed, ceiling $MAX_PACKED_BIN"; return 1; }
    else
        max_files=$MAX_FILES
        max_unpacked=$MAX_UNPACKED
    fi
    [ "$PACK_COUNT" -le "$max_files" ] || { echo "$PACK_COUNT files, ceiling $max_files"; return 1; }
    [ "$PACK_UNPACKED" -le "$max_unpacked" ] || { echo "$PACK_UNPACKED bytes unpacked, ceiling $max_unpacked"; return 1; }
}

# bin/ is built by prepack and ignored by git: it is in the package only when a
# developer or the release built it. Then it holds the six binaries and the sums,
# nothing else; without it, nothing of bin/ is shipped.
@test "package: bin/ holds the six binaries and SHA256SUMS, only when built" {
    shipped="$(grep '^bin/' "$PACK_FILES" || true)"
    if [ ! -d "$RACINE/bin" ]; then
        [ -z "$shipped" ] || { echo "bin/ shipped without being built: $shipped"; return 1; }
        return 0
    fi
    for f in $BIN_FILES; do
        grep -qxF -- "$f" "$PACK_FILES" || { echo "missing from the package: $f"; return 1; }
    done
    extra=""
    while IFS= read -r f; do
        case " $BIN_FILES " in *" $f "*) ;; *) extra="$extra $f" ;; esac
    done <<<"$shipped"
    [ -z "$extra" ] || { echo "unexpected files in bin/:$extra"; return 1; }
}
