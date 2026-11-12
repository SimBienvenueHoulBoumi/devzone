#!/usr/bin/env bash
# Prints the bats files of one CI shard (#522), one per line:
#   bash manage/test/shard.sh <index> <total>
# Why: running every manage/test/*.bats file in one ubuntu job went past its
# timeout as the suite grew. Files are sorted by name, then dealt in turn
# (file i goes to shard ((i - 1) % total) + 1), so a shard is stable from one
# run to the next and the shards stay about the same size.
# Portable: bash 3.2 (macOS) and Linux.
set -euo pipefail

usage() {
    echo "usage: bash manage/test/shard.sh <index> <total> (1 <= index <= total)" >&2
    exit 2
}

index="${1:-}"
total="${2:-}"
case "$index$total" in
    '' | *[!0-9]*) usage ;;
esac
[ "$total" -ge 1 ] && [ "$index" -ge 1 ] && [ "$index" -le "$total" ] || usage

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
i=0
for file in $(cd "$here" && LC_ALL=C ls -1 -- *.bats); do
    if [ $((i % total + 1)) -eq "$index" ]; then
        echo "manage/test/$file"
    fi
    i=$((i + 1))
done
