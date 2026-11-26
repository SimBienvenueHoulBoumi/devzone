#!/usr/bin/env bash
# Tests de la CLI de devzone dans un vrai terminal (pseudo-terminal), comme un
# humain : chaque commande a un délai maximal ; une commande qui attend une
# entrée au lieu de finir échoue (« attend une entrée »). Ticket #109.
#   make test-cli     (ou bash manage/test/cli-terminal.sh)
# Couvre, sans cluster ni conteneur (#735, le poste Docker est retiré) : aide
# de make, commande npm (manage/devzone --version, --help, uninstall hors d'un
# dossier devzone, --docker refusé, dossier non vide refusé).
# Les scénarios qui créaient et lançaient un conteneur sont retirés : la
# création exige désormais un cluster Kubernetes.
# Prérequis : Node, Python 3, make. Durée : moins d'une minute.
set -uo pipefail

RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=SCRIPTDIR/journal-error.sh
. "$(dirname "${BASH_SOURCE[0]}")/journal-error.sh"
export DEVZONE_VOLUMES="devzone-test-cli-$$"
# Désinstallation : aucun cluster de l'hôte examiné
export KUBECONFIG=/nexiste/pas
# Chemin physique : make (CURDIR) voit /private/var/… sous macOS, pas /var/…
TMP="$(cd "$(mktemp -d)" && pwd -P)"
# Nommé autrement que « devzone » (npx devzone <dossier>)
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
# humain <nom> <délai s> <code attendu> <motif attendu dans la sortie, ou "">
#        [--envoyer MOTIF TEXTE]... -- commande…
# Lance la commande sous terminal ; SORTIE garde sa sortie (sans couleurs)
humain() {
    local nom="$1" delai="$2" attendu="$3" motif="$4" code
    shift 4
    SORTIE="$("${TERMINAL[@]}" "$delai" "$@" 2>&1)"
    code=$?
    SORTIE="$(printf '%s\n' "$SORTIE" | sed "s/${ESC}\[[0-9;?]*[A-Za-z]//g" | tr -d '\r')"
    if [ "$code" -eq 124 ]; then
        ko "$nom : attend une entrée (délai de $delai s dépassé)" "$SORTIE"
    elif [ "$code" -eq "$attendu" ] && { [ -z "$motif" ] || grep -qE -- "$motif" <<<"$SORTIE"; }; then
        ok "$nom"
    else
        ko "$nom (code $code, attendu $attendu ; motif : $motif)" "$SORTIE"
    fi
}
# Cible make lancée dans le dossier du devzone
mk() {
    local nom="$1" delai="$2" attendu="$3" motif="$4"
    shift 4
    humain "make $nom" "$delai" "$attendu" "$motif" "$@" -- make -C "$COPIE" "$nom"
}
# verifier <nom> commande… : réussi si la commande réussit (sinon SORTIE affichée)
verifier() {
    local nom="$1"
    shift
    if "$@"; then ok "$nom"; else ko "$nom" "$SORTIE"; fi
}

echo "▶ Sans conteneur (volumes $DEVZONE_VOLUMES-*)"
humain "make help" 30 0 "make uninstall" -- make -C "$RACINE" help
humain "devzone --version" 30 0 "^$(node -p "require('$RACINE/package.json').version")$" -- bash "$RACINE/manage/devzone" --version
humain "devzone --help" 30 0 "devzone <folder>" -- bash "$RACINE/manage/devzone" --help
cd "$TMP" || exit 1
humain "devzone uninstall hors d'un dossier devzone : refusé" 30 1 "dossier devzone" -- bash "$RACINE/manage/devzone" uninstall
humain "devzone <dossier> --docker : option retirée, refusée" 30 1 "option inconnue : --docker" -- bash "$RACINE/manage/devzone" "$TMP/mon-devzone" --docker
verifier "--docker : dossier non créé" test ! -e "$TMP/mon-devzone"
mkdir -p "$TMP/plein"
echo important >"$TMP/plein/fichier"
humain "devzone <dossier> : dossier non vide refusé" 30 1 "pas vide" -- bash "$RACINE/manage/devzone" "$TMP/plein"
verifier "fichier existant préservé" grep -qx important "$TMP/plein/fichier"

echo
echo "Résultat : $reussis réussi(s), $failures échec(s)"
[ "$failures" -eq 0 ]
