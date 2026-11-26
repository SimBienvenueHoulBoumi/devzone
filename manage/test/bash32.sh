#!/usr/bin/env bash
# bats tests under bash 3.2 (#211): the macOS workflow job runs them in the
# bash:3.2 image with bats installed; this script does it by hand, or through the
# devzone test-bash32 command, with the same list as the macOS job.
#   bash manage/test/bash32.sh
#       the bats tests of the macOS job, as the macOS job runs them
#   devzone test-bash32
#       same run, through the devzone command
# Compatible bash 3.2 (macOS).

src="${BASH_SOURCE[0]}"
if [[ "$src" == */* ]]; then
    dir="${src%/*}"
else
    dir="."
fi
SCRIPT_DIR="$(cd "$dir" && pwd)"
RACINE="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKFLOW="$RACINE/.github/workflows/fonctionnel.yml"

# Version de bats du job macOS (bats@X.Y.Z)
MACOS_LINE=""
BATS_VERSION=""
while IFS= read -r line; do
    if [[ "$line" == *"npx --yes bats@"* && "$line" == *"manage/test/cli.bats"* ]]; then
        MACOS_LINE="$line"
        BATS_VERSION="$(grep -oE 'bats@[0-9]+\.[0-9]+\.[0-9]+' <<<"$MACOS_LINE")"
        BATS_VERSION="${BATS_VERSION#bats@}"
        break
    fi
done < "$WORKFLOW"

MATCHES="$(grep -oE 'manage/test/[A-Za-z0-9_.-]+\.bats' <<<"$MACOS_LINE")"
LISTE="${MATCHES//$'\n'/ }"
LISTE="${LISTE% }"

if [ -z "$LISTE" ]; then
    echo "No bats test found in the macOS job" >&2
    exit 2
fi

if [ -z "$BATS_VERSION" ]; then
    echo "bats version not found in the macOS job" >&2
    exit 2
fi

# Docker requis
if ! command -v docker >/dev/null 2>&1; then
    echo "Docker requis" >&2
    exit 2
fi

# Version printed
docker run --rm -v "$RACINE:/w" -w /w -e LC_ALL=C.UTF-8 -e LANG=C.UTF-8 bash:3.2 sh -c 'bash --version | head -1'

# Running the bats tests in the bash 3.2 image
# shellcheck disable=SC2086
# bats 1.12 under bash 3.2 does not find accented names and node is missing (see #211)
docker run --rm -v "$RACINE:/w" -w /w -e LC_ALL=C.UTF-8 -e LANG=C.UTF-8 bash:3.2 sh -c 'apk add --no-cache git jq nodejs >/dev/null && bash -c "[ \"\${BASH_VERSINFO[0]}\" = 3 ]" && git clone -q --depth 1 --branch v'"$BATS_VERSION"' https://github.com/bats-core/bats-core /tmp/bats && /tmp/bats/bin/bats '"$LISTE"
rc=$?

exit "$rc"
