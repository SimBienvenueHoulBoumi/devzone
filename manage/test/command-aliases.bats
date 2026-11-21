#!/usr/bin/env bats
# Noms retirés de la CLI devzone (#695) : chaque ancien nom (commande,
# sous-commande, option) est refusé sur stderr avec son nouveau nom, code 1,
# sans rien faire ni créer. Les noms anglais marchent sans avertissement.

setup() {
    bats_require_minimum_version 1.5.0
    load commun
    kube_isole
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CLI="$RACINE/manage/devzone"
    WS="$RACINE/manage/workspace.sh"
    ALIASES="$RACINE/.devcontainer/command-aliases.sh"
    T="$BATS_TEST_TMPDIR"
    mkdir -p "$T/bin"
    cat >"$T/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
echo "kubectl $*" >>"$T/kubectl.log"
exit 0
KUBE
    cat >"$T/bin/helm" <<'HELM'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
echo "helm $*" >>"$T/helm.log"
exit 0
HELM
    chmod +x "$T/bin/kubectl" "$T/bin/helm"
    export PATH="$T/bin:$PATH"
    cd "$T" || return 1
}

# refus <commande> <args...> : reject_renamed chargé depuis le fichier d'alias
refus() {
    bash -c ". '$ALIASES'; reject_renamed \"\$@\"" _ "$@"
}

@test "renamed_command: chaque commande retirée donne son nouveau nom, code 1" {
    while IFS='|' read -r old new; do
        [ -n "$old" ] || continue
        run --separate-stderr refus "$old"
        [ "$status" -eq 1 ] || { echo "code $status pour $old"; false; }
        [ "$stderr" = "✖ « $old » was renamed: devzone $new" ] || { echo "message pour $old : $stderr"; false; }
        [ -z "$output" ] || false
    done <<'TABLE'
actif|is-enabled
activer|enable
desactiver|disable
ia|ai
aide|help
appliquer|apply
catalogue|catalog
demarrer|start
arreter|stop
etat|status
mots-de-passe|passwords
paquets|packages
plateforme|platform
reparer|repair
utiliser|use
mettre-a-jour|update
desinstaller|uninstall
copier-vers|workspace copy-to
copier-depuis|workspace copy-from
TABLE
}

@test "renamed_subcommand: chaque sous-commande retirée donne son nouveau nom, code 1" {
    while IFS='|' read -r command old new; do
        [ -n "$command" ] || continue
        run --separate-stderr refus "$command" "$old"
        [ "$status" -eq 1 ] || { echo "code $status pour $command $old"; false; }
        [ "$stderr" = "✖ « $old » was renamed: devzone $command $new" ] || { echo "message : $stderr"; false; }
    done <<'TABLE'
postgres|creer|create
postgres|liste|list
postgres|supprimer|delete
postgres|supprimer-donnees|delete-data
postgres|etat|status
postgres|installer|install
postgres|desinstaller|uninstall
postgres|relais-lancer|relay-start
postgres|relais-arreter|relay-stop
postgres|autoriser|authorize
postgres|interdire|forbid
mysql|creer|create
mysql|liste|list
mysql|supprimer|delete
mysql|supprimer-donnees|delete-data
mysql|installer|install
mysql|desinstaller|uninstall
mysql|autoriser|authorize
mysql|interdire|forbid
gitlab|migrer|migrate
gitlab|nouveau-mdp|new-password
gitlab|etat|status
gitlab|installer|install
gitlab|desinstaller|uninstall
gitlab|relais-lancer|relay-start
gitlab|relais-arreter|relay-stop
gitlab|relais-etat|relay-status
argocd|etat|status
argocd|installer|install
argocd|desinstaller|uninstall
argocd|relais-lancer|relay-start
argocd|relais-arreter|relay-stop
packages|ajouter|add
packages|retirer|remove
packages|appliquer|apply
packages|lister|list
catalog|synchroniser|sync
catalog|appliquer|apply
catalog|lister|list
catalog|desinstaller|remove
port|ouvrir|open
port|fermer|close
port|liste|list
port|relancer|restart
port|exclure|exclude
port|inclure|include
workspace|demarrer|start
workspace|mettre-a-jour|update
workspace|arreter|stop
workspace|etat|status
workspace|copier-vers|copy-to
workspace|copier-depuis|copy-from
workspace|aide|help
workspace ports|demarrer|start
workspace ports|arreter|stop
workspace ports|etat|status
TABLE
}

@test "renamed_option: chaque option retirée donne la nouvelle, code 1" {
    while IFS='|' read -r old new; do
        [ -n "$old" ] || continue
        run --separate-stderr refus postgres create proj "$old"
        [ "$status" -eq 1 ] || { echo "code $status pour $old"; false; }
        [ "$stderr" = "✖ « $old » was renamed: $new" ] || { echo "message : $stderr"; false; }
    done <<'TABLE'
--fermer|--close
--supprimer|--delete
--nouveau-mdp|--new-password
--oui|--yes
--confirmer|--confirm
--contexte|--context
TABLE
}

@test "reject_renamed: noms anglais, inconnus et absence d'argument passent sans message" {
    run --separate-stderr refus enable ai --yes
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    run --separate-stderr refus nexistepas
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    run --separate-stderr refus
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
}

@test "reject_renamed: un module nommé comme un ancien nom n'est pas refusé" {
    run --separate-stderr refus enable ai
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
}

@test "hôte : chaque ancien nom est refusé, code 1, aucun dossier créé" {
    for old in activer desactiver appliquer actif reparer demarrer arreter etat utiliser \
        catalogue paquets mots-de-passe plateforme ia aide mettre-a-jour desinstaller \
        copier-vers; do
        run --separate-stderr bash "$CLI" "$old"
        [ "$status" -eq 1 ] || { echo "code $status pour $old"; false; }
        [[ "$stderr" == *"« $old » was renamed: devzone "* ]] || { echo "message : $stderr"; false; }
        [ -z "$output" ] || false
        [ ! -e "$old" ] || { echo "dossier créé : $old"; false; }
    done
}

@test "hôte : une sous-commande ou une option retirée est refusée avec le nouveau nom" {
    run --separate-stderr bash "$CLI" argocd etat
    [ "$status" -eq 1 ]
    [ "$stderr" = "✖ « etat » was renamed: devzone argocd status" ]
    run --separate-stderr bash "$CLI" update --oui
    [ "$status" -eq 1 ]
    [ "$stderr" = "✖ « --oui » was renamed: --yes" ]
    [ ! -e argocd ]
}

@test "conteneur : un ancien nom est refusé avant toute action" {
    run --separate-stderr bash "$RACINE/.devcontainer/devzone" activer ia
    [ "$status" -eq 1 ]
    [ "$stderr" = "✖ « activer » was renamed: devzone enable" ]
    run --separate-stderr bash "$RACINE/.devcontainer/devzone" catalogue lister
    [ "$status" -eq 1 ]
    [ "$stderr" = "✖ « catalogue » was renamed: devzone catalog" ]
}

@test "workspace.sh: les anciens noms sont refusés, sans appel à kubectl ni docker" {
    cat >"$T/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
echo "docker $*" >>"$BATS_TEST_TMPDIR/docker.log"
exit 1
DOCKER
    chmod +x "$T/bin/docker"
    run --separate-stderr bash "$WS" etat
    [ "$status" -eq 1 ]
    [ "$stderr" = "✖ « etat » was renamed: devzone workspace status" ]
    run --separate-stderr bash "$WS" copier-vers
    [ "$status" -eq 1 ]
    [ "$stderr" = "✖ « copier-vers » was renamed: devzone workspace copy-to" ]
    run --separate-stderr bash "$WS" ports demarrer
    [ "$status" -eq 1 ]
    [ "$stderr" = "✖ « demarrer » was renamed: devzone workspace ports start" ]
    [ ! -e "$T/kubectl.log" ]
    [ ! -e "$T/docker.log" ]
}

@test "workspace.sh: les noms anglais marchent sans avertissement" {
    : >"$T/kubectl.log"
    run --separate-stderr bash "$WS" status
    [ "$status" -eq 0 ]
    grep -q -- "get pods" "$T/kubectl.log" || false
    [[ "$stderr" != *"renomm"* ]] || false
}

@test "hôte : les noms anglais marchent sans avertissement" {
    run --separate-stderr bash "$CLI" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--version"* ]] || false
    [[ "$stderr" != *"renomm"* ]] || false
    run --separate-stderr bash "$CLI" update
    [ "$status" -eq 1 ]
    [[ "$stderr" == *".devcontainer introuvable"* ]] || false
    [[ "$stderr" != *"renomm"* ]] || false
    run --separate-stderr bash "$CLI" uninstall
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"introuvable"* ]] || false
    [[ "$stderr" != *"renomm"* ]] || false
}

@test "manage/devzone enable x is refused on the host like a container command" {
    run bash "$CLI" enable x
    [ "$status" -eq 2 ]
    [[ "$output" == *"commande du conteneur"* ]] || false
    [ ! -e enable ]
}

@test "manage/devzone copied without command-aliases.sh still answers --version" {
    mkdir -p "$T/paquet/manage"
    cp "$CLI" "$T/paquet/manage/devzone"
    run bash "$T/paquet/manage/devzone" --version
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "manage/devzone stop creates ./stop" {
    DEVZONE_NO_START=1 run bash "$CLI" stop
    [ "$status" -eq 0 ]
    [ -d stop ]
}

# Noms retirés en 3.0 (#735) : refusés, code 1, message sans le mot docker,
# aucune sortie, aucun dossier créé
removed_refus() {
    run --separate-stderr refus "$@"
    [ "$status" -eq 1 ] || { echo "code $status pour $*"; false; }
    [[ "$stderr" == *"was removed in devzone 3.0"* ]] || { echo "message : $stderr"; false; }
    [[ "$stderr" != *docker* ]] || false
    [ -z "$output" ] || false
}

@test "migrer : retiré, refusé en top-level et sous workspace, rien créé" {
    removed_refus migrer
    removed_refus workspace migrer
    run --separate-stderr bash "$CLI" migrer
    [ "$status" -eq 1 ]
    [ ! -e migrer ]
    run --separate-stderr bash "$WS" migrer
    [ "$status" -eq 1 ]
    [ ! -e "$T/kubectl.log" ]
}

@test "revenir : retiré, refusé en top-level et sous workspace, rien créé" {
    removed_refus revenir
    removed_refus workspace revenir
    run --separate-stderr bash "$CLI" revenir
    [ "$status" -eq 1 ]
    [ ! -e revenir ]
    run --separate-stderr bash "$WS" revenir --bring-back
    [ "$status" -eq 1 ]
    [ ! -e "$T/kubectl.log" ]
}

@test "nettoyer-docker : retiré, refusé en top-level et sous workspace, rien créé" {
    removed_refus nettoyer-docker
    removed_refus workspace nettoyer-docker
    run --separate-stderr bash "$CLI" nettoyer-docker
    [ "$status" -eq 1 ]
    [ ! -e nettoyer-docker ]
    run --separate-stderr bash "$WS" nettoyer-docker --yes
    [ "$status" -eq 1 ]
    [ ! -e "$T/kubectl.log" ]
}

@test "--rapatrier : option retirée, refusée avec code 1" {
    removed_refus workspace revert --rapatrier
    removed_refus workspace copy-to --rapatrier
    run --separate-stderr bash "$WS" revert --rapatrier
    [ "$status" -eq 1 ]
    [ ! -e "$T/kubectl.log" ]
}

@test "agent: old subcommand etat is refused, code 1, with the new name state" {
    run --separate-stderr refus agent etat
    [ "$status" -eq 1 ] || { echo "code $status"; false; }
    [[ "$stderr" == *"devzone agent state"* ]] || { echo "message : $stderr"; false; }
    [ -z "$output" ] || false
}

@test "agent: old subcommand liberer is refused, code 1, with the new name release" {
    run --separate-stderr refus agent liberer
    [ "$status" -eq 1 ] || { echo "code $status"; false; }
    [[ "$stderr" == *"devzone agent release"* ]] || { echo "message : $stderr"; false; }
    [ -z "$output" ] || false
}

@test "agent: old option --modele is refused, code 1, with the new name --model" {
    run --separate-stderr refus agent --modele big-pickle
    [ "$status" -eq 1 ] || { echo "code $status"; false; }
    [[ "$stderr" == *"--model"* ]] || { echo "message : $stderr"; false; }
    [ -z "$output" ] || false
}

@test "agent: old option --tous is refused, code 1, with the new name --all" {
    run --separate-stderr refus agent release --tous
    [ "$status" -eq 1 ] || { echo "code $status"; false; }
    [[ "$stderr" == *"--all"* ]] || { echo "message : $stderr"; false; }
    [ -z "$output" ] || false
}

@test "renamed_module: ia gives ai, any other name returns 1" {
    run bash -c ". '$ALIASES'; renamed_module ia"
    [ "$status" -eq 0 ]
    [ "$output" = "ai" ]
    run bash -c ". '$ALIASES'; renamed_module ai"
    [ "$status" -eq 1 ]
    run bash -c ". '$ALIASES'; renamed_module kubernetes"
    [ "$status" -eq 1 ]
}

@test "reject_renamed: enable ia is refused with the new module name" {
    run --separate-stderr refus enable ia
    [ "$status" -eq 1 ]
    [ "$stderr" = "✖ « ia » was renamed: ai" ]
    [ -z "$output" ]
}

@test "reject_renamed: disable ia is refused with the new module name" {
    run --separate-stderr refus disable ia
    [ "$status" -eq 1 ]
    [ "$stderr" = "✖ « ia » was renamed: ai" ]
}

@test "reject_renamed: is-enabled ia is refused with the new module name" {
    run --separate-stderr refus is-enabled ia
    [ "$status" -eq 1 ]
    [ "$stderr" = "✖ « ia » was renamed: ai" ]
}

@test "reject_renamed: apply ia is refused with the new module name" {
    run --separate-stderr refus apply ia
    [ "$status" -eq 1 ]
    [ "$stderr" = "✖ « ia » was renamed: ai" ]
}

@test "reject_renamed: the old module name is refused after an option too" {
    run --separate-stderr refus enable --yes ia
    [ "$status" -eq 1 ]
    [ "$stderr" = "✖ « ia » was renamed: ai" ]
}

@test "reject_renamed: ia is only a renamed module for enable, disable, is-enabled and apply" {
    run --separate-stderr refus postgres ia
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
}

@test "conteneur : enable, disable, is-enabled et apply refusent ia, code 1, aucun effet" {
    export DEVZONE_ROOT="$T/racine"
    for c in enable disable is-enabled apply; do
        run --separate-stderr bash "$RACINE/.devcontainer/devzone" "$c" ia
        [ "$status" -eq 1 ] || { echo "code $status pour $c"; false; }
        [ "$stderr" = "✖ « ia » was renamed: ai" ] || { echo "message pour $c : $stderr"; false; }
        [ -z "$output" ] || false
    done
    [ ! -e "$T/racine" ]
    [ ! -e "$T/ia" ]
}

@test "hôte : devzone enable ia est refusé avant toute action, aucun dossier créé" {
    run --separate-stderr bash "$CLI" enable ia
    [ "$status" -eq 1 ]
    [ "$stderr" = "✖ « ia » was renamed: ai" ]
    [ -z "$output" ]
    [ ! -e ia ]
    [ ! -e "$T/kubectl.log" ]
}
