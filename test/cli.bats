#!/usr/bin/env bats
# Commande devzone de l'hôte (paquet npm, bin/devzone) et contenu du paquet.

setup() {
    RACINE="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    CLI="$RACINE/bin/devzone"
    export DEVZONE_SANS_DEMARRER=1
    cd "$BATS_TEST_TMPDIR"
}

@test "devzone <dossier> : crée un devzone complet dans un dossier neuf" {
    run bash "$CLI" mon-devzone
    [ "$status" -eq 0 ]
    [[ "$output" == *"créé dans"* ]]
    for f in .devcontainer/devcontainer.json .devcontainer/devzone Makefile .gitattributes desinstaller.sh README.md LICENSE workspace/.gitkeep .gitignore; do
        [ -e "mon-devzone/$f" ] || { echo "manquant : $f"; return 1; }
    done
    [ -x mon-devzone/desinstaller.sh ]
    grep -q '^workspace/\*$' mon-devzone/.gitignore
}

@test "devzone <dossier> : n'embarque ni bin/, ni tests, ni CI, ni réglages du dépôt" {
    bash "$CLI" mon-devzone
    for f in bin test .github .repowarden.conf package.json .devzone.log; do
        [ ! -e "mon-devzone/$f" ] || { echo "en trop : $f"; return 1; }
    done
}

@test "devzone <dossier> : dossier existant vide accepté" {
    mkdir vide
    run bash "$CLI" vide
    [ "$status" -eq 0 ]
    [ -f vide/Makefile ]
}

@test "devzone <dossier> : dossier non vide refusé, rien n'est écrasé" {
    mkdir plein && echo important >plein/fichier
    run bash "$CLI" plein
    [ "$status" -eq 1 ]
    [[ "$output" == *"pas vide"* ]]
    [ "$(cat plein/fichier)" = important ]
    [ ! -e plein/Makefile ]
}

@test "devzone desinstaller : refusé hors d'un dossier devzone" {
    run bash "$CLI" desinstaller
    [ "$status" -eq 1 ]
    [[ "$output" == *"dossier devzone"* ]]
}

@test "devzone --version et --help" {
    run bash "$CLI" --version
    [ "$status" -eq 0 ]
    [ "$output" = "$(node -p "require('$RACINE/package.json').version")" ]
    run bash "$CLI" --help
    [[ "$output" == *"devzone <dossier>"* ]]
    run bash "$CLI" --truc
    [ "$status" -eq 1 ]
}

@test "paquet npm : contenu attendu, aucun fichier local ni de développement" {
    command -v npm >/dev/null || skip "npm absent"
    fichiers="$(cd "$RACINE" && npm pack --dry-run --json 2>/dev/null | node -e 'for (const f of JSON.parse(require("fs").readFileSync(0))[0].files) console.log(f.path)')"
    for f in bin/devzone .devcontainer/devcontainer.json .devcontainer/devzone Makefile desinstaller.sh README.md LICENSE package.json; do
        grep -qx "$f" <<<"$fichiers" || { echo "absent du paquet : $f"; return 1; }
    done
    ! grep -qE '^(test/|\.github/|workspace/|\.devzone\.|\.repowarden\.conf)' <<<"$fichiers"
}
