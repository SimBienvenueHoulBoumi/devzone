#!/usr/bin/env bash
# Tests bats sous bash 3.2 (#211) : le job macOS du workflow les lance dans le
# conteneur bash:3.2, bats installé ; ce script le fait à la main, ou via la
# commande devzone test-bash32, avec la même liste que le job macOS.
#   bash core/test/bash32.sh
#       les tests bats du job macOS, tels que le job macOS les lance
#   devzone test-bash32
#       même lancement, par la commande devzone
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
    if [[ "$line" == *"npx --yes bats@"* && "$line" == *"core/test/cli.bats"* ]]; then
        MACOS_LINE="$line"
        BATS_VERSION="$(grep -oE 'bats@[0-9]+\.[0-9]+\.[0-9]+' <<<"$MACOS_LINE")"
        BATS_VERSION="${BATS_VERSION#bats@}"
        break
    fi
done < "$WORKFLOW"

MATCHES="$(grep -oE 'core/test/[A-Za-z0-9_.-]+\.bats' <<<"$MACOS_LINE")"
LISTE="${MATCHES//$'\n'/ }"
LISTE="${LISTE% }"

if [ -z "$LISTE" ]; then
    echo "Aucun test bats trouvé dans le job macOS" >&2
    exit 2
fi

if [ -z "$BATS_VERSION" ]; then
    echo "Version de bats non trouvée dans le job macOS" >&2
    exit 2
fi

# Docker requis
if ! command -v docker >/dev/null 2>&1; then
    echo "Docker requis" >&2
    exit 2
fi

# Version affichée
docker run --rm -v "$RACINE:/w" -w /w -e LC_ALL=C.UTF-8 -e LANG=C.UTF-8 bash:3.2 sh -c 'bash --version | head -1'

# Exécution des tests bats dans le conteneur
# shellcheck disable=SC2086
# bats 1.12 sous bash 3.2 ne retrouve pas les noms accentués et node manque (cf #211)
docker run --rm -v "$RACINE:/w" -w /w -e LC_ALL=C.UTF-8 -e LANG=C.UTF-8 bash:3.2 sh -c 'apk add --no-cache git jq nodejs >/dev/null && bash -c "[ \"\${BASH_VERSINFO[0]}\" = 3 ]" && git clone -q --depth 1 --branch v'"$BATS_VERSION"' https://github.com/bats-core/bats-core /tmp/bats && /tmp/bats/bin/bats '"$LISTE"
rc=$?

exit "$rc"
