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
    [[ "$output" == *"créé dans"* ]] || false
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
    [[ "$output" == *"pas vide"* ]] || false
    [ "$(cat plein/fichier)" = important ]
    [ ! -e plein/Makefile ]
}

@test "devzone desinstaller : refusé hors d'un dossier devzone" {
    run bash "$CLI" desinstaller
    [ "$status" -eq 1 ]
    [[ "$output" == *"dossier devzone"* ]] || false
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
    [[ "$output" == *ancien* ]] || false
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
    [[ "$output" == *avant-core* ]] || false
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
    [[ "$output" == *"devzone <dossier>"* ]] || false
    run bash "$CLI" --truc
    [ "$status" -eq 1 ]
}

@test "paquet npm : contenu attendu, aucun fichier local ni de développement" {
    command -v npm >/dev/null || skip "npm absent"
    fichiers="$(cd "$RACINE" && npm pack --dry-run --json 2>/dev/null | node -e 'for (const f of JSON.parse(require("fs").readFileSync(0))[0].files) console.log(f.path)')"
    for f in core/devzone .devcontainer/devcontainer.json .devcontainer/devzone Makefile core/scripts/lancer.sh core/scripts/desinstaller.sh README.md LICENSE package.json; do
        grep -qx "$f" <<<"$fichiers" || { echo "absent du paquet : $f"; return 1; }
    done
    ! grep -qE '^(core/test/|\.github/|workspace/|\.devzone\.|\.repowarden\.conf)' <<<"$fichiers" || false
}

@test "README : commandes npm citées, sous-commandes citées dans devzone --help" {
    readme="$RACINE/README.md"
    for c in 'npm install -g devzone' 'npm uninstall -g devzone' 'devzone desinstaller'; do
        grep -q -- "$c" "$readme" || { echo "absent du README : $c"; return 1; }
    done
    run bash "$CLI" --help
    [ "$status" -eq 0 ]
    # Citations de la commande npm dans le README : blocs bash et inline code
    # `devzone <mot>`. Le récapitulatif (fence text) et la prose citent le
    # devzone du conteneur, autre commande (.devcontainer/devzone).
    # (aucune citation en ligne : cas normal)
    citations="$(
        awk '/^```bash$/ { dans = 1; next } /^```$/ { dans = 0 } dans' "$readme"
        grep -oE '`devzone [A-Za-z0-9_-]+`' "$readme" || true
    )"
    [ -n "$citations" ]
    # Tout mot cité aussi après npx devzone est le nom du dossier (argument
    # <dossier>), pas une sous-commande ; les options (--version, --help)
    # non plus.
    dossier="$(grep -oE 'npx devzone [A-Za-z0-9_-]+' "$readme" | awk '{ print $NF }' | sort -u)"
    mots="$(grep -oE '(^|[^A-Za-z0-9_-])devzone [A-Za-z0-9_-]+' <<<"$citations" | awk '{ print $NF }' | sort -u)"
    while IFS= read -r mot; do
        [ -n "$mot" ] || continue
        case "$mot" in -*) continue ;; esac
        grep -qx "$mot" <<<"$dossier" && continue
        grep -q -- "$mot" <<<"$output" || { echo "devzone $mot absent de devzone --help"; return 1; }
    done <<<"$mots"
}

# core/scripts/lancer.sh (make up, make rebuild) avec un CLI devcontainer simulé : $1 = son script
faux_cli() {
    mkdir -p "$BATS_TEST_TMPDIR/faux"
    { echo '#!/usr/bin/env bash'; echo "echo \"\$*\" >\"$BATS_TEST_TMPDIR/args\""; echo "$1"; } >"$BATS_TEST_TMPDIR/faux/npx"
    chmod +x "$BATS_TEST_TMPDIR/faux/npx"
    export PATH="$BATS_TEST_TMPDIR/faux:$PATH"
    mkdir -p dz
    # Docker démarré par défaut : les runners macOS n'en ont pas
    faux_docker demarre
}

# docker simulé : $1 = demarre, arrete, droits ou absent (commande introuvable) ;
# chaque appel est noté dans $BATS_TEST_TMPDIR/docker.log
faux_docker() {
    mkdir -p "$BATS_TEST_TMPDIR/faux"
    if [ "$1" = absent ]; then
        export DEVZONE_DOCKER=docker-introuvable-devzone
        return 0
    fi
    export DEVZONE_DOCKER=docker
    {
        echo '#!/usr/bin/env bash'
        echo "echo \"docker \$*\" >>\"$BATS_TEST_TMPDIR/docker.log\""
        case "$1" in
            demarre) echo 'exit 0' ;;
            arrete) echo 'echo "failed to connect to the docker API at unix:///var/run/docker.sock; check if the path is correct and if the daemon is running: dial unix /var/run/docker.sock: connect: no such file or directory" >&2; exit 1' ;;
            droits) echo 'echo "permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock: dial unix /var/run/docker.sock: connect: permission denied" >&2; exit 1' ;;
        esac
    } >"$BATS_TEST_TMPDIR/faux/docker"
    chmod +x "$BATS_TEST_TMPDIR/faux/docker"
    export PATH="$BATS_TEST_TMPDIR/faux:$PATH"
}

@test "lancer.sh : Docker absent → comment l'installer, CLI devcontainers jamais lancé" {
    faux_cli 'echo "{\"outcome\":\"error\"}"; exit 1'
    faux_docker absent
    run bash "$RACINE/core/scripts/lancer.sh" up "$PWD/dz"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Docker introuvable"*"Docker Desktop"*"Docker Engine"*"make up"* ]] || false
    [ ! -e "$BATS_TEST_TMPDIR/args" ]
    [[ "$output" != *outcome* ]] || false
}

@test "lancer.sh : Docker arrêté → démarrer Docker Desktop puis relancer, sans erreur brute" {
    faux_cli 'echo "{\"outcome\":\"error\"}"; exit 1'
    faux_docker arrete
    run bash "$RACINE/core/scripts/lancer.sh" rebuild "$PWD/dz"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Démarre Docker Desktop"*"make rebuild"* ]] || false
    [ ! -e "$BATS_TEST_TMPDIR/args" ]
    [[ "$output" != *outcome* ]] || false
    [[ "$output" != *"failed to connect"* ]] || false
}

@test "lancer.sh : Docker sans droits → la commande du groupe docker" {
    faux_cli 'exit 0'
    faux_docker droits
    run bash "$RACINE/core/scripts/lancer.sh" up "$PWD/dz"
    [ "$status" -ne 0 ]
    [[ "$output" == *"sudo usermod -aG docker"*"make up"* ]] || false
    [[ "$output" != *"permission denied while"* ]] || false
    [ ! -e "$BATS_TEST_TMPDIR/args" ]
}

@test "desinstaller.sh : Docker arrêté → message clair, une seule fois, rien d'autre lancé" {
    bash "$CLI" dz-des
    faux_cli 'exit 1'
    faux_docker arrete
    run bash dz-des/core/scripts/desinstaller.sh
    [ "$status" -ne 0 ]
    [[ "$output" == *"Démarre Docker Desktop"*"make desinstaller"* ]] || false
    [[ "$output" != *"failed to connect"* ]] || false
    [[ "$output" != *Inventaire* ]] || false
    [ "$(grep -c "Démarre Docker Desktop" <<<"$output")" -eq 1 ]
    [ "$(cat "$BATS_TEST_TMPDIR/docker.log")" = "docker info" ]
}

@test "devzone desinstaller : Docker arrêté → la commande à relancer est devzone desinstaller" {
    bash "$CLI" dz-des
    faux_cli 'exit 1'
    faux_docker arrete
    cd dz-des
    run bash "$CLI" desinstaller
    [ "$status" -ne 0 ]
    [[ "$output" == *"puis relance devzone desinstaller"* ]] || false
}

@test "devzone <dossier> sans Docker : dossier créé, comment lancer ensuite, sans erreur brute" {
    unset DEVZONE_SANS_DEMARRER
    faux_cli 'echo "{\"outcome\":\"error\"}"; exit 1'
    faux_docker arrete
    printf '#!/usr/bin/env bash\necho "make $*" >>"%s/make.log"\n' "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/faux/make"
    chmod +x "$BATS_TEST_TMPDIR/faux/make"
    run bash "$CLI" mon-devzone
    [ "$status" -ne 0 ]
    [ -f mon-devzone/Makefile ]
    [[ "$output" == *"Démarre Docker Desktop"*"cd $PWD/mon-devzone && make shell"* ]] || false
    [ ! -e "$BATS_TEST_TMPDIR/make.log" ]
    [ ! -e "$BATS_TEST_TMPDIR/args" ]
    [[ "$output" != *outcome* ]] || false
}

@test "lancer.sh : étapes clés et état affichés, journal complet gardé" {
    faux_cli 'printf "Start: Run: docker buildx build x\r\nbruit\r\nRunning the postStartCommand from devcontainer.json...\r\ndevzone : état\r\n  ○ module ia        facultatif\r\n"'
    run bash "$RACINE/core/scripts/lancer.sh" up "$PWD/dz"
    [ "$status" -eq 0 ]
    [[ "$output" == *"▶ Construction de l'image"*"▶ Démarrage"*"○ module ia"*"devzone lancé"* ]] || false
    [[ "$output" != *bruit* ]] || false
    grep -q bruit dz/.devzone.log
    [[ "$(cat "$BATS_TEST_TMPDIR/args")" == *"up --workspace-folder $PWD/dz"* ]] || false
}

@test "lancer.sh rebuild : conteneur recréé" {
    faux_cli 'exit 0'
    run bash "$RACINE/core/scripts/lancer.sh" rebuild "$PWD/dz"
    [ "$status" -eq 0 ]
    [[ "$output" == *"devzone reconstruit"* ]] || false
    [[ "$(cat "$BATS_TEST_TMPDIR/args")" == *"--remove-existing-container"* ]] || false
}

@test "lancer.sh : question posée dans le conteneur signalée, lancement arrêté au lieu d'attendre" {
    faux_cli 'printf "Running the postCreateCommand from devcontainer.json...\r\nConfigurer les bots de ce dépôt ? [o/N] "; sleep 60'
    export DEVZONE_ATTENTE_QUESTION=2
    debut="$(date +%s)"
    run bash "$RACINE/core/scripts/lancer.sh" up "$PWD/dz"
    [ "$status" -eq 1 ]
    [ $(($(date +%s) - debut)) -lt 20 ]
    [[ "$output" == *"pose une question"*"Configurer les bots de ce dépôt ? [o/N]"* ]] || false
}

@test "lancer.sh : silence signalé (signe de vie), sans le prendre pour une question" {
    faux_cli 'printf "npm install en cours\r\n"; sleep 4'
    export DEVZONE_SIGNE_DE_VIE=1 DEVZONE_ATTENTE_QUESTION=1
    run bash "$RACINE/core/scripts/lancer.sh" up "$PWD/dz"
    [ "$status" -eq 0 ]
    [[ "$output" == *"aucune nouvelle ligne depuis"*"npm install en cours"* ]] || false
    [[ "$output" == *"devzone lancé"* ]] || false
}

@test "lancer.sh : échec, fin du journal affichée" {
    faux_cli 'echo "erreur de construction"; exit 1'
    run bash "$RACINE/core/scripts/lancer.sh" up "$PWD/dz"
    [ "$status" -eq 1 ]
    [[ "$output" == *"erreur de construction"*"échec"* ]] || false
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
        # seuls les mots avec un « / » sont des chemins (ni « bash 3.2 » ni « bash --version »)
        grep -oE '(bash|run: bash) [A-Za-z0-9_.-]*/[A-Za-z0-9_./-]+' .github/workflows/fonctionnel.yml | awk '{ print $NF }'
        grep -oE '^ +- "[^"*]+' .github/workflows/fonctionnel.yml | sed 's/^ *- "//'
    )"
    [ -n "$chemins" ]
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        [ -e "${c%/}" ] || { echo "chemin cité mais absent : $c"; return 1; }
    done <<<"$chemins"
}
