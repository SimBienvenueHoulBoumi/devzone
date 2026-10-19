#!/usr/bin/env bats
# Commande devzone de l'hôte (paquet npm, core/devzone) et contenu du paquet.

setup() {
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CLI="$RACINE/core/devzone"
    export DEVZONE_SANS_DEMARRER=1
    cd "$BATS_TEST_TMPDIR"
}

@test "devzone <dossier> : crée un devzone complet dans un dossier neuf" {
    run bash "$CLI" mon-devzone
    [ "$status" -eq 0 ]
    [[ "$output" == *"créé dans"* ]]
    for f in .devcontainer/devcontainer.json .devcontainer/devzone Makefile .gitattributes core/scripts/lancer.sh core/scripts/desinstaller.sh README.md LICENSE workspace/.gitkeep .gitignore; do
        [ -e "mon-devzone/$f" ] || { echo "manquant : $f"; return 1; }
    done
    [ -x mon-devzone/core/scripts/desinstaller.sh ]
    [ -x mon-devzone/core/scripts/lancer.sh ]
    # Ni la commande npm, ni les tests dans un devzone
    [ ! -e mon-devzone/core/devzone ]
    [ ! -e mon-devzone/core/test ]
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

@test "devzone desinstaller : ancien devzone (desinstaller.sh à la racine) accepté" {
    # devzone créé avant le rangement dans scripts/ : desinstaller.sh à la
    # racine, pas de scripts/ ; la commande doit continuer à fonctionner
    mkdir -p vieux/.devcontainer
    printf '#!/usr/bin/env bash\necho ancien\n' >vieux/desinstaller.sh
    chmod +x vieux/desinstaller.sh
    cd vieux
    run bash "$CLI" desinstaller
    [ "$status" -eq 0 ]
    [[ "$output" == *ancien* ]]
}

@test "devzone desinstaller : devzone d'avant core/ (scripts/desinstaller.sh) accepté" {
    # devzone créé avant le rangement dans core/ : son desinstaller.sh est
    # dans scripts/ ; la commande doit continuer à fonctionner
    mkdir -p avant-core/.devcontainer avant-core/scripts
    printf '#!/usr/bin/env bash\necho avant-core\n' >avant-core/scripts/desinstaller.sh
    chmod +x avant-core/scripts/desinstaller.sh
    cd avant-core
    run bash "$CLI" desinstaller
    [ "$status" -eq 0 ]
    [[ "$output" == *avant-core* ]]
}

@test "devzone desinstaller : desinstaller.sh sans .devcontainer refusé" {
    mkdir pas-devzone
    printf '#!/usr/bin/env bash\necho appele\n' >pas-devzone/desinstaller.sh
    cd pas-devzone
    run bash "$CLI" desinstaller
    [ "$status" -eq 1 ]
    [[ "$output" != *appele* ]] || false
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
    for f in core/devzone .devcontainer/devcontainer.json .devcontainer/devzone Makefile core/scripts/lancer.sh core/scripts/desinstaller.sh README.md LICENSE package.json; do
        grep -qx "$f" <<<"$fichiers" || { echo "absent du paquet : $f"; return 1; }
    done
    ! grep -qE '^(core/test/|\.github/|workspace/|\.devzone\.|\.repowarden\.conf)' <<<"$fichiers"
}

# core/scripts/lancer.sh (make up, make rebuild) avec un CLI devcontainer simulé : $1 = son script
faux_cli() {
    mkdir -p "$BATS_TEST_TMPDIR/faux"
    { echo '#!/usr/bin/env bash'; echo "echo \"\$*\" >\"$BATS_TEST_TMPDIR/args\""; echo "$1"; } >"$BATS_TEST_TMPDIR/faux/npx"
    chmod +x "$BATS_TEST_TMPDIR/faux/npx"
    export PATH="$BATS_TEST_TMPDIR/faux:$PATH"
    mkdir -p dz
}

@test "lancer.sh : étapes clés et état affichés, journal complet gardé" {
    faux_cli 'printf "Start: Run: docker buildx build x\r\nbruit\r\nRunning the postStartCommand from devcontainer.json...\r\ndevzone : état\r\n  ○ module ia        facultatif\r\n"'
    run bash "$RACINE/core/scripts/lancer.sh" up "$PWD/dz"
    [ "$status" -eq 0 ]
    [[ "$output" == *"▶ Construction de l'image"*"▶ Démarrage"*"○ module ia"*"devzone lancé"* ]]
    [[ "$output" != *bruit* ]]
    grep -q bruit dz/.devzone.log
    [[ "$(cat "$BATS_TEST_TMPDIR/args")" == *"up --workspace-folder $PWD/dz"* ]]
}

@test "lancer.sh rebuild : conteneur recréé" {
    faux_cli 'exit 0'
    run bash "$RACINE/core/scripts/lancer.sh" rebuild "$PWD/dz"
    [ "$status" -eq 0 ]
    [[ "$output" == *"devzone reconstruit"* ]]
    [[ "$(cat "$BATS_TEST_TMPDIR/args")" == *"--remove-existing-container"* ]]
}

@test "lancer.sh : question posée dans le conteneur signalée, lancement arrêté au lieu d'attendre" {
    faux_cli 'printf "Running the postCreateCommand from devcontainer.json...\r\nConfigurer les bots de ce dépôt ? [o/N] "; sleep 60'
    export DEVZONE_ATTENTE_QUESTION=2
    debut="$(date +%s)"
    run bash "$RACINE/core/scripts/lancer.sh" up "$PWD/dz"
    [ "$status" -eq 1 ]
    [ $(($(date +%s) - debut)) -lt 20 ]
    [[ "$output" == *"pose une question"*"Configurer les bots de ce dépôt ? [o/N]"* ]]
}

@test "lancer.sh : silence signalé (signe de vie), sans le prendre pour une question" {
    faux_cli 'printf "npm install en cours\r\n"; sleep 4'
    export DEVZONE_SIGNE_DE_VIE=1 DEVZONE_ATTENTE_QUESTION=1
    run bash "$RACINE/core/scripts/lancer.sh" up "$PWD/dz"
    [ "$status" -eq 0 ]
    [[ "$output" == *"aucune nouvelle ligne depuis"*"npm install en cours"* ]]
    [[ "$output" == *"devzone lancé"* ]]
}

@test "lancer.sh : échec, fin du journal affichée" {
    faux_cli 'echo "erreur de construction"; exit 1'
    run bash "$RACINE/core/scripts/lancer.sh" up "$PWD/dz"
    [ "$status" -eq 1 ]
    [[ "$output" == *"erreur de construction"*"échec"* ]]
}

@test "scripts en LF" {
    # Tout fichier suivi commençant par #! doit imposer eol=lf, sinon un clone
    # Windows le reçoit en CRLF. Dans git ls-files --eol, les attributs
    # (3e champ, avec des espaces) précèdent le nom, séparés par une tabulation.
    run git -C "$RACINE" ls-files --eol
    [ "$status" -eq 0 ]
    while IFS= read -r ligne; do
        attrs="${ligne%%$'\t'*}"
        nom="${ligne#*$'\t'}"
        if head -c 2 "$RACINE/$nom" 2>/dev/null | grep -q '^#!'; then
            [[ "$attrs" == *"eol=lf"* ]] || { echo "sans eol=lf : $nom" >&2; false; }
        fi
    done <<<"$output"
}

@test "arborescence : chemins cités par Makefile, package.json, .gitattributes et fonctionnel.yml existants" {
    cd "$RACINE"
    # Anciens emplacements de la racine : ne reviennent pas (tout est sous core/)
    for d in bin scripts test; do
        [ ! -e "$d" ] || { echo "ancien dossier revenu à la racine : $d/"; return 1; }
    done
    chemins="$(
        grep -oE 'core/[A-Za-z0-9_./-]+' Makefile
        grep -oE 'bash [A-Za-z0-9_./-]+' Makefile | awk '{ print $2 }'
        node -e 'const p = require(process.argv[1]); for (const v of Object.values(p.bin)) console.log(v); for (const f of p.files) console.log(f)' "$RACINE/package.json"
        # .gitattributes : seules les entrées avec un « / » sont des chemins
        # (« Dockerfile » est un motif valable partout)
        awk '!/^#/ && NF && $1 ~ /\// && $1 !~ /\*/ { print $1 }' .gitattributes
        grep -oE '(bash|run: bash) [A-Za-z0-9_./-]+' .github/workflows/fonctionnel.yml | awk '{ print $NF }'
        grep -oE '^ +- "[^"*]+' .github/workflows/fonctionnel.yml | sed 's/^ *- "//'
    )"
    [ -n "$chemins" ]
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        [ -e "${c%/}" ] || { echo "chemin cité mais absent : $c"; return 1; }
    done <<<"$chemins"
}
