#!/usr/bin/env bats
# Assistant git de glab (#278) : devzone plateforme gitlab pose, pour l'hôte de
# l'instance seulement, credential.<URL>.helper = !glab auth git-credential ;
# devzone plateforme github le retire ; le récapitulatif dit « ✔ git par glab ».
# Faux glab (auth status, auth git-credential ok) et faux kind ; HOME et
# GIT_CONFIG_GLOBAL sous $BATS_TEST_TMPDIR : git config --global n'écrit jamais
# dans le vrai ~/.gitconfig.

setup() {
    load commun
    relais_docker_isole
    kube_isole
    kind_vide
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    export HOME="$BATS_TEST_TMPDIR/home"
    export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
    export GIT_CONFIG_NOSYSTEM=1
    mkdir -p "$HOME" "$HOME/.local/bin"
    # garde-fou : jamais le vrai HOME
    [[ "$HOME" == "$BATS_TEST_TMPDIR"/* ]] || false
    export DEVZONE_RACINE="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_ETAT="$BATS_TEST_TMPDIR/modules"
    mkdir -p "$DEVZONE_RACINE/workspace"
    export GLAB_LOG="$BATS_TEST_TMPDIR/glab.log"
    INSTANCE="http://example.gitlab:8443"
    AUTRE="https://git.autre.exemple"

    # glab simulé dans ~/.local/bin (chemin absolu, comme le vrai binaire) :
    # version, connexion et contrôle d'auth réussis, git-credential factice
    cat >"$HOME/.local/bin/glab" <<'GLAB'
#!/usr/bin/env bash
echo "glab $*" >>"$GLAB_LOG"
case "$*" in
    *"--version"*) echo "glab 1.126.0" ;;
esac
exit 0
GLAB
    chmod +x "$HOME/.local/bin/glab"
}

# Valeur du réglage credential de l'hôte donné, vide s'il n'existe pas
reglage() {
    git config --global --get "credential.$1.helper" 2>/dev/null || true
}

# Nombre de réglages credential.* présents dans le HOME de test
nombre_reglages_credential() {
    git config --global --get-regexp '^credential\.' 2>/dev/null | wc -l
}

@test "plateforme gitlab pose le réglage credential pour l'hôte de l'instance seulement" {
    run bash "$DEVZONE" plateforme gitlab --url "$INSTANCE"
    [ "$status" -eq 0 ]
    [ "$(reglage "$INSTANCE")" = "!$HOME/.local/bin/glab auth git-credential" ]
    [ "$(nombre_reglages_credential)" -eq 1 ]
    [ -f "$GIT_CONFIG_GLOBAL" ]
}

@test "plateforme gitlab : un autre réglage credential (autre hôte) reste intact" {
    git config --global "credential.$AUTRE.helper" store
    git config --global "credential.$AUTRE.username" bob
    avant="$(git config --global --get-regexp '^credential\.' | sort)"
    run bash "$DEVZONE" plateforme gitlab --url "$INSTANCE"
    [ "$status" -eq 0 ]
    [ "$(reglage "$AUTRE")" = "store" ]
    [ "$(git config --global "credential.$AUTRE.username")" = "bob" ]
    [ "$(reglage "$INSTANCE")" = "!$HOME/.local/bin/glab auth git-credential" ]
    # les réglages d'avant sont tous encore là, à l'identique
    apres="$(git config --global --get-regexp '^credential\.' | sort)"
    [[ "$apres" == *"$avant"* ]] || false
    [ "$(nombre_reglages_credential)" -eq 3 ]
}

@test "plateforme gitlab répétée : un seul réglage, pas de doublon" {
    run bash "$DEVZONE" plateforme gitlab --url "$INSTANCE"
    [ "$status" -eq 0 ]
    run bash "$DEVZONE" plateforme gitlab --url "$INSTANCE"
    [ "$status" -eq 0 ]
    [ "$(git config --global --get-all "credential.$INSTANCE.helper" | wc -l)" -eq 1 ]
}

@test "retour à github : plus aucun réglage pour l'instance, les autres intacts" {
    git config --global "credential.$AUTRE.helper" store
    run bash "$DEVZONE" plateforme gitlab --url "$INSTANCE"
    [ "$status" -eq 0 ]
    [ "$(reglage "$INSTANCE")" != "" ]
    run bash "$DEVZONE" plateforme github
    [ "$status" -eq 0 ]
    [ -z "$(reglage "$INSTANCE")" ]
    [ "$(reglage "$AUTRE")" = "store" ]
    [ "$(nombre_reglages_credential)" -eq 1 ]
    [ ! -e "$HOME/.local/bin/glab" ]
}

@test "retour à github sans réglage posé : aucune erreur, rien ajouté" {
    run bash "$DEVZONE" plateforme gitlab --url "$INSTANCE"
    [ "$status" -eq 0 ]
    git config --global --unset-all "credential.$INSTANCE.helper"
    run bash "$DEVZONE" plateforme github
    [ "$status" -eq 0 ]
    [ "$(nombre_reglages_credential)" -eq 0 ]
}

@test "récapitulatif : « ✔ git par glab » une fois le réglage posé" {
    run bash "$DEVZONE" plateforme gitlab --url "$INSTANCE"
    [ "$status" -eq 0 ]
    run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"✔ git par glab"* ]] || false
    [[ "$output" != *"à poser : devzone plateforme gitlab"* ]] || false
}

@test "récapitulatif : « à poser » si le réglage a disparu, plateforme gitlab gardée" {
    run bash "$DEVZONE" plateforme gitlab --url "$INSTANCE"
    [ "$status" -eq 0 ]
    git config --global --unset-all "credential.$INSTANCE.helper"
    run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"⚠ git par glab"*"à poser : devzone plateforme gitlab"* ]] || false
    [[ "$output" != *"✔ git par glab"* ]] || false
}

@test "récapitulatif : pas de ligne « git par glab » sur github" {
    run bash "$DEVZONE" plateforme gitlab --url "$INSTANCE"
    [ "$status" -eq 0 ]
    run bash "$DEVZONE" plateforme github
    [ "$status" -eq 0 ]
    run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    [[ "$output" != *"git par glab"* ]] || false
}

@test "réglage credential impossible (config globale non inscriptible) → échec, plateforme non retenue" {
    # git config échoue si le fichier de config global n'est pas inscriptible
    mkdir -p "$GIT_CONFIG_GLOBAL"
    run bash "$DEVZONE" plateforme gitlab --url "$INSTANCE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"réglage git credential impossible"* ]] || false
    ! grep -q '^plateforme=' "$DEVZONE_ETAT" 2>/dev/null || false
}
