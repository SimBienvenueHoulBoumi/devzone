#!/usr/bin/env bash
# Tests Windows et local (macOS/Linux) : fins de ligne, paquet npm installé en
# global dans un préfixe isolé sous $TMP (jamais celui de la machine), puis
# comportement de la commande devzone — sans conteneur, donc sans Docker ni make.
#   bash test/windows.sh     (en local, et dans le job windows de la CI)
# Style identique à test/fonctionnel.sh (✔/✖, compteurs).
set -euo pipefail

RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(cd "$(mktemp -d)" && pwd -P)"
TESTDIR="$TMP/testdz"
# Chemin passé en argument à node, jamais écrit dans le code JavaScript de -p :
# sous Git Bash $RACINE vaut /d/a/… et seul un argument séparé est reconverti
# pour un programme Windows
VERSION="$(node -p 'require(process.argv[1]).version' "$RACINE/package.json")"
# Préfixe npm isolé sous $TMP : la commande testée s'y installe en global sans
# toucher à celui de la machine ; sous Windows les exécutables globaux sont à la
# racine du préfixe, d'où les deux chemins ajoutés au PATH
export npm_config_prefix="$TMP/npm"
export PATH="$TMP/npm/bin:$TMP/npm:$PATH"
reussis=0
echecs=0

nettoyer() {
    rm -rf "$TMP"
}
trap nettoyer EXIT

ok() { reussis=$((reussis + 1)); echo "  ✔ $1"; }
ko() { echecs=$((echecs + 1)); echo "  ✖ $1"; printf '%s\n' "$2" | tail -5 | sed 's/^/      /'; }

# Commande tapée par un utilisateur (bash de Git Bash, PATH réelle) ; les \r
# sont retirés pour que les motifs tiennent sous Windows
bz() { bash -c "$1" 2>&1 | tr -d '\r'; }

# reussit <nom> <commande> [motif attendu dans la sortie]
reussit() {
    local sortie
    if sortie="$(bz "$2")" && { [ -z "${3:-}" ] || grep -qE -- "$3" <<<"$sortie"; }; then ok "$1"; else ko "$1" "$sortie"; fi
}
# echoue <nom> <commande> [motif attendu dans la sortie]
echoue() {
    local sortie
    if ! sortie="$(bz "$2")" && { [ -z "${3:-}" ] || grep -qE -- "$3" <<<"$sortie"; }; then ok "$1"; else ko "$1" "$sortie"; fi
}

# Même critère que la garde « scripts en LF » de test/cli.bats : tout fichier
# suivi commençant par #!, plus Makefile
echo "▶ Fins de ligne (aucun CRLF dans les scripts)"
for f in $(cd "$RACINE" && git ls-files); do
    if head -c 2 "$RACINE/$f" 2>/dev/null | grep -q '^#!' || [ "$f" = Makefile ]; then
        if grep -q $'\r' "$RACINE/$f"; then ko "pas de CRLF dans $f" "$(head -c 40 "$RACINE/$f" | od -An -tx1 | head -1)"; else ok "pas de CRLF dans $f"; fi
    fi
done

echo "▶ Paquet npm : npm pack puis installation globale de l'archive"
(cd "$RACINE" && npm pack --silent --pack-destination "$TMP" >/dev/null)
ARCHIVE=""
for a in "$TMP"/devzone-*.tgz; do
    if [ -f "$a" ]; then ARCHIVE="$a"; fi
done
if [ -n "$ARCHIVE" ]; then ok "npm pack : archive créée"; else ko "npm pack : archive créée" "$(ls "$TMP")"; fi
reussit "npm install -g de l'archive" "npm install -g --no-audit --no-fund '$ARCHIVE'"

echo "▶ devzone --version, --help, option inconnue"
reussit "devzone --version : la version de package.json" "devzone --version" "^$VERSION$"
reussit "devzone --help : l'aide" "devzone --help" "devzone <dossier>"
echoue "devzone --option-inconnue : sortie en erreur" "devzone --option-inconnue" "option inconnue"

echo "▶ devzone <dossier> avec DEVZONE_SANS_DEMARRER=1"
reussit "crée un devzone complet" "DEVZONE_SANS_DEMARRER=1 devzone '$TESTDIR'" "créé dans"
for f in .devcontainer/devcontainer.json .devcontainer/devzone Makefile .gitattributes lancer.sh desinstaller.sh README.md LICENSE workspace/.gitkeep .gitignore; do
    reussit "existe : $f" "[ -e '$TESTDIR/$f' ]"
done
reussit ".gitignore : workspace ignoré sauf .gitkeep" "grep -q '^workspace/\\*\$' '$TESTDIR/.gitignore'"

echo "▶ Dossier non vide refusé, rien n'est écrasé"
mkdir -p "$TMP/plein"
echo important >"$TMP/plein/fichier"
echoue "dossier non vide refusé" "DEVZONE_SANS_DEMARRER=1 devzone '$TMP/plein'" "pas vide"
reussit "fichier existant préservé" "[ \"\$(cat '$TMP/plein/fichier')\" = important ]"
reussit "Makefile non créé" "[ ! -e '$TMP/plein/Makefile' ]"

echo "▶ devzone desinstaller hors d'un dossier devzone"
echoue "desinstaller refusé hors devzone" "cd '$TMP' && devzone desinstaller" "dossier devzone"

echo
echo "Résultat : $reussis réussi(s), $echecs échec(s)"
[ "$echecs" -eq 0 ]
