#!/usr/bin/env bats
# Update of an existing devzone (#349): fake packages v1 and v2 under
# $BATS_TEST_TMPDIR. No real rebuild, no system script.

setup() {
    load commun
    relais_docker_isole
    kube_isole
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CLI="$RACINE/manage/devzone"
    T="$BATS_TEST_TMPDIR"
    cd "$T"
    export DEVZONE_NO_START=1
    export DEVZONE_REBUILD="$T/reconstruire"
    printf '#!/usr/bin/env bash\necho "reconstruit" >>"%s/reconstruction.log"\n' "$T" >"$DEVZONE_REBUILD"
    chmod +x "$DEVZONE_REBUILD"
    build_package v1 0.0.1 ancien
    build_package v2 0.0.2 nouveau
    MAJ="$T/v2/manage/devzone"
    MAJ1="$T/v1/manage/devzone"
}

build_package() {
    local name="$1" version="$2" mark="$3" folder="$T/$1"
    mkdir -p "$folder/.devcontainer/argocd" "$folder/.devcontainer" "$folder/manage/scripts"
    cp "$CLI" "$folder/manage/devzone"
    chmod +x "$folder/manage/devzone"
    cp "$RACINE/.devcontainer/argocd/conf.sh" "$folder/.devcontainer/argocd/conf.sh"
    # devzone <folder> sources the mode check (#497) from the package
    cp "$RACINE/manage/scripts/create-mode.sh" "$RACINE/manage/scripts/create-cluster.sh" "$RACINE/manage/scripts/kube-ready.sh" "$folder/manage/scripts/"
    cp "$RACINE/manage/scripts/devzone-manifest.sh" "$RACINE/manage/scripts/devzone-update.sh" "$RACINE/manage/scripts/devzone-create.sh" "$folder/manage/scripts/"
    printf '{"name":"devzone","version":"%s"}\n' "$version" >"$folder/package.json"
    printf '# makefile %s\n' "$mark" >"$folder/Makefile"
    printf '*.sh text eol=lf\n' >"$folder/.gitattributes"
    printf '# devzone %s\n' "$mark" >"$folder/README.md"
    printf 'licence %s\n' "$mark" >"$folder/LICENSE"
    printf '{"marque":"%s"}\n' "$mark" >"$folder/.devcontainer/devcontainer.json"
    printf '{"marque":"%s"}\n' "$mark" >"$folder/.devcontainer/devcontainer-lock.json"
    printf '#!/usr/bin/env bash\necho %s\n' "$mark" >"$folder/.devcontainer/devzone"
    printf '#!/usr/bin/env bash\necho lancer-%s\n' "$mark" >"$folder/manage/scripts/launch.sh"
    printf '#!/usr/bin/env bash\necho desinstaller-%s\n' "$mark" >"$folder/manage/scripts/uninstall.sh"
    chmod +x "$folder/.devcontainer/devzone" "$folder/manage/scripts/launch.sh" "$folder/manage/scripts/uninstall.sh"
}

create_v1() {
    DZ="$T/devzone"
    bash "$T/v1/manage/devzone" "$DZ" --docker >/dev/null
}

backup_of() {
    find "$DZ/.devzone.backup" -mindepth 1 -maxdepth 1 -type d | head -1
}

# Poisoned manifest: the path must be ignored with a warning, and the
# file outside the devzone folder must survive the update.
poisoned_manifest() {
    local rel="$1"
    create_v1
    mkdir -p "$T/dehors"
    printf 'secret\n' >"$T/dehors/secret"
    printf '%064d  %s\n' 0 "$rel" >>"$DZ/.devzone.version"
    cd "$DZ"
    run bash "$MAJ" update --yes --sans-reconstruire
    [ "$status" -eq 0 ]
    [ "$(cat "$T/dehors/secret")" = secret ]
    [[ "$output" == *"devzone : manifeste : chemin refusé : $rel"* ]] || false
}

@test "creation: .devzone.version holds the version and one checksum per copied file" {
    create_v1
    [ "$(sed -n '1p' "$DZ/.devzone.version")" = "version 0.0.1" ]
    for f in .devcontainer/devcontainer.json .devcontainer/devzone Makefile .gitattributes manage/scripts/launch.sh manage/scripts/uninstall.sh README.md LICENSE; do
        attendue="$(node -e 'const fs = require("fs"), crypto = require("crypto"); const h = crypto.createHash("sha256"); h.update(fs.readFileSync(process.argv[1])); process.stdout.write(h.digest("hex"))' "$DZ/$f")"
        grep -qxF "$attendue  $f" "$DZ/.devzone.version" || { echo "empreinte absente : $f"; return 1; }
    done
    ! grep -q 'manage/devzone' "$DZ/.devzone.version" || false
}

@test "up to date: same version, files present → exit 0, nothing touched, npx suggested" {
    create_v1
    avant="$(cat "$DZ/.devzone.version")"
    cd "$DZ"
    run bash "$MAJ1" update
    [ "$status" -eq 0 ]
    [[ "$output" == *"déjà à jour"* ]] || false
    [[ "$output" == *"npx devzone@latest update"* ]] || false
    [ "$(cat "$DZ/.devzone.version")" = "$avant" ]
    [ ! -e "$DZ/.devzone.backup" ]
    [ ! -e "$T/reconstruction.log" ]
}

@test "same version but a package file missing → the file is restored" {
    create_v1
    rm "$DZ/Makefile"
    cd "$DZ"
    run bash "$MAJ1" update
    [ "$status" -eq 0 ]
    grep -q '# makefile ancien' "$DZ/Makefile"
    [ "$(sed -n '1p' "$DZ/.devzone.version")" = "version 0.0.1" ]
    [ ! -e "$T/reconstruction.log" ]
}

@test "v1 → v2: files replaced, old removed, backup made, user files intact" {
    printf '#!/usr/bin/env bash\necho ancien\n' >"$T/v1/manage/scripts/ancien.sh"
    printf 'nouveau\n' >"$T/v2/.devcontainer/nouveau.txt"
    create_v1
    mkdir -p "$DZ/workspace/projet"
    printf 'projet\n' >"$DZ/workspace/projet/fichier"
    printf 'ia=on\n' >"$DZ/.devzone.modules"
    printf 'secret\n' >"$DZ/.password"
    printf 'app\n' >"$DZ/.app"
    printf 'journal\n' >"$DZ/.devzone.log"
    cd "$DZ"
    run bash "$MAJ" update --sans-reconstruire
    [ "$status" -eq 0 ]
    grep -q '# makefile nouveau' "$DZ/Makefile"
    grep -qx 'nouveau' "$DZ/.devcontainer/nouveau.txt"
    [ ! -e "$DZ/manage/scripts/ancien.sh" ]
    [ "$(sed -n '1p' "$DZ/.devzone.version")" = "version 0.0.2" ]
    backup="$(backup_of)"
    [ -n "$backup" ]
    grep -q '# makefile ancien' "$backup/Makefile"
    grep -q 'echo ancien' "$backup/manage/scripts/ancien.sh"
    [ "$(cat "$DZ/workspace/projet/fichier")" = projet ]
    [ "$(cat "$DZ/.devzone.modules")" = 'ia=on' ]
    [ "$(cat "$DZ/.password")" = secret ]
    [ "$(cat "$DZ/.app")" = app ]
    [ "$(cat "$DZ/.devzone.log")" = journal ]
    [ ! -e "$T/reconstruction.log" ]
}

@test "modified file without --yes and without terminal → refused with exit 1, nothing touched" {
    create_v1
    printf 'modifie a la main\n' >"$DZ/Makefile"
    cd "$DZ"
    run bash "$MAJ" update
    [ "$status" -eq 1 ]
    [[ "$output" == *"Makefile"* ]] || false
    [[ "$output" == *"--yes"* ]] || false
    [ "$(cat "$DZ/Makefile")" = 'modifie a la main' ]
    [ "$(sed -n '1p' "$DZ/.devzone.version")" = "version 0.0.1" ]
    [ ! -e "$DZ/.devzone.backup" ]
    [ ! -e "$T/reconstruction.log" ]
}

@test "modified file with --yes → backed up, then replaced" {
    create_v1
    printf 'modifie a la main\n' >"$DZ/Makefile"
    cd "$DZ"
    run bash "$MAJ" update --yes
    [ "$status" -eq 0 ]
    grep -q '# makefile nouveau' "$DZ/Makefile"
    backup="$(backup_of)"
    [ -n "$backup" ]
    [ "$(cat "$backup/Makefile")" = 'modifie a la main' ]
    [[ "$output" == *"Sauvegarde :"* ]] || false
    [ ! -e "$T/reconstruction.log" ]
}

@test "update: .argocd.conf is never replaced nor backed up" {
    create_v1
    printf '[argocd]\n    repo = https://github.com/tester/devzone-argocd.git\n' >"$DZ/.argocd.conf"
    cd "$DZ"
    run bash "$MAJ" update --yes --sans-reconstruire
    [ "$status" -eq 0 ]
    grep -q '^    repo = https://github.com/tester/devzone-argocd.git$' "$DZ/.argocd.conf"
    [ ! -e "$DZ/.devzone.backup/.argocd.conf" ]
}

@test "scripts/ created by the user with a manifest: kept intact" {
    create_v1
    mkdir -p "$DZ/scripts"
    printf '#!/usr/bin/env bash\necho moi\n' >"$DZ/scripts/mon-outil.sh"
    cd "$DZ"
    run bash "$MAJ" update --sans-reconstruire
    [ "$status" -eq 0 ]
    [ "$(cat "$DZ/scripts/mon-outil.sh")" = '#!/usr/bin/env bash
echo moi' ]
    backup="$(backup_of)"
    [ ! -e "$backup/scripts/mon-outil.sh" ]
    [ "$(sed -n '1p' "$DZ/.devzone.version")" = "version 0.0.2" ]
}

@test "scripts/ created by the user without a manifest: kept intact" {
    create_v1
    rm "$DZ/.devzone.version"
    mkdir -p "$DZ/scripts"
    printf 'mon outil\n' >"$DZ/scripts/mon-outil.sh"
    cd "$DZ"
    run bash "$MAJ" update --yes --sans-reconstruire
    [ "$status" -eq 0 ]
    [ "$(cat "$DZ/scripts/mon-outil.sh")" = 'mon outil' ]
    [ "$(sed -n '1p' "$DZ/.devzone.version")" = "version 0.0.2" ]
}

@test "old devzone scripts/ with a user file: only the devzone files are removed" {
    create_v1
    mkdir -p "$DZ/scripts"
    printf 'vieux desinstaller\n' >"$DZ/scripts/uninstall.sh"
    printf 'vieux lancer\n' >"$DZ/scripts/launch.sh"
    printf 'mon outil\n' >"$DZ/scripts/mon-outil.sh"
    cd "$DZ"
    run bash "$MAJ" update --yes --sans-reconstruire
    [ "$status" -eq 0 ]
    [ ! -e "$DZ/scripts/uninstall.sh" ]
    [ ! -e "$DZ/scripts/launch.sh" ]
    [ "$(cat "$DZ/scripts/mon-outil.sh")" = 'mon outil' ]
    backup="$(backup_of)"
    [ "$(cat "$backup/scripts/uninstall.sh")" = 'vieux desinstaller' ]
    [ "$(cat "$backup/scripts/launch.sh")" = 'vieux lancer' ]
    [ ! -e "$backup/scripts/mon-outil.sh" ]
}

@test "old core/ recognized: known files backed up, then the tree removed" {
    create_v1
    mkdir -p "$DZ/core/scripts" "$DZ/core/test" "$DZ/core/docs"
    printf 'vieux devzone\n' >"$DZ/core/devzone"
    printf 'vieux desinstaller\n' >"$DZ/core/scripts/uninstall.sh"
    printf 'vieux test\n' >"$DZ/core/test/ancien.bats"
    printf 'vieille doc\n' >"$DZ/core/docs/ancien.md"
    cd "$DZ"
    run bash "$MAJ" update --yes --sans-reconstruire
    [ "$status" -eq 0 ]
    [ ! -e "$DZ/core" ]
    backup="$(backup_of)"
    [ "$(cat "$backup/core/devzone")" = 'vieux devzone' ]
    [ "$(cat "$backup/core/scripts/uninstall.sh")" = 'vieux desinstaller' ]
    [ "$(cat "$backup/core/test/ancien.bats")" = 'vieux test' ]
    [ "$(cat "$backup/core/docs/ancien.md")" = 'vieille doc' ]
}

@test "old core/ recognized without a manifest: unknown file kept, known files backed up" {
    create_v1
    rm "$DZ/.devzone.version"
    mkdir -p "$DZ/core/scripts" "$DZ/core/autre" "$DZ/workspace/projet"
    printf 'vieux desinstaller\n' >"$DZ/core/scripts/uninstall.sh"
    printf 'fichier a moi\n' >"$DZ/core/autre/mon-fichier"
    printf 'projet\n' >"$DZ/workspace/projet/fichier"
    cd "$DZ"
    run bash "$MAJ" update --yes --sans-reconstruire
    [ "$status" -eq 0 ]
    [[ "$output" == *"inconnue"* ]] || false
    [ ! -e "$DZ/core/scripts" ]
    [ "$(cat "$DZ/core/autre/mon-fichier")" = 'fichier a moi' ]
    backup="$(backup_of)"
    [ "$(cat "$backup/core/scripts/uninstall.sh")" = 'vieux desinstaller' ]
    [ ! -e "$backup/core/autre/mon-fichier" ]
    [ "$(cat "$DZ/workspace/projet/fichier")" = projet ]
    [ "$(sed -n '1p' "$DZ/.devzone.version")" = "version 0.0.2" ]
}

@test "old trees without a terminal: refused, nothing touched" {
    create_v1
    mkdir -p "$DZ/scripts" "$DZ/core/scripts"
    printf 'vieux desinstaller\n' >"$DZ/scripts/uninstall.sh"
    printf 'vieux lancer\n' >"$DZ/scripts/launch.sh"
    printf 'mon outil\n' >"$DZ/scripts/mon-outil.sh"
    printf 'vieux devzone\n' >"$DZ/core/devzone"
    printf 'vieux core\n' >"$DZ/core/scripts/uninstall.sh"
    cd "$DZ"
    run bash "$MAJ" update
    [ "$status" -eq 1 ]
    [[ "$output" == *"scripts/uninstall.sh"* ]] || false
    [[ "$output" == *"--yes"* ]] || false
    [ "$(cat "$DZ/scripts/uninstall.sh")" = 'vieux desinstaller' ]
    [ "$(cat "$DZ/scripts/launch.sh")" = 'vieux lancer' ]
    [ "$(cat "$DZ/scripts/mon-outil.sh")" = 'mon outil' ]
    [ "$(cat "$DZ/core/devzone")" = 'vieux devzone' ]
    [ "$(cat "$DZ/core/scripts/uninstall.sh")" = 'vieux core' ]
    [ "$(sed -n '1p' "$DZ/.devzone.version")" = "version 0.0.1" ]
    [ ! -e "$DZ/.devzone.backup" ]
}

@test "old folder without a manifest: all differing files are modified → --yes required" {
    create_v1
    rm "$DZ/.devzone.version"
    cd "$DZ"
    run bash "$MAJ" update
    [ "$status" -eq 1 ]
    [[ "$output" == *"Makefile"* ]] || false
    [ ! -e "$DZ/.devzone.backup" ]
}

@test ".gitignore completed without overwriting the custom lines" {
    create_v1
    printf 'mon-regle-a-moi\n' >>"$DZ/.gitignore"
    grep -v '^\.devzone\.backup/$' "$DZ/.gitignore" >"$T/gitignore.tmp"
    mv "$T/gitignore.tmp" "$DZ/.gitignore"
    cd "$DZ"
    run bash "$MAJ" update --sans-reconstruire
    [ "$status" -eq 0 ]
    grep -qx 'mon-regle-a-moi' "$DZ/.gitignore"
    grep -qx '.devzone.backup/' "$DZ/.gitignore"
    grep -qx 'workspace/\*' "$DZ/.gitignore"
    [ "$(grep -c '^\.devzone\.backup/$' "$DZ/.gitignore")" -eq 1 ]
}

@test "without a terminal: rebuild suggested, never started" {
    create_v1
    cd "$DZ"
    run bash "$MAJ" update --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"make -C $DZ rebuild"* ]] || false
    [ ! -e "$T/reconstruction.log" ]
}

@test "--sans-reconstruire: no rebuild, even with --yes" {
    create_v1
    cd "$DZ"
    run bash "$MAJ" update --yes --sans-reconstruire
    [ "$status" -eq 0 ]
    [[ "$output" == *"Reconstruction non lancée (--sans-reconstruire)"* ]] || false
    [ ! -e "$T/reconstruction.log" ]
}

@test "kubernetes mode: advice shown, make rebuild never offered" {
    cp "$RACINE/manage/scripts/poste.sh" "$RACINE/manage/scripts/kube-ready.sh" "$T/v2/manage/scripts/"
    create_v1
    printf 'workspace=kubernetes\n' >"$DZ/.devzone.modules"
    cd "$DZ"
    run bash "$MAJ" update --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"next devzone workspace start"* ]] || false
    [[ "$output" != *"rebuild"* ]] || false
    [ "$(cat "$DZ/.devzone.modules")" = 'workspace=kubernetes' ]
    [ ! -e "$T/reconstruction.log" ]
}

@test "poisoned manifest: ../dehors/secret refused" {
    poisoned_manifest '../dehors/secret'
}

@test "poisoned manifest: /etc/x refused" {
    poisoned_manifest '/etc/x'
}

@test "poisoned manifest: a/../../dehors/secret refused" {
    poisoned_manifest 'a/../../dehors/secret'
}

@test "poisoned manifest: .devcontainer/../../dehors/secret refused" {
    poisoned_manifest '.devcontainer/../../dehors/secret'
}

@test "poisoned manifest: workspace/x outside the managed folders refused" {
    create_v1
    mkdir -p "$T/dehors" "$DZ/workspace"
    printf 'secret\n' >"$T/dehors/secret"
    printf 'a moi\n' >"$DZ/workspace/x"
    printf '%064d  %s\n' 0 'workspace/x' >>"$DZ/.devzone.version"
    cd "$DZ"
    run bash "$MAJ" update --yes --sans-reconstruire
    [ "$status" -eq 0 ]
    [ "$(cat "$T/dehors/secret")" = secret ]
    [ "$(cat "$DZ/workspace/x")" = 'a moi' ]
    [[ "$output" == *"devzone : manifeste : chemin refusé : workspace/x"* ]] || false
}

@test "poisoned manifest: outgoing symbolic link refused" {
    create_v1
    mkdir -p "$T/dehors"
    printf 'secret\n' >"$T/dehors/secret"
    ln -s "$T/dehors" "$DZ/.devcontainer/lien"
    printf '%064d  %s\n' 0 '.devcontainer/lien/secret' >>"$DZ/.devzone.version"
    cd "$DZ"
    run bash "$MAJ" update --yes --sans-reconstruire
    [ "$status" -eq 0 ]
    [ "$(cat "$T/dehors/secret")" = secret ]
    [[ "$output" == *"devzone : manifeste : chemin refusé : .devcontainer/lien/secret"* ]] || false
}

@test "symbolic link on the last element: replaced by a real file, target intact" {
    create_v1
    mkdir -p "$T/dehors"
    printf 'intact\n' >"$T/dehors/cible"
    rm -f "$DZ/.devcontainer/devcontainer.json"
    ln -s "$T/dehors/cible" "$DZ/.devcontainer/devcontainer.json"
    cd "$DZ"
    run bash "$MAJ" update --yes --sans-reconstruire
    [ "$status" -eq 0 ]
    [ "$(cat "$T/dehors/cible")" = intact ]
    [ ! -L "$DZ/.devcontainer/devcontainer.json" ] || false
    [ "$(cat "$DZ/.devcontainer/devcontainer.json")" = '{"marque":"nouveau"}' ]
    [[ "$output" == *"lien remplacé : .devcontainer/devcontainer.json"* ]] || false
}

@test "symbolic link: the backup keeps the link, not a copy of the target" {
    create_v1
    mkdir -p "$T/dehors"
    printf 'intact\n' >"$T/dehors/cible"
    rm -f "$DZ/.devcontainer/devcontainer.json"
    ln -s "$T/dehors/cible" "$DZ/.devcontainer/devcontainer.json"
    cd "$DZ"
    run bash "$MAJ" update --yes --sans-reconstruire
    [ "$status" -eq 0 ]
    [ -L "$(backup_of)/.devcontainer/devcontainer.json" ] || false
    [ "$(cat "$T/dehors/cible")" = intact ]
}

@test "outside a devzone folder and unknown option → refused" {
    mkdir pas-devzone
    cd pas-devzone
    run bash "$MAJ" update
    [ "$status" -eq 1 ]
    [[ "$output" == *"dossier devzone"* ]] || false
    create_v1
    cd "$DZ"
    run bash "$MAJ" update --truc
    [ "$status" -eq 1 ]
    [[ "$output" == *"option inconnue"* ]] || false
}
