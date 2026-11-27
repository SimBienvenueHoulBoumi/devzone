#!/usr/bin/env bats
# devzone command on the host (npm package, manage/devzone) and package content.

setup_file() {
    # uninstall.sh asks the Go program for the host engine check (#884): built once for the file
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export DEVZONE_HOST_BIN="$BATS_FILE_TMPDIR/devzone"
    (cd "$RACINE" && go build -o "$DEVZONE_HOST_BIN" ./cmd/devzone) || { echo "go build failed"; return 1; }
}

setup() {
    load commun
    kube_isole
    cluster_pret
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CLI="$RACINE/manage/devzone"
    export DEVZONE_NO_START=1
    cd "$BATS_TEST_TMPDIR" || return 1
}

@test "devzone <folder>: creates a complete devzone in a new folder" {
    run bash "$CLI" mon-devzone --kubernetes
    [ "$status" -eq 0 ]
    [[ "$output" == *"created in"* ]] || false
    for f in .devcontainer/devcontainer.json .devcontainer/devzone Makefile .gitattributes manage/scripts/uninstall.sh README.md LICENSE workspace/.gitkeep .gitignore .devzone.version; do
        [ -e "mon-devzone/$f" ] || { echo "manquant : $f"; return 1; }
    done
    [ -x mon-devzone/manage/scripts/uninstall.sh ]
    # Neither the npm command nor the tests in a devzone
    [ ! -e mon-devzone/manage/devzone ]
    [ ! -e mon-devzone/manage/test ]
    grep -q '^workspace/\*$' mon-devzone/.gitignore
    grep -qx '.devzone.backup/' mon-devzone/.gitignore
}

@test "devzone <folder>: .devzone.version holds the version and one checksum per copied file" {
    bash "$CLI" mon-devzone --kubernetes
    [ "$(sed -n '1p' mon-devzone/.devzone.version)" = "version $(bash "$CLI" --version)" ]
    for f in .devcontainer/devcontainer.json .devcontainer/devzone Makefile .gitattributes manage/scripts/uninstall.sh README.md LICENSE; do
        attendue="$(node -e 'const fs = require("fs"), crypto = require("crypto"); const h = crypto.createHash("sha256"); h.update(fs.readFileSync(process.argv[1])); process.stdout.write(h.digest("hex"))' "mon-devzone/$f")"
        grep -qxF "$attendue  $f" mon-devzone/.devzone.version || { echo "empreinte absente : $f"; return 1; }
    done
    # The npm command and the locally written files are not copied
    ! grep -q 'manage/devzone' mon-devzone/.devzone.version || false
    ! grep -q '  .gitignore$' mon-devzone/.devzone.version || false
}

@test "devzone <folder>: embeds neither bin/, nor tests, nor CI, nor repository settings" {
    bash "$CLI" mon-devzone --kubernetes
    for f in bin test .github .repowarden.conf package.json .devzone.log; do
        [ ! -e "mon-devzone/$f" ] || { echo "en trop : $f"; return 1; }
    done
}

@test "devzone <folder>: existing empty folder accepted" {
    mkdir vide
    run bash "$CLI" vide --kubernetes
    [ "$status" -eq 0 ]
    [ -f vide/Makefile ]
}

@test "devzone <folder>: non-empty folder refused, nothing overwritten" {
    mkdir plein && echo important >plein/file
    run bash "$CLI" plein
    [ "$status" -eq 1 ]
    [[ "$output" == *"not empty"* ]] || false
    [ "$(cat plein/file)" = important ]
    [ ! -e plein/Makefile ]
}

@test "devzone <folder> --gitops none: .argocd.conf notes no GitOps" {
    run bash "$CLI" mon-devzone --gitops none --kubernetes
    [ "$status" -eq 0 ]
    grep -q '^\[argocd\]$' mon-devzone/.argocd.conf
    grep -q '^    repo = none$' mon-devzone/.argocd.conf
    export ARGOCD_CONF="$BATS_TEST_TMPDIR/mon-devzone/.argocd.conf"
    . "$RACINE/.devcontainer/argocd/conf.sh"
    [ "$(conf_get argocd repo)" = none ]
}

@test "devzone <folder> --gitops <url>: .argocd.conf notes the URL" {
    run bash "$CLI" mon-devzone --gitops https://github.com/x/y.git --kubernetes
    [ "$status" -eq 0 ]
    grep -q '^    repo = https://github.com/x/y.git$' mon-devzone/.argocd.conf
}

@test "devzone <folder> --gitops github: .argocd.conf notes the GitHub repository" {
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
    run bash "$CLI" mon-devzone --gitops github --kubernetes
    [ "$status" -eq 0 ]
    grep -q '^    repo = https://github.com/tester/devzone-argocd.git$' mon-devzone/.argocd.conf
}

@test "devzone <folder> without option nor terminal: none and a notice about --gitops" {
    run bash "$CLI" mon-devzone --kubernetes
    [ "$status" -eq 0 ]
    [[ "$output" == *"--gitops"* ]] || false
    grep -q '^    repo = none$' mon-devzone/.argocd.conf
}

@test "devzone uninstall: refused outside a devzone folder" {
    run bash "$CLI" uninstall
    [ "$status" -eq 1 ]
    [[ "$output" == *"devzone folder"* ]] || false
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
    [[ "$output" == *"devzone <folder>"* ]] || false
    run bash "$CLI" --truc
    [ "$status" -eq 1 ]
}

@test "npm package: expected content, no local nor development file" {
    command -v npm >/dev/null || skip "npm absent"
    fichiers="$(cd "$RACINE" && npm pack --dry-run --json --ignore-scripts 2>/dev/null | node -e 'for (const f of JSON.parse(require("fs").readFileSync(0))[0].files) console.log(f.path)')"
    for f in manage/devzone .devcontainer/devcontainer.json .devcontainer/devzone Makefile manage/scripts/uninstall.sh README.md LICENSE package.json; do
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
    citations="$(awk '/^```bash$/ { inside = 1; next } /^```$/ { inside = 0 } inside' "$readme")"
    [ -n "$citations" ]
    # Any word also cited after npx devzone is the folder name (argument
    # <folder>), not a subcommand; the options (--version, --help)
    # neither.
    folders="$(grep -oE 'npx devzone [A-Za-z0-9_-]+' "$readme" | awk '{ print $NF }' | sort -u)"
    mots="$(grep -oE '(^|[^A-Za-z0-9_-])devzone [A-Za-z0-9_-]+' <<<"$citations" | awk '{ print $NF }' | sort -u)"
    while IFS= read -r mot; do
        [ -n "$mot" ] || continue
        case "$mot" in -*) continue ;; esac
        grep -qx "$mot" <<<"$folders" && continue
        grep -q -- "$mot" <<<"$output" || { echo "devzone $mot absent de devzone --help"; return 1; }
    done <<<"$mots"
}

# fake devcontainer CLI: $1 = its script
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

@test "uninstall.sh: Docker stopped → clear message, once, nothing else started" {
    bash "$CLI" dz-test --kubernetes
    fake_cli 'exit 1'
    fake_docker arrete
    run bash dz-test/manage/scripts/uninstall.sh
    [ "$status" -ne 0 ]
    [[ "$output" == *"Start Docker Desktop"*"make desinstaller"* ]] || false
    [[ "$output" != *"failed to connect"* ]] || false
    [[ "$output" != *Inventaire* ]] || false
    [ "$(grep -c "Start Docker Desktop" <<<"$output")" -eq 1 ]
    [ "$(cat "$BATS_TEST_TMPDIR/docker.log")" = "docker info" ]
}

@test "devzone uninstall: Docker stopped → the command to re-run is devzone desinstaller" {
    bash "$CLI" dz-test --kubernetes
    fake_cli 'exit 1'
    fake_docker arrete
    cd dz-test
    run bash "$CLI" uninstall
    [ "$status" -ne 0 ]
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
                echo "without eol=lf: $nom" >&2
                false
            fi
        fi
    done <<<"$output"
}

@test "layout: paths cited by Makefile, package.json, .gitattributes and fonctionnel.yml exist" {
    cd "$RACINE"
    # Old root locations: must not come back (everything is under manage/)
    for d in scripts test; do
        [ ! -e "$d" ] || { echo "old folder back at the root: $d/"; return 1; }
    done
    # bin/ at the root holds the Go binaries built by prepack (#773): present only
    # after a build, ignored by git, never tracked
    [ -z "$(git ls-files bin)" ] || { echo "bin/ is tracked by git"; return 1; }
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
        # bin/ is built by prepack: absent from a checkout
        [ "$c" != "bin/" ] || continue
        [ -e "${c%/}" ] || { echo "cited path but missing: $c"; return 1; }
    done <<<"$chemins"
}

@test "devzone modules: container command refused on the workstation, no folder created" {
    run bash "$CLI" modules
    [ "$status" -eq 2 ]
    [[ "$output" == *"devzone modules: pod command"* ]] || false
    [ ! -e modules ]
}

@test "devzone mon-projet: a free name always creates the folder" {
    run bash "$CLI" mon-projet --kubernetes
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
            workspace | uninstall | update | -h | --help | -v | --version | help | '*') continue ;;
        esac
        # The launcher must not create a folder for this name
        run bash "$CLI" "$cmd"
        [ "$status" -eq 2 ] || { echo "absent de la liste du lanceur : $cmd"; return 1; }
        [ ! -e "$cmd" ] || { echo "folder created: $cmd"; return 1; }
    done
}
