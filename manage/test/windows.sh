#!/usr/bin/env bash
# Windows and local tests (macOS/Linux): line endings, npm package installed
# globally in an isolated prefix under $TMP (never the machine one), then the
# behaviour of the devzone command — no host container mode, no image engine.
#   bash manage/test/windows.sh     (locally and in the CI windows job)
# Same style as manage/test/functional.sh (✔/✖, counters).
set -euo pipefail

RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(cd "$(mktemp -d)" && pwd -P)"
TESTDIR="$TMP/testdz"
# Path passed as an argument to node, never written in the JavaScript of -p:
# under Git Bash $RACINE is /d/a/… and only a separate argument is converted
# for a Windows program
VERSION="$(node -p 'require(process.argv[1]).version' "$RACINE/package.json")"
# Isolated npm prefix under $TMP: the tested command is installed there globally
# without touching the machine one; under Windows global executables are at the
# root of the prefix, hence the two paths added to PATH
export npm_config_prefix="$TMP/npm"
export PATH="$TMP/npm/bin:$TMP/npm:$PATH"
reussis=0
failures=0

nettoyer() {
    rm -rf "$TMP"
}
trap nettoyer EXIT

ok() { reussis=$((reussis + 1)); echo "  ✔ $1"; }
ko() { failures=$((failures + 1)); echo "  ✖ $1"; printf '%s\n' "$2" | tail -5 | sed 's/^/      /'; }

# Command typed by a user (Git Bash shell, real PATH); the \r characters are
# removed so the patterns work under Windows
bz() { bash -c "$1" 2>&1 | tr -d '\r'; }

# succeeds <name> <command> [expected pattern in the output]
reussit() {
    local sortie
    if sortie="$(bz "$2")" && { [ -z "${3:-}" ] || grep -qE -- "$3" <<<"$sortie"; }; then ok "$1"; else ko "$1" "$sortie"; fi
}
# fails <name> <command> [expected pattern in the output]
echoue() {
    local sortie
    if ! sortie="$(bz "$2")" && { [ -z "${3:-}" ] || grep -qE -- "$3" <<<"$sortie"; }; then ok "$1"; else ko "$1" "$sortie"; fi
}

# Same rule as the "LF scripts" guard of manage/test/cli.bats: every tracked
# file starting with #!, plus Makefile
echo "▶ Line endings (no CRLF in the scripts)"
for f in $(cd "$RACINE" && git ls-files); do
    if head -c 2 "$RACINE/$f" 2>/dev/null | grep -q '^#!' || [ "$f" = Makefile ]; then
        if grep -q $'\r' "$RACINE/$f"; then ko "no CRLF in $f" "$(head -c 40 "$RACINE/$f" | od -An -tx1 | head -1)"; else ok "no CRLF in $f"; fi
    fi
done

echo "▶ Paquet npm : npm pack puis installation globale de l'archive"
(cd "$RACINE" && npm pack --silent --pack-destination "$TMP" >/dev/null)
ARCHIVE=""
for a in "$TMP"/devzone-*.tgz; do
    if [ -f "$a" ]; then ARCHIVE="$a"; fi
done
if [ -n "$ARCHIVE" ]; then ok "npm pack: archive created"; else ko "npm pack: archive created" "$(ls "$TMP")"; fi
reussit "npm install -g of the archive" "npm install -g --no-audit --no-fund '$ARCHIVE'"

echo "▶ devzone --version, --help, option inconnue"
reussit "devzone --version: the package.json version" "devzone --version" "^$VERSION$"
reussit "devzone --help: the help" "devzone --help" "devzone <folder>"
echoue "devzone --option-inconnue: error output" "devzone --option-inconnue" "option inconnue"

echo "▶ devzone run through the npm .cmd shortcut (Windows path of the script)"
# Under cmd, the npm .cmd shortcut calls bash with the Windows path of the
# script (backslashes, drive letter): reproduced here from Git Bash by passing
# that same path to bash; skipped outside Windows (no cygpath)
if command -v cygpath >/dev/null 2>&1; then
    WINSCRIPT="$(cygpath -w "$TMP/npm/node_modules/devzone/manage/devzone")"
    reussit "Windows path: --version gives the version" "bash '$WINSCRIPT' --version" "^$VERSION$"
    reussit "Windows path: --help gives the help" "bash '$WINSCRIPT' --help" "devzone <folder>"
else
    echo "  ○ skipped (outside Windows: no cygpath)"
fi

REMOVED_OPTION="$(cat "$RACINE/manage/test/removed-option.txt")"
echo "▶ removed image option (#735): refused as an unknown option, nothing created"
echoue "removed option refused as unknown" "DEVZONE_NO_START=1 devzone '$TESTDIR' $REMOVED_OPTION" "unknown option: $REMOVED_OPTION"
reussit "folder not created" "[ ! -e '$TESTDIR' ]"

echo "▶ Non-empty folder refused, nothing overwritten"
mkdir -p "$TMP/plein"
echo important >"$TMP/plein/file"
echoue "non-empty folder refused" "DEVZONE_NO_START=1 devzone '$TMP/plein'" "not empty"
reussit "existing file preserved" "[ \"\$(cat '$TMP/plein/file')\" = important ]"
reussit "Makefile not created" "[ ! -e '$TMP/plein/Makefile' ]"

echo "▶ devzone uninstall outside a devzone folder"
echoue "uninstall refused outside devzone" "cd '$TMP' && devzone uninstall" "Not a devzone folder"

echo
echo "Result: $reussis passed, $failures failed"
[ "$failures" -eq 0 ]
