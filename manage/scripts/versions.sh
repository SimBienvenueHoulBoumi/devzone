#!/usr/bin/env bash
# Pinned container versions: compares repowarden (versions.env) and AI
# assistants (IA_… lines, devzone) to the latest npm version, or applies an
# upgrade.
#   bash manage/scripts/versions.sh
#       one "package old new" line per outdated package, nothing otherwise
#   bash manage/scripts/versions.sh --installed
#       one "package pinned installed" line per installed tool behind its pin
#   bash manage/scripts/versions.sh --apply <package> <version>
#       replaces that pinned version in its file, nothing else
#   bash manage/scripts/versions.sh --existing-ticket <package> <author>
#       "number<TAB>title" of the open ticket by <author>, nothing otherwise
# Compatible with bash 3.2 (macOS).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSIONS_ENV="$HERE/.devcontainer/versions.env"
DEVZONE="$HERE/.devcontainer/devzone"

# List "package version" of pinned versions in both files; in devzone, one
# IA_<NAME>=<package>@<version> line per AI assistant
pinned() {
    local item
    if [ -f "$VERSIONS_ENV" ]; then
        # shellcheck disable=SC1090
        . "$VERSIONS_ENV"
        [ -z "${REPOWARDEN_VERSION:-}" ] || echo "repowarden $REPOWARDEN_VERSION"
    fi
    while read -r item; do
        case "$item" in
            ?*@*) echo "${item%@*} ${item##*@}" ;;
        esac
    done < <(sed -nE 's/^IA_[A-Z0-9_]+=([^[:space:]()"]+)$/\1/p' "$DEVZONE")
}

# True if version $1 is newer than $2 (numeric components)
newer() {
    local i x y
    local IFS=.
    local a b
    read -ra a <<<"$1"
    read -ra b <<<"$2"
    for i in 0 1 2 3; do
        x="${a[i]:-0}"
        y="${b[i]:-0}"
        x="${x%%[!0-9]*}"
        y="${y%%[!0-9]*}"
        x="${x:-0}"
        y="${y:-0}"
        [ "$x" -gt "$y" ] && return 0
        [ "$x" -lt "$y" ] && return 1
    done
    return 1
}

# Latest version published on npm (empty if npm does not respond)
latest() {
    npm view "$1" version 2>/dev/null | tail -1 | tr -d '[:space:]'
}

# One line per outdated package, nothing if everything is up to date
list_outdated() {
    local package old new
    while read -r package old; do
        [ -n "$package" ] || continue
        new="$(latest "$package")"
        if [ -z "$new" ]; then
            echo "versions: cannot read npm version for $package" >&2
            exit 1
        fi
        if newer "$new" "$old"; then
            echo "$package $old $new"
        fi
    done < <(pinned)
}

# Globally installed versions (package version), read once;
# fails if npm or jq does not respond (state then omits the line)
installed_packages() {
    local json
    json="$(npm ls -g --depth=0 --json 2>/dev/null || true)"
    [ -n "$json" ] || return 1
    printf '%s\n' "$json" | jq -r '.dependencies // {} | to_entries[] | "\(.key) \(.value.version)"'
}

# One "package pinned installed" line per installed tool whose version differs
# from the pinned version; a tool not installed is not listed
compare_installed() {
    local package pin installed list
    list="$(installed_packages)"
    while read -r package pin; do
        [ -n "$package" ] || continue
        installed="$(printf '%s\n' "$list" | awk -v p="$package" '$1 == p { print $2; exit }')"
        [ -n "$installed" ] || continue
        [ "$installed" = "$pin" ] || echo "$package $pin $installed"
    done < <(pinned)
}

# Prints "number<TAB>title" of the open ticket by $2 whose title starts with
# "$1", nothing otherwise: a ticket with the same title opened by someone else is ignored.
existing_ticket() {
    local package="$1" author="$2" tickets number title ticket_author
    tickets="$(gh issue list --state open --limit 200 --json number,title,author \
        --jq '.[] | "\(.number)\t\(.title)\t\(.author.login)"')"
    while IFS=$'\t' read -r number title ticket_author; do
        [ -n "$number" ] || continue
        case "$title" in
            "$package "*) ;;
            *) continue ;;
        esac
        [ "$ticket_author" = "$author" ] || continue
        printf '%s\t%s\n' "$number" "$title"
        return 0
    done <<<"$tickets"
}

# Escapes $1 for a sed pattern (delimiter is "|")
escape_sed() {
    printf '%s' "$1" | sed "s/[][\\\\.*^$()+?{}|]/\\\\&/g"
}

# Replaces the single pinned version of $1 with $2 in its file. Content is
# written back into the existing file (no mv): its permissions, including the
# execute bit on devzone, are preserved.
apply() {
    local package="$1" version="$2" pattern tmp file
    case "$version" in
        "" | *[!0-9A-Za-z.+-]*)
            echo "versions: invalid version: ${version:-(none)}" >&2
            exit 1
            ;;
    esac
    if [ "$package" = repowarden ]; then
        file="$VERSIONS_ENV"
        grep -qE '^REPOWARDEN_VERSION=' "$file" ||
            { echo "versions: unknown package: $package" >&2; exit 1; }
        tmp="$(mktemp)"
        sed -E "s|^(REPOWARDEN_VERSION=)[^[:space:]]+$|\1${version}|" "$file" >"$tmp"
    else
        file="$DEVZONE"
        pinned | awk -v p="$package" '$1 == p { found = 1 } END { exit found ? 0 : 1 }' ||
            { echo "versions: unknown package: $package" >&2; exit 1; }
        pattern="$(escape_sed "$package")"
        tmp="$(mktemp)"
        sed -E "s|^(IA_[A-Z0-9_]+=${pattern}@)[^[:space:]]+$|\1${version}|" "$file" >"$tmp"
    fi
    cat "$tmp" >"$file"
    rm -f "$tmp"
}

case "${1:-}" in
    "") list_outdated ;;
    --installed | --installees) compare_installed ;;
    --apply | --appliquer)
        [ "$#" -eq 3 ] ||
            { echo "usage: bash manage/scripts/versions.sh [--installed | --apply <package> <version> | --existing-ticket <package> <author>]" >&2; exit 2; }
        apply "$2" "$3"
        ;;
    --existing-ticket | --ticket-existant)
        [ "$#" -eq 3 ] ||
            { echo "usage: bash manage/scripts/versions.sh [--installed | --apply <package> <version> | --existing-ticket <package> <author>]" >&2; exit 2; }
        existing_ticket "$2" "$3"
        ;;
    -h | --help) sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
    *)
        echo "usage: bash manage/scripts/versions.sh [--installed | --apply <package> <version> | --existing-ticket <package> <author>]" >&2
        exit 2
        ;;
esac
