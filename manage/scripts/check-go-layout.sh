#!/usr/bin/env bash
# CI check: every Go file has at most 250 lines, tests included (#710). A file
# that grows beyond it is split into a folder of smaller files, by
# responsibility. Checked: the Go files tracked by git, plus the new ones not
# ignored (git ls-files --cached --others --exclude-standard), so the Go
# projects checked out under workspace/ are never counted. A file too long is
# printed as "path: N lines (max 250)" and the run exits 1; otherwise it prints
# "go layout: N files ok" and exits 0. bash 3.2 (macOS).

set -u

ICI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$ICI/../.." && pwd)"
MAX=250

if ! files="$(git -C "$ROOT" ls-files --cached --others --exclude-standard -- '*.go')"; then
    echo "check-go-layout: git ls-files fails in $ROOT" >&2
    exit 1
fi

fails=0
count=0
while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$ROOT/$f" ] || continue
    count=$((count + 1))
    # awk counts the last line too, even without a final newline
    lines="$(awk 'END { print NR }' "$ROOT/$f")"
    if [ "$lines" -gt "$MAX" ]; then
        printf '%s: %s lines (max %s)\n' "$f" "$lines" "$MAX"
        fails=1
    fi
done <<LISTE
$files
LISTE

if [ "$fails" -ne 0 ]; then
    exit 1
fi
echo "go layout: $count files ok"
