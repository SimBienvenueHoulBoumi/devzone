#!/usr/bin/env bash
# Plan of the image tools to bump, for the versions workflow. Reads the
# "tool pinned upstream [majeure]" lines of "versions.sh --tools" on stdin and
# prints one TAB-separated line per tool to act on, with the fields:
#   kind  tool  pinned  upstream  title  notes  ticket
#   plan       a new ticket, the design, the bump and the push; at most MAX
#              (3 by default) per run, the others wait for the next run
#   existant   the App has an open ticket for this tool with another title:
#              the workflow only updates it (no branch); ticket is its number
#   majeure    a next major version: listed in the job summary, never applied
# A tool whose open ticket of the author has the same title is not listed.
# Usage: versions.sh --tools | bash versions-tools-plan.sh <author> [max]
# Compatible with bash 3.2 (macOS).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTHOR="${1:-}"
MAX="${2:-3}"

if [ -z "$AUTHOR" ]; then
    echo "usage: versions.sh --tools | bash versions-tools-plan.sh <author> [max]" >&2
    exit 2
fi
case "$MAX" in
    '' | *[!0-9]*)
        echo "versions-tools-plan: invalid max: $MAX" >&2
        exit 2
        ;;
esac

# Release notes of tool $1 at version $2 (Go publishes its notes on go.dev)
notes_of() {
    case "$1" in
        go) echo "https://go.dev/doc/devel/release#go$2" ;;
        k9s) echo "https://github.com/derailed/k9s/releases/tag/v$2" ;;
        actionlint) echo "https://github.com/rhysd/actionlint/releases/tag/v$2" ;;
        gitleaks) echo "https://github.com/gitleaks/gitleaks/releases/tag/v$2" ;;
        kind) echo "https://github.com/kubernetes-sigs/kind/releases/tag/v$2" ;;
        *)
            echo "versions-tools-plan: unknown tool: $1" >&2
            exit 1
            ;;
    esac
}

# Title of the ticket and of the commit for the bump of tool $1 from $2 to $3
title_of() {
    echo "$1 $2 → $3 in the image"
}

# "number<TAB>title" of the open ticket of AUTHOR for tool $1, nothing otherwise
open_ticket_of() {
    bash "$HERE/versions.sh" --existing-ticket "$1" "$AUTHOR" </dev/null
}

# Prints one plan line: kind, tool, pinned, upstream, title, notes, ticket
emit() {
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "${7:--}"
}

count=0
deferred=""
while read -r tool pinned upstream rest; do
    [ -n "${tool:-}" ] || continue
    if [ -z "${upstream:-}" ]; then
        echo "versions-tools-plan: invalid line: $tool $pinned" >&2
        exit 1
    fi
    case "$rest" in
        '') kind=plan ;;
        majeure) kind=majeure ;;
        *)
            echo "versions-tools-plan: invalid line: $tool $pinned $upstream $rest" >&2
            exit 1
            ;;
    esac
    title="$(title_of "$tool" "$pinned" "$upstream")"
    notes="$(notes_of "$tool" "$upstream")"

    if [ "$kind" = majeure ]; then
        emit majeure "$tool" "$pinned" "$upstream" "$title" "$notes"
        continue
    fi

    existing="$(open_ticket_of "$tool")"
    if [ -n "$existing" ]; then
        number="${existing%%$'\t'*}"
        existing_title="${existing#*$'\t'}"
        if [ "$existing_title" != "$title" ]; then
            emit existant "$tool" "$pinned" "$upstream" "$title" "$notes" "$number"
        fi
        continue
    fi

    if [ "$count" -ge "$MAX" ]; then
        deferred="$deferred $tool"
        continue
    fi
    count=$((count + 1))
    emit plan "$tool" "$pinned" "$upstream" "$title" "$notes"
done

if [ -n "$deferred" ]; then
    echo "versions-tools-plan: deferred to the next run (at most $MAX per run):$deferred" >&2
fi
