# shellcheck shell=bash
# Tools of the workspace image (Dockerfile): Go, k9s, actionlint, gitleaks and
# kind. Sourced by versions.sh, which defines DOCKERFILE and newer(); not meant
# to run on its own. Compatible with bash 3.2 (macOS).
#   bash manage/scripts/ci/versions.sh --tools
#       one "tool pinned upstream" line per tool behind its upstream release,
#       with " majeure" added when the major version differs; nothing otherwise
#   bash manage/scripts/ci/versions.sh --apply <tool> <version> [--major]
#       replaces the version and both sha256 fingerprints of the tool in the
#       Dockerfile, nothing else
# shellcheck disable=SC2154 # DOCKERFILE and newer() are defined by versions.sh

IMAGE_TOOLS="go k9s actionlint gitleaks kind"

# Prints an error on stderr and exits 1
fail() {
    echo "versions: $*" >&2
    exit 1
}

# True if $1 is a tool of the image
tool_known() {
    case " $IMAGE_TOOLS " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

# Dockerfile variable holding the version of tool $1
tool_version_var() {
    case "$1" in
        go) echo GO_VERSION ;;
        k9s) echo K9S_VERSION ;;
        actionlint) echo ACTIONLINT_VERSION ;;
        gitleaks) echo GITLEAKS_VERSION ;;
        kind) echo KIND_VERSION ;;
    esac
}

# Dockerfile variable holding the sha256 of tool $1 for architecture $2 (arm64
# or amd64). k9s, actionlint, gitleaks and kind use one name for both
# architectures: see tool_sha_occurrence
tool_sha_var() {
    case "$1:$2" in
        go:arm64) echo GO_SHA256_ARM64 ;;
        go:amd64) echo GO_SHA256_AMD64 ;;
        k9s:*) echo k9s_sha ;;
        actionlint:*) echo al_sha ;;
        gitleaks:*) echo gl_sha ;;
        kind:*) echo kind_sha ;;
    esac
}

# Which line naming the sha256 variable of tool $1 for architecture $2 is
# meant: arm64 comes first in the Dockerfile, amd64 second when both share a name
tool_sha_occurrence() {
    if [ "$2" = amd64 ] && [ "$(tool_sha_var "$1" arm64)" = "$(tool_sha_var "$1" amd64)" ]; then
        echo 2
    else
        echo 1
    fi
}

# GitHub repository releasing tool $1 (Go is published on go.dev instead)
tool_repo() {
    case "$1" in
        k9s) echo derailed/k9s ;;
        actionlint) echo rhysd/actionlint ;;
        gitleaks) echo gitleaks/gitleaks ;;
        kind) echo kubernetes-sigs/kind ;;
    esac
}

# URL of the archive of tool $1, version $2, architecture $3 (arm64 or amd64,
# as dpkg names them). kind is published as a bare binary, not an archive
tool_archive_url() {
    local tool="$1" version="$2" arch="$3" gl_arch
    case "$tool" in
        go) echo "https://go.dev/dl/go${version}.linux-${arch}.tar.gz" ;;
        k9s) echo "https://github.com/derailed/k9s/releases/download/v${version}/k9s_Linux_${arch}.tar.gz" ;;
        actionlint) echo "https://github.com/rhysd/actionlint/releases/download/v${version}/actionlint_${version}_linux_${arch}.tar.gz" ;;
        gitleaks)
            gl_arch="$arch"
            [ "$arch" != amd64 ] || gl_arch=x64
            echo "https://github.com/gitleaks/gitleaks/releases/download/v${version}/gitleaks_${version}_linux_${gl_arch}.tar.gz"
            ;;
        kind) echo "https://github.com/kubernetes-sigs/kind/releases/download/v${version}/kind-linux-${arch}" ;;
    esac
}

# Major version (first numeric component) of version $1
major_of() {
    local version="${1#v}"
    echo "${version%%.*}"
}

# Version pinned in the Dockerfile for tool $1 (empty if absent)
tool_pinned() {
    sed -nE "s/^ARG $(tool_version_var "$1")=([^[:space:]]+)\$/\1/p" "$DOCKERFILE"
}

# Highest version among the lines read on stdin (empty if none)
highest() {
    local best="" version
    while read -r version; do
        [ -n "$version" ] || continue
        if [ -z "$best" ] || newer "$version" "$best"; then
            best="$version"
        fi
    done
    printf '%s\n' "$best"
}

# Latest stable version of tool $1 upstream: the go.dev index for Go, the
# latest GitHub release otherwise (empty if the source does not answer)
tool_latest() {
    if [ "$1" = go ]; then
        curl -fsSL "https://go.dev/dl/?mode=json&include=all" 2>/dev/null |
            jq -r '.[] | select(.stable == true) | .version' | sed 's/^go//' | highest
    else
        curl -fsSL "https://api.github.com/repos/$(tool_repo "$1")/releases/latest" 2>/dev/null |
            jq -r '.tag_name // empty' | sed 's/^v//'
    fi
}

# One "tool pinned upstream" line per tool whose upstream version is newer than
# the pinned one, with " majeure" when the major differs; nothing otherwise
tools_outdated() {
    local tool pinned upstream
    for tool in $IMAGE_TOOLS; do
        pinned="$(tool_pinned "$tool")"
        upstream="$(tool_latest "$tool")" || upstream=""
        [ -n "$upstream" ] || fail "cannot read upstream version for $tool"
        if newer "$upstream" "$pinned"; then
            if [ "$(major_of "$upstream")" = "$(major_of "$pinned")" ]; then
                echo "$tool $pinned $upstream"
            else
                echo "$tool $pinned $upstream majeure"
            fi
        fi
    done
}

# sha256 of file $1, with sha256sum (Linux) or shasum (macOS)
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{ print $1 }'
    else
        shasum -a 256 "$1" | awk '{ print $1 }'
    fi
}

# sha256 of the Go archive of version $1 for architecture $2, as listed by
# go.dev (empty if the index does not list it)
go_official_sha() {
    curl -fsSL "https://go.dev/dl/?mode=json&include=all" 2>/dev/null |
        jq -r --arg file "go$1.linux-$2.tar.gz" \
            '[.[] | .files[]? | select(.filename == $file) | .sha256][0] // empty'
}

# Downloads the archive of tool $1, version $2, architecture $3 into directory
# $4, checks it against the official sha256 when go.dev publishes one, and
# prints its sha256
archive_sha() {
    local tool="$1" version="$2" arch="$3" dir="$4" url file sha official
    url="$(tool_archive_url "$tool" "$version" "$arch")"
    file="$dir/$arch.archive"
    curl -fsSL "$url" -o "$file" 2>/dev/null || fail "archive not found: $url"
    sha="$(sha256_of "$file")"
    if [ "$tool" = go ]; then
        official="$(go_official_sha "$version" "$arch")" || official=""
        [ -n "$official" ] || fail "no official sha256 for $url on go.dev"
        [ "$official" = "$sha" ] ||
            fail "sha256 of $url ($sha) differs from the official one ($official)"
    fi
    printf '%s\n' "$sha"
}

# Sets the value of the single "ARG <var>=" line of file $1 to $3 (variable $2)
set_arg() {
    local file="$1" var="$2" value="$3" count
    count="$(grep -c "^ARG $var=" "$file" || true)"
    [ "$count" = 1 ] || fail "$var: expected one ARG line in the Dockerfile, found $count"
    awk -v prefix="ARG $var=" -v value="$value" '
        index($0, prefix) == 1 { print prefix value; next }
        { print }
    ' "$file" >"$file.next" && mv "$file.next" "$file"
}

# Sets the sha256 of variable $2 in file $1, on the line of its occurrence $3
# (counted from 1), to $4
set_sha() {
    local file="$1" var="$2" occurrence="$3" hex="$4" line
    line="$(grep -nE "(^|[^A-Za-z0-9_])${var}=[0-9a-f]{64}([^0-9a-f]|\$)" "$file" |
        sed -n "${occurrence}p" | cut -d: -f1)" || line=""
    [ -n "$line" ] || fail "$var: sha256 line not found in the Dockerfile"
    awk -v n="$line" -v var="$var" -v hex="$hex" '
        NR == n { sub(var "=[0-9a-f]+", var "=" hex) }
        { print }
    ' "$file" >"$file.next" && mv "$file.next" "$file"
}

# Replaces the version and both sha256 fingerprints of tool $1 with version $2
# in the Dockerfile, nothing else. Refused: an archive that cannot be fetched,
# a go.dev checksum that differs, a major version other than the pinned one
# unless $3 is --major
apply_tool() {
    local tool="$1" version="${2:-}" option="${3:-}" pinned sha_amd64 sha_arm64
    case "$version" in
        "" | *[!0-9A-Za-z.+-]*) fail "invalid version: ${version:-(none)}" ;;
    esac
    case "$option" in
        "" | --major) ;;
        *)
            echo "usage: bash manage/scripts/ci/versions.sh --apply <tool> <version> [--major]" >&2
            exit 2
            ;;
    esac
    pinned="$(tool_pinned "$tool")"
    [ -n "$pinned" ] || fail "no pinned version of $tool in the Dockerfile"
    if [ "$(major_of "$version")" != "$(major_of "$pinned")" ] && [ "$option" != --major ]; then
        fail "$tool $version is a major version (pinned $pinned): refused without --major"
    fi
    # Global on purpose: the EXIT trap runs after this function has returned
    TOOLS_WORK="$(mktemp -d)"
    trap 'rm -rf "$TOOLS_WORK"' EXIT
    sha_amd64="$(archive_sha "$tool" "$version" amd64 "$TOOLS_WORK")" || exit 1
    sha_arm64="$(archive_sha "$tool" "$version" arm64 "$TOOLS_WORK")" || exit 1
    cp "$DOCKERFILE" "$TOOLS_WORK/new"
    set_arg "$TOOLS_WORK/new" "$(tool_version_var "$tool")" "$version"
    set_sha "$TOOLS_WORK/new" "$(tool_sha_var "$tool" arm64)" 1 "$sha_arm64"
    set_sha "$TOOLS_WORK/new" "$(tool_sha_var "$tool" amd64)" "$(tool_sha_occurrence "$tool" amd64)" "$sha_amd64"
    # Written back into the existing file: its permissions are kept
    cat "$TOOLS_WORK/new" >"$DOCKERFILE"
}
