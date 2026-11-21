#!/usr/bin/env bats
# versions.sh --tools and --apply <tool> (tools-image.sh): a fake curl answers
# from fixture files, so no test reaches the network.

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/http" \
        "$BATS_TEST_TMPDIR/dz/manage/scripts/ci" "$BATS_TEST_TMPDIR/dz/.devcontainer"
    cp "$ROOT/manage/scripts/ci/versions.sh" "$ROOT/manage/scripts/ci/tools-image.sh" \
        "$BATS_TEST_TMPDIR/dz/manage/scripts/ci/"
    VERSIONS="$BATS_TEST_TMPDIR/dz/manage/scripts/ci/versions.sh"
    DOCKERFILE="$BATS_TEST_TMPDIR/dz/.devcontainer/Dockerfile"
    cp "$ROOT/.devcontainer/Dockerfile" "$DOCKERFILE"
    ORIG="$BATS_TEST_TMPDIR/Dockerfile.orig"
    cp "$DOCKERFILE" "$ORIG"
    export FAKE_HTTP="$BATS_TEST_TMPDIR/http"
    cat >"$BATS_TEST_TMPDIR/bin/curl" <<'EOFCURL'
#!/usr/bin/env bash
# Fake curl: answers from $FAKE_HTTP/<url, non-alphanumerics as _>, exit 22 if absent
out=""
url=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift ;;
        http*) url="$1" ;;
    esac
    shift
done
file="$FAKE_HTTP/$(printf '%s' "$url" | tr -c 'A-Za-z0-9' '_')"
if [ ! -f "$file" ]; then
    echo "fake curl: no fixture for $url" >&2
    exit 22
fi
if [ -n "$out" ]; then cp "$file" "$out"; else cat "$file"; fi
EOFCURL
    chmod +x "$BATS_TEST_TMPDIR/bin/curl"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    # Every upstream answers the pinned version: nothing is outdated by default
    serve_github derailed/k9s "v$(pin K9S_VERSION)"
    serve_github rhysd/actionlint "v$(pin ACTIONLINT_VERSION)"
    serve_github gitleaks/gitleaks "v$(pin GITLEAKS_VERSION)"
    serve_github kubernetes-sigs/kind "v$(pin KIND_VERSION)"
    serve_go_index
}

# Value of the Dockerfile ARG $1
pin() {
    sed -nE "s/^ARG $1=([^[:space:]]+)\$/\1/p" "$DOCKERFILE"
}

# URL to fixture file name, as the fake curl reads it
key() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'
}

# Serves the body $2 for the URL $1
serve() {
    printf '%s' "$2" >"$FAKE_HTTP/$(key "$1")"
}

# Serves the latest GitHub release $2 of repository $1
serve_github() {
    serve "https://api.github.com/repos/$1/releases/latest" "{\"tag_name\":\"$2\"}"
}

# Serves the go.dev index: the pinned Go release, then version $1 (if given)
# with the sha256 $2 (amd64) and $3 (arm64) of its archives
serve_go_index() {
    local json
    json="[{\"version\":\"go$(pin GO_VERSION)\",\"stable\":true,\"files\":[]}"
    if [ -n "${1:-}" ]; then
        json="$json,{\"version\":\"go$1\",\"stable\":true,\"files\":[{\"filename\":\"go$1.linux-amd64.tar.gz\",\"sha256\":\"$2\"},{\"filename\":\"go$1.linux-arm64.tar.gz\",\"sha256\":\"$3\"}]},{\"version\":\"go$1rc1\",\"stable\":false,\"files\":[]}"
    fi
    serve "https://go.dev/dl/?mode=json&include=all" "$json]"
}

# sha256 of the text $1, as the archive served with that text
sha_of() {
    printf '%s' "$1" | sha256sum | awk '{ print $1 }'
}

# Dockerfile lines changed compared to the original, with "<" as diff prints them
changed_lines() {
    diff "$ORIG" "$DOCKERFILE" | grep '^<' || true
}

@test "--tools: everything up to date, nothing printed" {
    run bash "$VERSIONS" --tools
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "--tools: Go minor release listed with pinned and upstream versions" {
    serve_go_index 1.28.0 aaaa bbbb
    run bash "$VERSIONS" --tools
    [ "$status" -eq 0 ]
    [ "$output" = "go $(pin GO_VERSION) 1.28.0" ]
}

@test "--tools: GitHub tool minor release listed" {
    serve_github derailed/k9s v0.52.0
    run bash "$VERSIONS" --tools
    [ "$status" -eq 0 ]
    [ "$output" = "k9s $(pin K9S_VERSION) 0.52.0" ]
}

@test "--tools: next major version listed with majeure, not applied" {
    serve_github rhysd/actionlint v2.0.0
    run bash "$VERSIONS" --tools
    [ "$status" -eq 0 ]
    [ "$output" = "actionlint $(pin ACTIONLINT_VERSION) 2.0.0 majeure" ]
    [ "$(cat "$DOCKERFILE")" = "$(cat "$ORIG")" ]
}

@test "--tools: upstream not answering: error, no guess" {
    rm "$FAKE_HTTP/$(key "https://api.github.com/repos/derailed/k9s/releases/latest")"
    run bash "$VERSIONS" --tools
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot read upstream version for k9s"* ]] || false
}

@test "--apply go: minor release applied, both fingerprints recomputed" {
    serve "https://go.dev/dl/go1.28.0.linux-amd64.tar.gz" "go amd64 archive 1.28.0"
    serve "https://go.dev/dl/go1.28.0.linux-arm64.tar.gz" "go arm64 archive 1.28.0"
    serve_go_index 1.28.0 "$(sha_of "go amd64 archive 1.28.0")" "$(sha_of "go arm64 archive 1.28.0")"
    run bash "$VERSIONS" --apply go 1.28.0
    [ "$status" -eq 0 ]
    grep -qx 'ARG GO_VERSION=1.28.0' "$DOCKERFILE"
    grep -qx "ARG GO_SHA256_AMD64=$(sha_of "go amd64 archive 1.28.0")" "$DOCKERFILE"
    grep -qx "ARG GO_SHA256_ARM64=$(sha_of "go arm64 archive 1.28.0")" "$DOCKERFILE"
}

@test "--apply go: only the three Go lines change" {
    serve "https://go.dev/dl/go1.28.0.linux-amd64.tar.gz" "go amd64 archive 1.28.0"
    serve "https://go.dev/dl/go1.28.0.linux-arm64.tar.gz" "go arm64 archive 1.28.0"
    serve_go_index 1.28.0 "$(sha_of "go amd64 archive 1.28.0")" "$(sha_of "go arm64 archive 1.28.0")"
    run bash "$VERSIONS" --apply go 1.28.0
    [ "$status" -eq 0 ]
    [ "$(changed_lines | wc -l | tr -d ' ')" = 3 ]
    [ -z "$(changed_lines | grep -v 'GO_')" ]
}

@test "--apply k9s: shared sha256 name, arm64 and amd64 lines both updated" {
    serve "https://github.com/derailed/k9s/releases/download/v0.52.0/k9s_Linux_amd64.tar.gz" "k9s amd64"
    serve "https://github.com/derailed/k9s/releases/download/v0.52.0/k9s_Linux_arm64.tar.gz" "k9s arm64"
    run bash "$VERSIONS" --apply k9s 0.52.0
    [ "$status" -eq 0 ]
    grep -qx 'ARG K9S_VERSION=0.52.0' "$DOCKERFILE"
    grep -qF "k9s_sha=$(sha_of "k9s arm64");" "$DOCKERFILE"
    grep -qF "k9s_sha=$(sha_of "k9s amd64");" "$DOCKERFILE"
    [ "$(changed_lines | wc -l | tr -d ' ')" = 3 ]
    [ -z "$(changed_lines | grep -vE 'K9S_VERSION|k9s_sha')" ]
}

@test "--apply kind: archive absent, refused, Dockerfile unchanged" {
    run bash "$VERSIONS" --apply kind 0.34.0
    [ "$status" -ne 0 ]
    [[ "$output" == *"archive not found"* ]] || false
    cmp -s "$ORIG" "$DOCKERFILE"
}

@test "--apply go: go.dev checksum differing from the computed one, refused" {
    serve "https://go.dev/dl/go1.28.0.linux-amd64.tar.gz" "go amd64 archive 1.28.0"
    serve "https://go.dev/dl/go1.28.0.linux-arm64.tar.gz" "go arm64 archive 1.28.0"
    serve_go_index 1.28.0 "$(sha_of "go amd64 archive 1.28.0")" "$(sha_of "another archive")"
    run bash "$VERSIONS" --apply go 1.28.0
    [ "$status" -ne 0 ]
    [[ "$output" == *"differs from the official one"* ]] || false
    cmp -s "$ORIG" "$DOCKERFILE"
}

@test "--apply k9s: next major refused without --major, Dockerfile unchanged" {
    serve "https://github.com/derailed/k9s/releases/download/v1.0.0/k9s_Linux_amd64.tar.gz" "k9s amd64 1"
    serve "https://github.com/derailed/k9s/releases/download/v1.0.0/k9s_Linux_arm64.tar.gz" "k9s arm64 1"
    run bash "$VERSIONS" --apply k9s 1.0.0
    [ "$status" -ne 0 ]
    [[ "$output" == *"major"* ]] || false
    cmp -s "$ORIG" "$DOCKERFILE"
}

@test "--apply k9s --major: next major applied" {
    serve "https://github.com/derailed/k9s/releases/download/v1.0.0/k9s_Linux_amd64.tar.gz" "k9s amd64 1"
    serve "https://github.com/derailed/k9s/releases/download/v1.0.0/k9s_Linux_arm64.tar.gz" "k9s arm64 1"
    run bash "$VERSIONS" --apply k9s 1.0.0 --major
    [ "$status" -eq 0 ]
    grep -qx 'ARG K9S_VERSION=1.0.0' "$DOCKERFILE"
}

@test "--apply tool: invalid version refused, Dockerfile unchanged" {
    run bash "$VERSIONS" --apply go "1.28;rm"
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid version"* ]] || false
    cmp -s "$ORIG" "$DOCKERFILE"
}

@test "--apply tool: unknown option refused" {
    run bash "$VERSIONS" --apply go 1.28.0 --force
    [ "$status" -ne 0 ]
    cmp -s "$ORIG" "$DOCKERFILE"
}
