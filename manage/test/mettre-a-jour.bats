#!/usr/bin/env bats
# Mise à jour d'un devzone existant (#349) : paquets factices v1 et v2 sous
# $BATS_TEST_TMPDIR. Aucune reconstruction réelle, aucun script système.

setup() {
    load commun
    relais_docker_isole
    kube_isole
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CLI="$RACINE/manage/devzone"
    T="$BATS_TEST_TMPDIR"
    cd "$T"
    export DEVZONE_SANS_DEMARRER=1
    export DEVZONE_RECONSTRUIRE="$T/reconstruire"
    printf '#!/usr/bin/env bash\necho "reconstruit" >>"%s/reconstruction.log"\n' "$T" >"$DEVZONE_RECONSTRUIRE"
    chmod +x "$DEVZONE_RECONSTRUIRE"
    fabriquer_paquet v1 0.0.1 ancien
    fabriquer_paquet v2 0.0.2 nouveau
    MAJ="$T/v2/manage/devzone"
    MAJ1="$T/v1/manage/devzone"
}

fabriquer_paquet() {
    local nom="$1" v="$2" marque="$3" dossier="$T/$1"
    mkdir -p "$dossier/.devcontainer/argocd" "$dossier/.devcontainer" "$dossier/manage/scripts"
    cp "$CLI" "$dossier/manage/devzone"
    chmod +x "$dossier/manage/devzone"
    cp "$RACINE/.devcontainer/argocd/conf.sh" "$dossier/.devcontainer/argocd/conf.sh"
    printf '{"name":"devzone","version":"%s"}\n' "$v" >"$dossier/package.json"
    printf '# makefile %s\n' "$marque" >"$dossier/Makefile"
    printf '*.sh text eol=lf\n' >"$dossier/.gitattributes"
    printf '# devzone %s\n' "$marque" >"$dossier/README.md"
    printf 'licence %s\n' "$marque" >"$dossier/LICENSE"
    printf '{"marque":"%s"}\n' "$marque" >"$dossier/.devcontainer/devcontainer.json"
    printf '{"marque":"%s"}\n' "$marque" >"$dossier/.devcontainer/devcontainer-lock.json"
    printf '#!/usr/bin/env bash\necho %s\n' "$marque" >"$dossier/.devcontainer/devzone"
    printf '#!/usr/bin/env bash\necho lancer-%s\n' "$marque" >"$dossier/manage/scripts/lancer.sh"
    printf '#!/usr/bin/env bash\necho desinstaller-%s\n' "$marque" >"$dossier/manage/scripts/desinstaller.sh"
    chmod +x "$dossier/.devcontainer/devzone" "$dossier/manage/scripts/lancer.sh" "$dossier/manage/scripts/desinstaller.sh"
}

creer_v1() {
    DZ="$T/devzone"
    bash "$T/v1/manage/devzone" "$DZ" >/dev/null
}

sauvegarde_de() {
    find "$DZ/.devzone.sauvegarde" -mindepth 1 -maxdepth 1 -type d | head -1
}

# Manifeste piégé : le chemin doit être ignoré avec un avertissement, et le
# fichier hors du dossier devzone doit survivre à la mise à jour.
pieger_manifeste() {
    local rel="$1"
    creer_v1
    mkdir -p "$T/dehors"
    printf 'secret\n' >"$T/dehors/secret"
    printf '%064d  %s\n' 0 "$rel" >>"$DZ/.devzone.version"
    cd "$DZ"
    run bash "$MAJ" mettre-a-jour --oui --sans-reconstruire
    [ "$status" -eq 0 ]
    [ "$(cat "$T/dehors/secret")" = secret ]
    [[ "$output" == *"devzone : manifeste : chemin refusé : $rel"* ]] || false
}

@test "création : .devzone.version porte la version et une empreinte par fichier copié" {
    creer_v1
    [ "$(sed -n '1p' "$DZ/.devzone.version")" = "version 0.0.1" ]
    for f in .devcontainer/devcontainer.json .devcontainer/devzone Makefile .gitattributes manage/scripts/lancer.sh manage/scripts/desinstaller.sh README.md LICENSE; do
        attendue="$(node -e 'const fs = require("fs"), crypto = require("crypto"); const h = crypto.createHash("sha256"); h.update(fs.readFileSync(process.argv[1])); process.stdout.write(h.digest("hex"))' "$DZ/$f")"
        grep -qxF "$attendue  $f" "$DZ/.devzone.version" || { echo "empreinte absente : $f"; return 1; }
    done
    ! grep -q 'manage/devzone' "$DZ/.devzone.version" || false
}

@test "déjà à jour : même version, fichiers présents → code 0, rien touché, npx conseillé" {
    creer_v1
    avant="$(cat "$DZ/.devzone.version")"
    cd "$DZ"
    run bash "$MAJ1" mettre-a-jour
    [ "$status" -eq 0 ]
    [[ "$output" == *"déjà à jour"* ]] || false
    [[ "$output" == *"npx devzone@latest mettre-a-jour"* ]] || false
    [ "$(cat "$DZ/.devzone.version")" = "$avant" ]
    [ ! -e "$DZ/.devzone.sauvegarde" ]
    [ ! -e "$T/reconstruction.log" ]
}

@test "même version mais fichier du paquet manquant → le fichier est rétabli" {
    creer_v1
    rm "$DZ/Makefile"
    cd "$DZ"
    run bash "$MAJ1" mettre-a-jour
    [ "$status" -eq 0 ]
    grep -q '# makefile ancien' "$DZ/Makefile"
    [ "$(sed -n '1p' "$DZ/.devzone.version")" = "version 0.0.1" ]
    [ ! -e "$T/reconstruction.log" ]
}

@test "v1 → v2 : fichiers remplacés, ancien supprimé, sauvegarde, utilisateur intact" {
    printf '#!/usr/bin/env bash\necho ancien\n' >"$T/v1/manage/scripts/ancien.sh"
    printf 'nouveau\n' >"$T/v2/.devcontainer/nouveau.txt"
    creer_v1
    mkdir -p "$DZ/workspace/projet"
    printf 'projet\n' >"$DZ/workspace/projet/fichier"
    printf 'ia=on\n' >"$DZ/.devzone.modules"
    printf 'secret\n' >"$DZ/.password"
    printf 'app\n' >"$DZ/.app"
    printf 'journal\n' >"$DZ/.devzone.log"
    cd "$DZ"
    run bash "$MAJ" mettre-a-jour --sans-reconstruire
    [ "$status" -eq 0 ]
    grep -q '# makefile nouveau' "$DZ/Makefile"
    grep -qx 'nouveau' "$DZ/.devcontainer/nouveau.txt"
    [ ! -e "$DZ/manage/scripts/ancien.sh" ]
    [ "$(sed -n '1p' "$DZ/.devzone.version")" = "version 0.0.2" ]
    sauvegarde="$(sauvegarde_de)"
    [ -n "$sauvegarde" ]
    grep -q '# makefile ancien' "$sauvegarde/Makefile"
    grep -q 'echo ancien' "$sauvegarde/manage/scripts/ancien.sh"
    [ "$(cat "$DZ/workspace/projet/fichier")" = projet ]
    [ "$(cat "$DZ/.devzone.modules")" = 'ia=on' ]
    [ "$(cat "$DZ/.password")" = secret ]
    [ "$(cat "$DZ/.app")" = app ]
    [ "$(cat "$DZ/.devzone.log")" = journal ]
    [ ! -e "$T/reconstruction.log" ]
}

@test "fichier modifié sans --oui et sans terminal → refus code 1, rien touché" {
    creer_v1
    printf 'modifie a la main\n' >"$DZ/Makefile"
    cd "$DZ"
    run bash "$MAJ" mettre-a-jour
    [ "$status" -eq 1 ]
    [[ "$output" == *"Makefile"* ]] || false
    [[ "$output" == *"--oui"* ]] || false
    [ "$(cat "$DZ/Makefile")" = 'modifie a la main' ]
    [ "$(sed -n '1p' "$DZ/.devzone.version")" = "version 0.0.1" ]
    [ ! -e "$DZ/.devzone.sauvegarde" ]
    [ ! -e "$T/reconstruction.log" ]
}

@test "fichier modifié avec --oui → sauvegardé puis remplacé" {
    creer_v1
    printf 'modifie a la main\n' >"$DZ/Makefile"
    cd "$DZ"
    run bash "$MAJ" mettre-a-jour --oui
    [ "$status" -eq 0 ]
    grep -q '# makefile nouveau' "$DZ/Makefile"
    sauvegarde="$(sauvegarde_de)"
    [ -n "$sauvegarde" ]
    [ "$(cat "$sauvegarde/Makefile")" = 'modifie a la main' ]
    [[ "$output" == *"Sauvegarde :"* ]] || false
    [ ! -e "$T/reconstruction.log" ]
}

@test "mettre-a-jour : .argocd.conf n'est jamais remplacé ni sauvegardé" {
    creer_v1
    printf '[argocd]\n    repo = https://github.com/tester/devzone-argocd.git\n' >"$DZ/.argocd.conf"
    cd "$DZ"
    run bash "$MAJ" mettre-a-jour --oui --sans-reconstruire
    [ "$status" -eq 0 ]
    grep -q '^    repo = https://github.com/tester/devzone-argocd.git$' "$DZ/.argocd.conf"
    [ ! -e "$DZ/.devzone.sauvegarde/.argocd.conf" ]
}

@test "scripts/ créé par l'utilisateur avec manifeste : gardé intact" {
    creer_v1
    mkdir -p "$DZ/scripts"
    printf '#!/usr/bin/env bash\necho moi\n' >"$DZ/scripts/mon-outil.sh"
    cd "$DZ"
    run bash "$MAJ" mettre-a-jour --sans-reconstruire
    [ "$status" -eq 0 ]
    [ "$(cat "$DZ/scripts/mon-outil.sh")" = '#!/usr/bin/env bash
echo moi' ]
    sauvegarde="$(sauvegarde_de)"
    [ ! -e "$sauvegarde/scripts/mon-outil.sh" ]
    [ "$(sed -n '1p' "$DZ/.devzone.version")" = "version 0.0.2" ]
}

@test "scripts/ créé par l'utilisateur sans manifeste : gardé intact" {
    creer_v1
    rm "$DZ/.devzone.version"
    mkdir -p "$DZ/scripts"
    printf 'mon outil\n' >"$DZ/scripts/mon-outil.sh"
    cd "$DZ"
    run bash "$MAJ" mettre-a-jour --oui --sans-reconstruire
    [ "$status" -eq 0 ]
    [ "$(cat "$DZ/scripts/mon-outil.sh")" = 'mon outil' ]
    [ "$(sed -n '1p' "$DZ/.devzone.version")" = "version 0.0.2" ]
}

@test "ancien scripts/ de devzone avec fichier utilisateur : seuls les fichiers de devzone partent" {
    creer_v1
    mkdir -p "$DZ/scripts"
    printf 'vieux desinstaller\n' >"$DZ/scripts/desinstaller.sh"
    printf 'vieux lancer\n' >"$DZ/scripts/lancer.sh"
    printf 'mon outil\n' >"$DZ/scripts/mon-outil.sh"
    cd "$DZ"
    run bash "$MAJ" mettre-a-jour --oui --sans-reconstruire
    [ "$status" -eq 0 ]
    [ ! -e "$DZ/scripts/desinstaller.sh" ]
    [ ! -e "$DZ/scripts/lancer.sh" ]
    [ "$(cat "$DZ/scripts/mon-outil.sh")" = 'mon outil' ]
    sauvegarde="$(sauvegarde_de)"
    [ "$(cat "$sauvegarde/scripts/desinstaller.sh")" = 'vieux desinstaller' ]
    [ "$(cat "$sauvegarde/scripts/lancer.sh")" = 'vieux lancer' ]
    [ ! -e "$sauvegarde/scripts/mon-outil.sh" ]
}

@test "ancien core/ reconnu : fichiers connus sauvegardés puis arborescence retirée" {
    creer_v1
    mkdir -p "$DZ/core/scripts" "$DZ/core/test" "$DZ/core/docs"
    printf 'vieux devzone\n' >"$DZ/core/devzone"
    printf 'vieux desinstaller\n' >"$DZ/core/scripts/desinstaller.sh"
    printf 'vieux test\n' >"$DZ/core/test/ancien.bats"
    printf 'vieille doc\n' >"$DZ/core/docs/ancien.md"
    cd "$DZ"
    run bash "$MAJ" mettre-a-jour --oui --sans-reconstruire
    [ "$status" -eq 0 ]
    [ ! -e "$DZ/core" ]
    sauvegarde="$(sauvegarde_de)"
    [ "$(cat "$sauvegarde/core/devzone")" = 'vieux devzone' ]
    [ "$(cat "$sauvegarde/core/scripts/desinstaller.sh")" = 'vieux desinstaller' ]
    [ "$(cat "$sauvegarde/core/test/ancien.bats")" = 'vieux test' ]
    [ "$(cat "$sauvegarde/core/docs/ancien.md")" = 'vieille doc' ]
}

@test "ancien core/ reconnu sans manifeste : inconnu gardé, connus sauvegardés" {
    creer_v1
    rm "$DZ/.devzone.version"
    mkdir -p "$DZ/core/scripts" "$DZ/core/autre" "$DZ/workspace/projet"
    printf 'vieux desinstaller\n' >"$DZ/core/scripts/desinstaller.sh"
    printf 'fichier a moi\n' >"$DZ/core/autre/mon-fichier"
    printf 'projet\n' >"$DZ/workspace/projet/fichier"
    cd "$DZ"
    run bash "$MAJ" mettre-a-jour --oui --sans-reconstruire
    [ "$status" -eq 0 ]
    [[ "$output" == *"inconnue"* ]] || false
    [ ! -e "$DZ/core/scripts" ]
    [ "$(cat "$DZ/core/autre/mon-fichier")" = 'fichier a moi' ]
    sauvegarde="$(sauvegarde_de)"
    [ "$(cat "$sauvegarde/core/scripts/desinstaller.sh")" = 'vieux desinstaller' ]
    [ ! -e "$sauvegarde/core/autre/mon-fichier" ]
    [ "$(cat "$DZ/workspace/projet/fichier")" = projet ]
    [ "$(sed -n '1p' "$DZ/.devzone.version")" = "version 0.0.2" ]
}

@test "anciennes arborescences sans terminal : refus, rien n'est touché" {
    creer_v1
    mkdir -p "$DZ/scripts" "$DZ/core/scripts"
    printf 'vieux desinstaller\n' >"$DZ/scripts/desinstaller.sh"
    printf 'vieux lancer\n' >"$DZ/scripts/lancer.sh"
    printf 'mon outil\n' >"$DZ/scripts/mon-outil.sh"
    printf 'vieux devzone\n' >"$DZ/core/devzone"
    printf 'vieux core\n' >"$DZ/core/scripts/desinstaller.sh"
    cd "$DZ"
    run bash "$MAJ" mettre-a-jour
    [ "$status" -eq 1 ]
    [[ "$output" == *"scripts/desinstaller.sh"* ]] || false
    [[ "$output" == *"--oui"* ]] || false
    [ "$(cat "$DZ/scripts/desinstaller.sh")" = 'vieux desinstaller' ]
    [ "$(cat "$DZ/scripts/lancer.sh")" = 'vieux lancer' ]
    [ "$(cat "$DZ/scripts/mon-outil.sh")" = 'mon outil' ]
    [ "$(cat "$DZ/core/devzone")" = 'vieux devzone' ]
    [ "$(cat "$DZ/core/scripts/desinstaller.sh")" = 'vieux core' ]
    [ "$(sed -n '1p' "$DZ/.devzone.version")" = "version 0.0.1" ]
    [ ! -e "$DZ/.devzone.sauvegarde" ]
}

@test "ancien dossier sans manifeste : tous les fichiers différents sont modifiés → --oui requis" {
    creer_v1
    rm "$DZ/.devzone.version"
    cd "$DZ"
    run bash "$MAJ" mettre-a-jour
    [ "$status" -eq 1 ]
    [[ "$output" == *"Makefile"* ]] || false
    [ ! -e "$DZ/.devzone.sauvegarde" ]
}

@test ".gitignore complété sans écraser les lignes personnalisées" {
    creer_v1
    printf 'mon-regle-a-moi\n' >>"$DZ/.gitignore"
    grep -v '^\.devzone\.sauvegarde/$' "$DZ/.gitignore" >"$T/gitignore.tmp"
    mv "$T/gitignore.tmp" "$DZ/.gitignore"
    cd "$DZ"
    run bash "$MAJ" mettre-a-jour --sans-reconstruire
    [ "$status" -eq 0 ]
    grep -qx 'mon-regle-a-moi' "$DZ/.gitignore"
    grep -qx '.devzone.sauvegarde/' "$DZ/.gitignore"
    grep -qx 'workspace/\*' "$DZ/.gitignore"
    [ "$(grep -c '^\.devzone\.sauvegarde/$' "$DZ/.gitignore")" -eq 1 ]
}

@test "sans terminal : reconstruction indiquée, jamais lancée" {
    creer_v1
    cd "$DZ"
    run bash "$MAJ" mettre-a-jour --oui
    [ "$status" -eq 0 ]
    [[ "$output" == *"make -C $DZ rebuild"* ]] || false
    [ ! -e "$T/reconstruction.log" ]
}

@test "--sans-reconstruire : pas de reconstruction, même avec --oui" {
    creer_v1
    cd "$DZ"
    run bash "$MAJ" mettre-a-jour --oui --sans-reconstruire
    [ "$status" -eq 0 ]
    [[ "$output" == *"Reconstruction non lancée (--sans-reconstruire)"* ]] || false
    [ ! -e "$T/reconstruction.log" ]
}

@test "mode kubernetes : conseil affiché, make rebuild jamais proposé" {
    cp "$RACINE/manage/scripts/poste.sh" "$T/v2/manage/scripts/poste.sh"
    creer_v1
    printf 'workspace=kubernetes\n' >"$DZ/.devzone.modules"
    cd "$DZ"
    run bash "$MAJ" mettre-a-jour --oui
    [ "$status" -eq 0 ]
    [[ "$output" == *"prochain devzone workspace demarrer"* ]] || false
    [[ "$output" != *"rebuild"* ]] || false
    [ "$(cat "$DZ/.devzone.modules")" = 'workspace=kubernetes' ]
    [ ! -e "$T/reconstruction.log" ]
}

@test "manifeste piégé : ../dehors/secret refusé" {
    pieger_manifeste '../dehors/secret'
}

@test "manifeste piégé : /etc/x refusé" {
    pieger_manifeste '/etc/x'
}

@test "manifeste piégé : a/../../dehors/secret refusé" {
    pieger_manifeste 'a/../../dehors/secret'
}

@test "manifeste piégé : .devcontainer/../../dehors/secret refusé" {
    pieger_manifeste '.devcontainer/../../dehors/secret'
}

@test "manifeste piégé : workspace/x hors des dossiers gérés refusé" {
    creer_v1
    mkdir -p "$T/dehors" "$DZ/workspace"
    printf 'secret\n' >"$T/dehors/secret"
    printf 'a moi\n' >"$DZ/workspace/x"
    printf '%064d  %s\n' 0 'workspace/x' >>"$DZ/.devzone.version"
    cd "$DZ"
    run bash "$MAJ" mettre-a-jour --oui --sans-reconstruire
    [ "$status" -eq 0 ]
    [ "$(cat "$T/dehors/secret")" = secret ]
    [ "$(cat "$DZ/workspace/x")" = 'a moi' ]
    [[ "$output" == *"devzone : manifeste : chemin refusé : workspace/x"* ]] || false
}

@test "manifeste piégé : lien symbolique sortant refusé" {
    creer_v1
    mkdir -p "$T/dehors"
    printf 'secret\n' >"$T/dehors/secret"
    ln -s "$T/dehors" "$DZ/.devcontainer/lien"
    printf '%064d  %s\n' 0 '.devcontainer/lien/secret' >>"$DZ/.devzone.version"
    cd "$DZ"
    run bash "$MAJ" mettre-a-jour --oui --sans-reconstruire
    [ "$status" -eq 0 ]
    [ "$(cat "$T/dehors/secret")" = secret ]
    [[ "$output" == *"devzone : manifeste : chemin refusé : .devcontainer/lien/secret"* ]] || false
}

@test "lien symbolique sur le dernier élément : remplacé par un vrai fichier, cible intacte" {
    creer_v1
    mkdir -p "$T/dehors"
    printf 'intact\n' >"$T/dehors/cible"
    rm -f "$DZ/.devcontainer/devcontainer.json"
    ln -s "$T/dehors/cible" "$DZ/.devcontainer/devcontainer.json"
    cd "$DZ"
    run bash "$MAJ" mettre-a-jour --oui --sans-reconstruire
    [ "$status" -eq 0 ]
    [ "$(cat "$T/dehors/cible")" = intact ]
    [ ! -L "$DZ/.devcontainer/devcontainer.json" ] || false
    [ "$(cat "$DZ/.devcontainer/devcontainer.json")" = '{"marque":"nouveau"}' ]
    [[ "$output" == *"lien remplacé : .devcontainer/devcontainer.json"* ]] || false
}

@test "lien symbolique : la sauvegarde garde le lien, pas une copie de la cible" {
    creer_v1
    mkdir -p "$T/dehors"
    printf 'intact\n' >"$T/dehors/cible"
    rm -f "$DZ/.devcontainer/devcontainer.json"
    ln -s "$T/dehors/cible" "$DZ/.devcontainer/devcontainer.json"
    cd "$DZ"
    run bash "$MAJ" mettre-a-jour --oui --sans-reconstruire
    [ "$status" -eq 0 ]
    [ -L "$(sauvegarde_de)/.devcontainer/devcontainer.json" ] || false
    [ "$(cat "$T/dehors/cible")" = intact ]
}

@test "hors d'un dossier devzone et option inconnue → refus" {
    mkdir pas-devzone
    cd pas-devzone
    run bash "$MAJ" mettre-a-jour
    [ "$status" -eq 1 ]
    [[ "$output" == *"dossier devzone"* ]] || false
    creer_v1
    cd "$DZ"
    run bash "$MAJ" mettre-a-jour --truc
    [ "$status" -eq 1 ]
    [[ "$output" == *"option inconnue"* ]] || false
}
