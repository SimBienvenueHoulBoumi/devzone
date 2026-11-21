#!/usr/bin/env bash
# Builds the Go binary of devzone for the six platforms of the npm package
# (linux, darwin, windows; amd64, arm64) into bin/ at the root of the package
# (#773):
#   bin/devzone-<os>-<arch>   (.exe for windows)
#   bin/SHA256SUMS            one "<sum>  <name>" line per binary
# It is the "prepack" script of package.json: it runs on "npm publish" and
# "npm pack", never with --ignore-scripts. manage/devzone checks the sums, then
# runs the binary of the machine.
#
# The runner of the publication has Go, but not necessarily the version of
# go.mod. The script reads the version the image uses (ARG GO_VERSION of
# .devcontainer/Dockerfile) and sets GOTOOLCHAIN to it: a Go 1.21 or newer
# downloads that exact toolchain by itself (3 attempts, 5 s apart). Without Go,
# or with a Go older than 1.21, it fails with the reason. A package with a
# missing binary is never produced: any failure exits 1.
#
# The version printed by "devzone --version" is not injected: the Go binary
# reads the package.json of the package, as the bash command does.
# Progress goes to the standard error: npm pack --json keeps its report clean.
# bash 3.2 (macOS).

set -euo pipefail

ICI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$ICI/../../.." && pwd)"
OUT="$ROOT/bin"
IMAGE_FILE="$ROOT/.devcontainer/Dockerfile"
TARGETS="linux-amd64 linux-arm64 darwin-amd64 darwin-arm64 windows-amd64 windows-arm64"

die() {
    echo "build-binaries: $*" >&2
    exit 1
}

# retry <attempts> <pause in seconds> <command...>: the command succeeds at the
# first attempt that works; the last failure is the result
retry() {
    local attempts="$1" pause="$2" n=1
    shift 2
    until "$@"; do
        [ "$n" -lt "$attempts" ] || return 1
        echo "build-binaries: attempt $n of $attempts failed, new attempt in ${pause}s" >&2
        n=$((n + 1))
        sleep "$pause"
    done
}

# SHA-256 of file $1
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        node -e 'const h = require("crypto").createHash("sha256"); h.update(require("fs").readFileSync(process.argv[1])); console.log(h.digest("hex"))' "$1"
    fi
}

# Selects the Go toolchain of the image through GOTOOLCHAIN
select_toolchain() {
    local want local_version major minor
    [ -f "$IMAGE_FILE" ] || die "$IMAGE_FILE not found (the Go version is read there)"
    want="$(sed -n 's/^ARG GO_VERSION=//p' "$IMAGE_FILE" | head -n 1)"
    [ -n "$want" ] || die "no ARG GO_VERSION in $IMAGE_FILE"
    command -v go >/dev/null 2>&1 || die "go not found: install Go 1.21 or newer (the build then downloads Go $want by itself)"
    local_version="$(go version | sed -n 's/^go version go\([0-9][0-9.]*\).*/\1/p')"
    [ -n "$local_version" ] || die "cannot read the version of go (go version: $(go version))"
    major="${local_version%%.*}"
    minor="${local_version#*.}"
    minor="${minor%%.*}"
    if [ "$major" -lt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -lt 21 ]; }; then
        die "go $local_version is too old: Go 1.21 or newer is needed to select Go $want (GOTOOLCHAIN)"
    fi
    export GOTOOLCHAIN="go$want"
    # Downloads the toolchain now, with retries: a network failure stops here
    retry 3 5 go version >/dev/null || die "cannot obtain the Go $want toolchain (network?)"
    [ "$(go version | sed -n 's/^go version go\([0-9][0-9.]*\).*/\1/p')" = "$want" ] \
        || die "go $want expected, got: $(go version)"
    echo "build-binaries: $(go version)" >&2
}

build_all() {
    local target goos goarch name
    rm -rf "$OUT"
    mkdir -p "$OUT"
    for target in $TARGETS; do
        goos="${target%-*}"
        goarch="${target#*-}"
        name="devzone-$target"
        [ "$goos" != windows ] || name="$name.exe"
        echo "build-binaries: $name" >&2
        (cd "$ROOT" && CGO_ENABLED=0 GOOS="$goos" GOARCH="$goarch" \
            go build -trimpath -ldflags "-s -w" -o "$OUT/$name" ./cmd/devzone) \
            || die "build of $name failed"
    done
}

# Writes bin/SHA256SUMS and refuses a package with a missing or empty binary
write_sums() {
    local target name count=0
    : >"$OUT/SHA256SUMS"
    for target in $TARGETS; do
        name="devzone-$target"
        case "$target" in windows-*) name="$name.exe" ;; esac
        [ -s "$OUT/$name" ] || die "binary missing or empty: bin/$name"
        printf '%s  %s\n' "$(sha256_of "$OUT/$name")" "$name" >>"$OUT/SHA256SUMS"
        count=$((count + 1))
    done
    [ "$count" -eq 6 ] || die "$count binaries instead of 6"
}

select_toolchain
build_all
write_sums
echo "build-binaries: 6 binaries and SHA256SUMS in $OUT" >&2
