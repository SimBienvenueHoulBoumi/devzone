#!/usr/bin/env bash
# Tests of the devzone CLI in a real terminal (pseudo-terminal), like a
# human: each command has a maximum delay; a command waiting for input
# instead of ending fails ("waiting for input"). Ticket #109.
#   make test-cli     (or bash manage/test/cli-terminal.sh)
# Covers, without a cluster or host container mode (#735): make help, the npm
# command (manage/devzone --version, --help, uninstall outside a devzone folder,
# removed option refused, non-empty folder refused).
# Scenarios that created and started a container are gone: creating a devzone
# now requires a Kubernetes cluster.
# Prerequisites: Node, Python 3, make. Duration: under a minute.
set -uo pipefail

RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REMOVED_OPTION="$(cat "$RACINE/manage/test/removed-option.txt")"
# shellcheck source=SCRIPTDIR/journal-error.sh
. "$(dirname "${BASH_SOURCE[0]}")/journal-error.sh"
export DEVZONE_VOLUMES="devzone-test-cli-$$"
# Uninstall: no host cluster inspected
export KUBECONFIG=/nexiste/pas
# Chemin physique : make (CURDIR) voit /private/var/… sous macOS, pas /var/…
TMP="$(cd "$(mktemp -d)" && pwd -P)"
# Named differently from "devzone" (npx devzone <folder>)
COPIE="$TMP/mon-devzone-cli"
TERMINAL=(python3 -I "$RACINE/manage/test/terminal.py")
reussis=0
failures=0

nettoyer() {
    rm -rf "$TMP"
}
trap nettoyer EXIT

ok() { reussis=$((reussis + 1)); echo "  ✔ $1"; }
ko() {
    failures=$((failures + 1))
    echo "  ✖ $1"
    printf '%s\n' "$2" | tail -8 | sed 's/^/      /'
    # make up failure names its full log: show its error lines and tail too
    local journal
    journal="$(printf '%s\n' "$2" | sed -n 's/.*[Ff]ull log: \([^[:space:]]*\).*/\1/p' | tail -1)"
    [ -n "$journal" ] || return 0
    case "$journal" in
        /*) ;;
        *) journal="$COPIE/$journal" ;;
    esac
    print_log_errors "$journal"
    return 0
}

ESC="$(printf '\033')"
# human <name> <delay s> <expected code> <expected pattern in output, or "">
#        [--send PATTERN TEXT]... -- command...
# Runs the command in a terminal; SORTIE keeps its output (without colors)
humain() {
    local nom="$1" delai="$2" attendu="$3" motif="$4" code
    shift 4
    SORTIE="$("${TERMINAL[@]}" "$delai" "$@" 2>&1)"
    code=$?
    SORTIE="$(printf '%s\n' "$SORTIE" | sed "s/${ESC}\[[0-9;?]*[A-Za-z]//g" | tr -d '\r')"
    if [ "$code" -eq 124 ]; then
        ko "$nom: waiting for input (delay of $delai s exceeded)" "$SORTIE"
    elif [ "$code" -eq "$attendu" ] && { [ -z "$motif" ] || grep -qE -- "$motif" <<<"$SORTIE"; }; then
        ok "$nom"
    else
        ko "$nom (code $code, expected $attendu; pattern: $motif)" "$SORTIE"
    fi
}
# Make target run in the devzone folder
mk() {
    local nom="$1" delai="$2" attendu="$3" motif="$4"
    shift 4
    humain "make $nom" "$delai" "$attendu" "$motif" "$@" -- make -C "$COPIE" "$nom"
}
# verify <name> command...: succeeds if the command succeeds (else SORTIE is printed)
verifier() {
    local nom="$1"
    shift
    if "$@"; then ok "$nom"; else ko "$nom" "$SORTIE"; fi
}

echo "▶ Without a host container mode (volumes $DEVZONE_VOLUMES-*)"
humain "make help" 30 0 "make uninstall" -- make -C "$RACINE" help
humain "devzone --version" 30 0 "^$(node -p "require('$RACINE/package.json').version")$" -- bash "$RACINE/manage/devzone" --version
humain "devzone --help" 30 0 "devzone <folder>" -- bash "$RACINE/manage/devzone" --help
cd "$TMP" || exit 1
humain "devzone uninstall outside a devzone folder: refused" 30 1 "devzone folder" -- bash "$RACINE/manage/devzone" uninstall
humain "devzone <folder> removed option: refused" 30 1 "unknown option: $REMOVED_OPTION" -- bash "$RACINE/manage/devzone" "$TMP/mon-devzone" "$REMOVED_OPTION"
verifier "$REMOVED_OPTION: folder not created" test ! -e "$TMP/mon-devzone"
mkdir -p "$TMP/plein"
echo important >"$TMP/plein/file"
humain "devzone <folder>: non-empty folder refused" 30 1 "not empty" -- bash "$RACINE/manage/devzone" "$TMP/plein"
verifier "existing file preserved" grep -qx important "$TMP/plein/file"

echo
echo "Result: $reussis passed, $failures failed"
[ "$failures" -eq 0 ]
