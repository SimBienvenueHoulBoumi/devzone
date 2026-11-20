#!/usr/bin/env bats
# devzone command on the host (npm package, manage/devzone) and package content.

setup() {
    load commun
    relais_docker_isole
    kube_isole
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CLI="$RACINE/manage/devzone"
    export DEVZONE_SANS_DEMARRER=1
    cd "$BATS_TEST_TMPDIR" || return 1
}

@test "devzone <folder>: creates a complete devzone in a new folder" {
    run bash "$CLI" mon-devzone --docker
    [ "$status" -eq 0 ]
    [[ "$output" == *"créé dans"* ]] || false
    for f in .devcontainer/devcontainer.json .devcontainer/devzone Makefile .gitattributes manage/scripts/launch.sh manage/scripts/uninstall.sh README.md LICENSE workspace/.gitkeep .gitignore .devzone.version; do
        [ -e "mon-devzone/$f" ] || { echo "manquant : $f"; return 1; }
    done
    [ -x mon-devzone/manage/scripts/uninstall.sh ]
    [ -x mon-devzone/manage/scripts/launch.sh ]
    # Neither the npm command nor the tests in a devzone
    [ ! -e mon-devzone/manage/devzone ]
    [ ! -e mon-devzone/manage/test ]
    grep -q '^workspace/\*$' mon-devzone/.gitignore
    grep -qx '.devzone.sauvegarde/' mon-devzone/.gitignore
}

@test "devzone <folder>: .devzone.version holds the version and one checksum per copied file" {
    bash "$CLI" mon-devzone --docker
    [ "$(sed -n '1p' mon-devzone/.devzone.version)" = "version $(bash "$CLI" --version)" ]
    for f in .devcontainer/devcontainer.json .devcontainer/devzone Makefile .gitattributes manage/scripts/launch.sh manage/scripts/uninstall.sh README.md LICENSE; do
        attendue="$(node -e 'const fs = require("fs"), crypto = require("crypto"); const h = crypto.createHash("sha256"); h.update(fs.readFileSync(process.argv[1])); process.stdout.write(h.digest("hex"))' "mon-devzone/$f")"
        grep -qxF "$attendue  $f" mon-devzone/.devzone.version || { echo "empreinte absente : $f"; return 1; }
    done
    # The npm command and the locally written files are not copied
    ! grep -q 'manage/devzone' mon-devzone/.devzone.version || false
    ! grep -q '  .gitignore$' mon-devzone/.devzone.version || false
}

@test "devzone <folder>: embeds neither bin/, nor tests, nor CI, nor repository settings" {
    bash "$CLI" mon-devzone --docker
    for f in bin test .github .repowarden.conf package.json .devzone.log; do
        [ ! -e "mon-devzone/$f" ] || { echo "en trop : $f"; return 1; }
    done
}

@test "devzone <folder>: existing empty folder accepted" {
    mkdir vide
    run bash "$CLI" vide --docker
    [ "$status" -eq 0 ]
    [ -f vide/Makefile ]
}

@test "devzone <folder>: non-empty folder refused, nothing overwritten" {
    mkdir plein && echo important >plein/fichier
    run bash "$CLI" plein
    [ "$status" -eq 1 ]
    [[ "$output" == *"pas vide"* ]] || false
    [ "$(cat plein/fichier)" = important ]
    [ ! -e plein/Makefile ]
}

@test "devzone <dossier> --gitops none : .argocd.conf note no GitOps" {
    run bash "$CLI" mon-devzone --gitops none --docker
    [ "$status" -eq 0 ]
    grep -q '^\[argocd\]$' mon-devzone/.argocd.conf
    grep -q '^    repo = none$' mon-devzone/.argocd.conf
    export ARGOCD_CONF="$BATS_TEST_TMPDIR/mon-devzone/.argocd.conf"
    . "$RACINE/.devcontainer/argocd/conf.sh"
    [ "$(conf_get argocd repo)" = none ]
}

@test "devzone <dossier> --gitops <url> : .argocd.conf note the URL" {
    run bash "$CLI" mon-devzone --gitops https://github.com/x/y.git --docker
    [ "$status" -eq 0 ]
    grep -q '^    repo = https://github.com/x/y.git$' mon-devzone/.argocd.conf
}

@test "devzone <dossier> --gitops github : .argocd.conf note the GitHub repository" {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat >"$BATS_TEST_TMPDIR/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$*" in
    "auth status") exit 0 ;;
    "api user --jq .login") echo tester ;;
esac
exit 0
GH
    chmod +x "$BATS_TEST_TMPDIR/bin/gh"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    run bash "$CLI" mon-devzone --gitops github --docker
    [ "$status" -eq 0 ]
    grep -q '^    repo = https://github.com/tester/devzone-argocd.git$' mon-devzone/.argocd.conf
}

@test "devzone <folder> without option nor terminal: none and a notice about --gitops" {
    run bash "$CLI" mon-devzone --docker
    [ "$status" -eq 0 ]
    [[ "$output" == *"--gitops"* ]] || false
    grep -q '^    repo = none$' mon-devzone/.argocd.conf
}

@test "devzone uninstall: refused outside a devzone folder" {
    run bash "$CLI" uninstall
    [ "$status" -eq 1 ]
    [[ "$output" == *"dossier devzone"* ]] || false
}

@test "devzone uninstall: old devzone (uninstall.sh at the root) accepted" {
    # devzone created before the move into scripts/: uninstall.sh at the
    # root, no scripts/; the command must keep working
    mkdir -p vieux/.devcontainer
    printf '#!/usr/bin/env bash\necho ancien\n' >vieux/uninstall.sh
    chmod +x vieux/uninstall.sh
    cd vieux
    run bash "$CLI" uninstall
    [ "$status" -eq 0 ]
    [[ "$output" == *ancien* ]] || false
}

@test "devzone uninstall: devzone from before manage/ (scripts/uninstall.sh) accepted" {
    # devzone created before the move into manage/: its uninstall.sh is
    # in scripts/; the command must keep working
    mkdir -p avant-core/.devcontainer avant-core/scripts
    printf '#!/usr/bin/env bash\necho avant-core\n' >avant-core/scripts/uninstall.sh
    chmod +x avant-core/scripts/uninstall.sh
    cd avant-core
    run bash "$CLI" uninstall
    [ "$status" -eq 0 ]
    [[ "$output" == *avant-core* ]] || false
}

@test "devzone uninstall: uninstall.sh without .devcontainer refused" {
    mkdir pas-devzone
    printf '#!/usr/bin/env bash\necho appele\n' >pas-devzone/uninstall.sh
    cd pas-devzone
    run bash "$CLI" uninstall
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

@test "npm package: expected content, no local nor development file" {
    command -v npm >/dev/null || skip "npm absent"
    fichiers="$(cd "$RACINE" && npm pack --dry-run --json 2>/dev/null | node -e 'for (const f of JSON.parse(require("fs").readFileSync(0))[0].files) console.log(f.path)')"
    for f in manage/devzone .devcontainer/devcontainer.json .devcontainer/devzone Makefile manage/scripts/launch.sh manage/scripts/uninstall.sh README.md LICENSE package.json; do
        grep -qx "$f" <<<"$fichiers" || { echo "absent du paquet : $f"; return 1; }
    done
    ! grep -qE '^(manage/test/|\.github/|workspace/|\.devzone\.|\.repowarden\.conf)' <<<"$fichiers" || false
}

@test "README: npm commands cited, subcommands cited in devzone --help" {
    readme="$RACINE/README.md"
    for c in 'npm install -g devzone' 'npm uninstall -g devzone' 'devzone uninstall'; do
        grep -q -- "$c" "$readme" || { echo "absent du README : $c"; return 1; }
    done
    run bash "$CLI" --help
    [ "$status" -eq 0 ]
    # Workstation commands cited in the bash blocks of the README. Inline citations
    # are checked by readme.bats (workstation, container, aliases).
    citations="$(awk '/^```bash$/ { dans = 1; next } /^```$/ { dans = 0 } dans' "$readme")"
    [ -n "$citations" ]
    # Any word also cited after npx devzone is the folder name (argument
    # <folder>), not a subcommand; the options (--version, --help)
    # neither.
    dossier="$(grep -oE 'npx devzone [A-Za-z0-9_-]+' "$readme" | awk '{ print $NF }' | sort -u)"
    mots="$(grep -oE '(^|[^A-Za-z0-9_-])devzone [A-Za-z0-9_-]+' <<<"$citations" | awk '{ print $NF }' | sort -u)"
    while IFS= read -r mot; do
        [ -n "$mot" ] || continue
        case "$mot" in -*) continue ;; esac
        grep -qx "$mot" <<<"$dossier" && continue
        grep -q -- "$mot" <<<"$output" || { echo "devzone $mot absent de devzone --help"; return 1; }
    done <<<"$mots"
}

# manage/scripts/launch.sh (make up, make rebuild) with a fake devcontainer CLI: $1 = its script
fake_cli() {
    mkdir -p "$BATS_TEST_TMPDIR/faux"
    { echo '#!/usr/bin/env bash'; echo "echo \"\$*\" >\"$BATS_TEST_TMPDIR/args\""; echo "$1"; } >"$BATS_TEST_TMPDIR/faux/npx"
    chmod +x "$BATS_TEST_TMPDIR/faux/npx"
    export PATH="$BATS_TEST_TMPDIR/faux:$PATH"
    mkdir -p dz
    # Docker started by default: macOS runners have none
    fake_docker demarre
}

# fake docker: $1 = demarre, arrete, droits or absent (command not found);
# each call is logged in $BATS_TEST_TMPDIR/docker.log
fake_docker() {
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

@test "launch.sh: Docker absent → how to install it, devcontainer CLI never started" {
    fake_cli 'echo "{\"outcome\":\"error\"}"; exit 1'
    fake_docker absent
    run bash "$RACINE/manage/scripts/launch.sh" up "$PWD/dz"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Docker not found"*"Docker Desktop"*"Docker Engine"*"make up"* ]] || false
    [ ! -e "$BATS_TEST_TMPDIR/args" ]
    [[ "$output" != *outcome* ]] || false
}

@test "launch.sh: Docker stopped → start Docker Desktop then retry, without a raw error" {
    fake_cli 'echo "{\"outcome\":\"error\"}"; exit 1'
    fake_docker arrete
    run bash "$RACINE/manage/scripts/launch.sh" rebuild "$PWD/dz"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Start Docker Desktop"*"make rebuild"* ]] || false
    [ ! -e "$BATS_TEST_TMPDIR/args" ]
    [[ "$output" != *outcome* ]] || false
    [[ "$output" != *"failed to connect"* ]] || false
}

@test "launch.sh: Docker without rights → the docker group command" {
    fake_cli 'exit 0'
    fake_docker droits
    run bash "$RACINE/manage/scripts/launch.sh" up "$PWD/dz"
    [ "$status" -ne 0 ]
    [[ "$output" == *"sudo usermod -aG docker"*"make up"* ]] || false
    [[ "$output" != *"permission denied while"* ]] || false
    [ ! -e "$BATS_TEST_TMPDIR/args" ]
}

@test "uninstall.sh: Docker stopped → clear message, once, nothing else started" {
    bash "$CLI" dz-des --docker
    fake_cli 'exit 1'
    fake_docker arrete
    run bash dz-des/manage/scripts/uninstall.sh
    [ "$status" -ne 0 ]
    [[ "$output" == *"Start Docker Desktop"*"make desinstaller"* ]] || false
    [[ "$output" != *"failed to connect"* ]] || false
    [[ "$output" != *Inventaire* ]] || false
    [ "$(grep -c "Start Docker Desktop" <<<"$output")" -eq 1 ]
    [ "$(cat "$BATS_TEST_TMPDIR/docker.log")" = "docker info" ]
}

@test "devzone uninstall: Docker stopped → the command to re-run is devzone desinstaller" {
    bash "$CLI" dz-des --docker
    fake_cli 'exit 1'
    fake_docker arrete
    cd dz-des
    run bash "$CLI" uninstall
    [ "$status" -ne 0 ]
}

@test "devzone <folder> without Docker: folder created, how to start later, without a raw error" {
    unset DEVZONE_SANS_DEMARRER
    fake_cli 'echo "{\"outcome\":\"error\"}"; exit 1'
    fake_docker arrete
    # Cluster unreachable: the mode is Docker, whatever kubectl the host has (#497)
    printf '#!/usr/bin/env bash\nexit 1\n' >"$BATS_TEST_TMPDIR/faux/kubectl"
    chmod +x "$BATS_TEST_TMPDIR/faux/kubectl"
    printf '#!/usr/bin/env bash\necho "make $*" >>"%s/make.log"\n' "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/faux/make"
    chmod +x "$BATS_TEST_TMPDIR/faux/make"
    run bash "$CLI" mon-devzone --docker
    [ "$status" -ne 0 ]
    [ -f mon-devzone/Makefile ]
    [[ "$output" == *"Start Docker Desktop"*"cd $PWD/mon-devzone && make shell"* ]] || false
    [ ! -e "$BATS_TEST_TMPDIR/make.log" ]
    [ ! -e "$BATS_TEST_TMPDIR/args" ]
    [[ "$output" != *outcome* ]] || false
}

@test "launch.sh: key steps and state shown, full log kept" {
    fake_cli 'printf "Start: Run: docker buildx build x\r\nbruit\r\nRunning the postStartCommand from devcontainer.json...\r\ndevzone : état\r\n  ○ module ia        facultatif\r\n"'
    run bash "$RACINE/manage/scripts/launch.sh" up "$PWD/dz"
    [ "$status" -eq 0 ]
    [[ "$output" == *"▶ Building image"*"▶ Starting (git identity, clusters, state)"*"○ module ia"*"devzone started"* ]] || false
    [[ "$output" != *bruit* ]] || false
    grep -q bruit dz/.devzone.log
    [[ "$(cat "$BATS_TEST_TMPDIR/args")" == *"up --workspace-folder $PWD/dz"* ]] || false
}

@test "launch.sh: « devzone: state » summary (English form) shown" {
    fake_cli 'printf "Running the postStartCommand from devcontainer.json...\r\ndevzone: state\r\n  ○ module ia        facultatif\r\n"'
    run bash "$RACINE/manage/scripts/launch.sh" up "$PWD/dz"
    [ "$status" -eq 0 ]
    [[ "$output" == *"devzone: state"*"○ module ia"* ]] || false
}

@test "launch.sh rebuild: container recreated" {
    fake_cli 'exit 0'
    run bash "$RACINE/manage/scripts/launch.sh" rebuild "$PWD/dz"
    [ "$status" -eq 0 ]
    [[ "$output" == *"devzone rebuilt"* ]] || false
    [[ "$(cat "$BATS_TEST_TMPDIR/args")" == *"--remove-existing-container"* ]] || false
}

@test "launch.sh: question asked in the container reported, start stopped instead of waiting" {
    fake_cli 'printf "Running the postCreateCommand from devcontainer.json...\r\nConfigurer les bots de ce dépôt ? [o/N] "; sleep 60'
    export DEVZONE_ATTENTE_QUESTION=2
    debut="$(date +%s)"
    run bash "$RACINE/manage/scripts/launch.sh" up "$PWD/dz"
    [ "$status" -eq 1 ]
    [ $(($(date +%s) - debut)) -lt 20 ]
    [[ "$output" == *"asks a question"*"Configurer les bots de ce dépôt ? [o/N]"* ]] || false
}

@test "launch.sh: silence reported (sign of life), not taken for a question" {
    fake_cli 'printf "npm install en cours\r\n"; sleep 4'
    export DEVZONE_SIGNE_DE_VIE=1 DEVZONE_ATTENTE_QUESTION=1
    run bash "$RACINE/manage/scripts/launch.sh" up "$PWD/dz"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no new line for"*"npm install en cours"* ]] || false
    [[ "$output" == *"devzone started"* ]] || false
}

@test "launch.sh: failure, end of the log shown" {
    fake_cli 'echo "erreur de construction"; exit 1'
    run bash "$RACINE/manage/scripts/launch.sh" up "$PWD/dz"
    [ "$status" -eq 1 ]
    [[ "$output" == *"erreur de construction"*"failed"* ]] || false
}

@test "launch.sh: docker-hote=off → config without the feature, build paths fixed, --config passed" {
    fake_cli 'exit 0'
    mkdir -p dz/.devcontainer
    cp "$RACINE/.devcontainer/devcontainer.json" dz/.devcontainer/devcontainer.json
    printf 'docker-hote=off\n' >dz/.devzone.modules
    run bash "$RACINE/manage/scripts/launch.sh" up "$PWD/dz"
    [ "$status" -eq 0 ]
    cfg="$PWD/dz/.devcontainer/without-host-docker/devcontainer.json"
    [ -f "$cfg" ]
    ! grep -q "docker-outside-of-docker" "$cfg" || false
    grep -q '"dockerfile": "../Dockerfile"' "$cfg"
    grep -q '"context": ".."' "$cfg"
    # JSONC: the comments of the original copy are kept
    grep -q '// Image de base' "$cfg"
    [[ "$(cat "$BATS_TEST_TMPDIR/args")" == *"up --workspace-folder $PWD/dz --config $cfg"* ]] || false
}

@test "launch.sh: docker-hote absent or on → normal config, no --config" {
    fake_cli 'exit 0'
    run bash "$RACINE/manage/scripts/launch.sh" up "$PWD/dz"
    [ "$status" -eq 0 ]
    [ ! -e dz/.devcontainer/without-host-docker/devcontainer.json ]
    [[ "$(cat "$BATS_TEST_TMPDIR/args")" != *"--config"* ]] || false
    printf 'docker-hote=on\n' >dz/.devzone.modules
    run bash "$RACINE/manage/scripts/launch.sh" rebuild "$PWD/dz"
    [ "$status" -eq 0 ]
    [ ! -e dz/.devcontainer/without-host-docker/devcontainer.json ]
    [[ "$(cat "$BATS_TEST_TMPDIR/args")" != *"--config"* ]] || false
}

@test "scripts with LF endings" {
    # Any tracked file starting with #! must enforce eol=lf, otherwise a
    # Windows clone gets it in CRLF. In git ls-files --eol, the attributes
    # (3rd field, with spaces) come before the name, separated by a tab.
    run git -C "$RACINE" ls-files --eol
    [ "$status" -eq 0 ]
    while IFS= read -r ligne; do
        attrs="${ligne%%$'\t'*}"
        nom="${ligne#*$'\t'}"
        if head -c 2 "$RACINE/$nom" 2>/dev/null | grep -q '^#!'; then
            if [[ "$attrs" != *"eol=lf"* ]]; then
                echo "sans eol=lf : $nom" >&2
                false
            fi
        fi
    done <<<"$output"
}

@test "layout: paths cited by Makefile, package.json, .gitattributes and fonctionnel.yml exist" {
    cd "$RACINE"
    # Old root locations: must not come back (everything is under manage/)
    for d in bin scripts test; do
        [ ! -e "$d" ] || { echo "ancien dossier revenu à la racine : $d/"; return 1; }
    done
    chemins="$(
        grep -oE 'manage/[A-Za-z0-9_./-]+' Makefile
        grep -oE 'bash [A-Za-z0-9_./-]+' Makefile | awk '{ print $2 }'
        node -e 'const p = require(process.argv[1]); for (const v of Object.values(p.bin)) console.log(v); for (const f of p.files) console.log(f)' "$RACINE/package.json"
        # .gitattributes: only the entries with a « / » are paths
        # («Dockerfile» is a pattern valid everywhere)
        awk '!/^#/ && NF && $1 ~ /\// && $1 !~ /\*/ { print $1 }' .gitattributes
        # only the words with a « / » are paths (neither « bash 3.2 » nor « bash --version »)
        grep -oE '(bash|run: bash) [A-Za-z0-9_.-]*/[A-Za-z0-9_./-]+' .github/workflows/fonctionnel.yml | awk '{ print $NF }'
        grep -oE '^ +- "[^"*]+' .github/workflows/fonctionnel.yml | sed 's/^ *- "//'
    )"
    [ -n "$chemins" ]
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        [ -e "${c%/}" ] || { echo "chemin cité mais absent : $c"; return 1; }
    done <<<"$chemins"
}

@test "devzone modules: container command refused on the workstation, no folder created" {
    run bash "$CLI" modules
    [ "$status" -eq 2 ]
    [[ "$output" == *"devzone modules : commande du conteneur"* ]] || false
    [ ! -e modules ]
}

@test "devzone mon-projet: a free name always creates the folder" {
    run bash "$CLI" mon-projet --docker
    [ "$status" -eq 0 ]
    [ -d mon-projet/.devcontainer ]
}

@test "devzone: each container command is in the launcher list" {
    local cmd noms
    # Final case of .devcontainer/devzone: lines with 4 spaces, before ')'
    noms="$(sed -n '/^case "\${1:-}" in/,/^esac/p' "$RACINE/.devcontainer/devzone" |
        grep -oE '^    [^ ][^)]*\)' | sed 's/)$//' | tr '|' '\n' | tr -d ' "')"
    [ -n "$noms" ]
    # No expansion: the default case « * » must not become a list of files
    set -f
    for cmd in $noms; do
        case "$cmd" in
            workspace | uninstall | update | -h | --help | -v | --version | aide | help | '*') continue ;;
        esac
        # The launcher must not create a folder for this name
        run bash "$CLI" "$cmd"
        [ "$status" -eq 2 ] || { echo "absent de la liste du lanceur : $cmd"; return 1; }
        [ ! -e "$cmd" ] || { echo "dossier créé : $cmd"; return 1; }
    done
}
