#!/usr/bin/env bats
# Rebuild et gitlab (#366) : kind_sans_basculer et kind_creer_sans_basculer
# (cluster.sh), contexte kind-gitlab remis quand le cluster existe déjà
# (gitlab.sh installer), échec effacé quand gitlab est prêt (devzone appliquer).
# Faux kind, kubectl, helm, docker, curl et git dans $BATS_TEST_TMPDIR/bin :
# aucun vrai cluster, aucun vrai kubeconfig. Chaque faux outil journalise ses
# arguments dans $BATS_TEST_TMPDIR/<outil>.log.

setup() {
    load commun
    relais_docker_isole
    kube_isole
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    GITLAB="$BATS_TEST_DIRNAME/../../.devcontainer/gitlab/gitlab.sh"
    CLUSTER="$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
    export DEVZONE_RACINE="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_ETAT="$BATS_TEST_TMPDIR/modules"
    export DEVZONE_MEMINFO="$BATS_TEST_TMPDIR/meminfo"
    export DEVZONE_HOSTS="$BATS_TEST_TMPDIR/hosts"
    export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
    export KIND_CLUSTERS="$BATS_TEST_TMPDIR/clusters"
    SECRETS="$DEVZONE_RACINE/workspace/.gitlab"
    mkdir -p "$DEVZONE_RACINE/workspace" "$BATS_TEST_TMPDIR/bin"
    printf 'MemAvailable: 16000000 kB\n' >"$DEVZONE_MEMINFO"
    : >"$KIND_CLUSTERS"
    printf '127.0.0.1 localhost\n' >"$DEVZONE_HOSTS"

    # kind : clusters dans $KIND_CLUSTERS ; create et export écrivent le
    # contexte kind-<nom> dans --kubeconfig (défaut ~/.kube/config), comme le vrai
    cat >"$BATS_TEST_TMPDIR/bin/kind" <<'KIND'
#!/usr/bin/env bash
echo "kind $*" >>"$BATS_TEST_TMPDIR/kind.log"
sous="$1 $2"
nom="" fichier="$HOME/.kube/config"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --name) nom="$2"; shift ;;
        --kubeconfig) fichier="$2"; shift ;;
    esac
    shift
done
case "$sous" in
    "get clusters") cat "$KIND_CLUSTERS" ;;
    "create cluster")
        echo "$nom" >>"$KIND_CLUSTERS"
        printf 'ctx: kind-%s\ncurrent-context: kind-%s\n' "$nom" "$nom" >>"$fichier" ;;
    "export kubeconfig")
        printf 'ctx: kind-%s\ncurrent-context: kind-%s\n' "$nom" "$nom" >>"$fichier" ;;
esac
if [ -n "${FAUX_KIND_ECHEC:-}" ]; then exit 1; fi
exit 0
KIND

    # kubectl : kubeconfig factice (lignes « ctx: » et « current-context: »),
    # secret root, pod toolbox, jeton root
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"$BATS_TEST_TMPDIR/kubectl.log"
fichier="$HOME/.kube/config"
case "$*" in
    "config current-context") sed -n 's/^current-context:[[:space:]]*//p' "$fichier" 2>/dev/null | head -1 ;;
    "config get-contexts -o name") sed -n 's/^ctx: //p' "$fichier" 2>/dev/null ;;
    "config use-context "*)
        { grep -v '^current-context:' "$fichier" 2>/dev/null || true; printf 'current-context: %s\n' "${3:-}"; } >"$fichier.tmp"
        mv "$fichier.tmp" "$fichier" ;;
    "config unset current-context")
        { grep -v '^current-context:' "$fichier" 2>/dev/null || true; } >"$fichier.tmp"
        mv "$fichier.tmp" "$fichier" ;;
    *"get secret"*) echo "cGFzc3dvcmQxMjM=" ;;
    *"get pod"*) echo "gitlab-toolbox-1" ;;
    *"gitlab-rails runner"*) echo "jeton-root-secret" ;;
esac
exit 0
KUBE

    # helm : journalise les arguments
    cat >"$BATS_TEST_TMPDIR/bin/helm" <<'HELM'
#!/usr/bin/env bash
echo "helm $*" >>"$BATS_TEST_TMPDIR/helm.log"
HELM

    # docker : journalise, aucun mapping ni réseau réel
    cat >"$BATS_TEST_TMPDIR/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
echo "docker $*" >>"$BATS_TEST_TMPDIR/docker.log"
exit 0
DOCKER

    # curl : API GitLab simulée (readiness, groupe, runner, jeton)
    cat >"$BATS_TEST_TMPDIR/bin/curl" <<'CURL'
#!/usr/bin/env bash
echo "curl $*" | sed -e 's/token=[^ &]*/token=<masque>/g' -e 's/PRIVATE-TOKEN: [^ "]*/PRIVATE-TOKEN: <masque>/g' >>"$BATS_TEST_TMPDIR/curl.log"
case "$*" in
    *"api/v4/runners/verify"*) echo 200 ;;
    *"api/v4/groups/devzone"*) echo '{"id":42}' ;;
    *"--request POST"*"api/v4/user/runners"*) echo '{"token":"jeton-runner-secret"}' ;;
    # Branche main : absente tant que le faux git n'a pas poussé
    *"api/v4/projects/devzone%2Fdemo/repository"*) [ -f "$BATS_TEST_TMPDIR/pousse" ] || exit 22 ;;
    *"--request POST"*) ;;
    *"api/v4/projects/devzone%2Fdemo"*) exit 22 ;;
    *"api/v4/users?username=dev"*) echo '[]' ;;
    *"api/v4/runners/all"*) echo "${FAUX_RUNNERS:-[]}" ;;
esac
exit 0
CURL

    # git : journalise, touche poussée
    cat >"$BATS_TEST_TMPDIR/bin/git" <<'GIT'
#!/usr/bin/env bash
echo "git $*" >>"$BATS_TEST_TMPDIR/git.log"
case "$*" in *" push "*) touch "$BATS_TEST_TMPDIR/pousse" ;; esac
GIT

    chmod +x "$BATS_TEST_TMPDIR"/bin/*
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# Écrit le contexte courant dans le faux ~/.kube/config ; vide = aucun
poser_contexte_courant() {
    printf 'current-context: %s\n' "$1" >"$HOME/.kube/config"
}

# Lit le contexte courant du faux ~/.kube/config
contexte_courant() {
    sed -n 's/^current-context:[[:space:]]*//p' "$HOME/.kube/config" 2>/dev/null | head -1
}

@test "kind_sans_basculer : export sans basculer, contexte courant gardé" {
    poser_contexte_courant docker-desktop
    (
        set -e
        source "$CLUSTER"
        kind_sans_basculer export kubeconfig --name gitlab --kubeconfig "$HOME/.kube/config"
    ) || false
    grep -qxF "kind export kubeconfig --name gitlab --kubeconfig $HOME/.kube/config" "$BATS_TEST_TMPDIR/kind.log" || false
    grep -qxF 'ctx: kind-gitlab' "$HOME/.kube/config" || false
    [ "$(contexte_courant)" = docker-desktop ] || false
}

@test "kind_sans_basculer : aucun contexte au départ, aucun posé à la fin" {
    poser_contexte_courant ""
    (
        set -e
        source "$CLUSTER"
        kind_sans_basculer export kubeconfig --name gitlab --kubeconfig "$HOME/.kube/config"
    ) || false
    grep -qxF 'ctx: kind-gitlab' "$HOME/.kube/config" || false
    [ -z "$(contexte_courant)" ] || false
    grep -qxF 'kubectl config unset current-context' "$BATS_TEST_TMPDIR/kubectl.log" || false
    ! grep -q 'config use-context' "$BATS_TEST_TMPDIR/kubectl.log" || false
}

@test "kind_sans_basculer : échec de kind, code 1 rendu sous set -e, contexte remis" {
    poser_contexte_courant docker-desktop
    FAUX_KIND_ECHEC=1 run bash -c '
        set -e
        source "$1"
        kind_sans_basculer create cluster --name gitlab
    ' _ "$CLUSTER"
    [ "$status" -eq 1 ] || false
    [ "$(contexte_courant)" = docker-desktop ] || false
}

@test "kind_creer_sans_basculer : appelle kind create cluster, contexte gardé" {
    poser_contexte_courant docker-desktop
    (
        set -e
        source "$CLUSTER"
        kind_creer_sans_basculer --name devzone --wait 120s
    ) || false
    grep -qxF 'kind create cluster --name devzone --wait 120s' "$BATS_TEST_TMPDIR/kind.log" || false
    [ "$(contexte_courant)" = docker-desktop ] || false
}

@test "installer : cluster gitlab existant sans contexte → export, contexte courant gardé" {
    echo gitlab >"$KIND_CLUSTERS"
    poser_contexte_courant docker-desktop
    run bash "$GITLAB" installer
    [ "$status" -eq 0 ] || false
    [[ "$output" == *"▶ Contexte kind-gitlab remis (cluster existant)"* ]] || false
    grep -qxF "kind export kubeconfig --name gitlab --kubeconfig $HOME/.kube/config" "$BATS_TEST_TMPDIR/kind.log" || false
    ! grep -q 'kind create' "$BATS_TEST_TMPDIR/kind.log" || false
    grep -qF -- "--kube-context kind-gitlab upgrade --install gitlab gitlab/gitlab" "$BATS_TEST_TMPDIR/helm.log" || false
    [ "$(contexte_courant)" = docker-desktop ] || false
}

@test "installer : contexte kind-gitlab déjà présent → aucun export" {
    echo gitlab >"$KIND_CLUSTERS"
    printf 'ctx: kind-gitlab\ncurrent-context: docker-desktop\n' >"$HOME/.kube/config"
    run bash "$GITLAB" installer
    [ "$status" -eq 0 ] || false
    ! grep -q 'export kubeconfig' "$BATS_TEST_TMPDIR/kind.log" || false
    [[ "$output" != *"Contexte kind-gitlab remis"* ]] || false
    [ "$(contexte_courant)" = docker-desktop ] || false
}

@test "installer : cluster absent → création sans basculer, contexte gardé" {
    poser_contexte_courant docker-desktop
    run bash "$GITLAB" installer
    [ "$status" -eq 0 ] || false
    grep -q 'kind create cluster --name gitlab --config .* --wait 120s' "$BATS_TEST_TMPDIR/kind.log" || false
    ! grep -q 'export kubeconfig' "$BATS_TEST_TMPDIR/kind.log" || false
    [ "$(contexte_courant)" = docker-desktop ] || false
}

@test "appliquer : gitlab prêt, runner en ligne → marque d'échec effacée, récapitulatif à ✔" {
    echo gitlab >"$KIND_CLUSTERS"
    printf 'gitlab=on\n' >"$DEVZONE_ETAT"
    mkdir -p "$SECRETS" && echo jeton >"$SECRETS/root-token"
    echo gitlab >"$DEVZONE_ETAT-echec-gitlab"
    FAUX_RUNNERS='[{"id":1}]' run bash "$DEVZONE" appliquer
    [ "$status" -eq 0 ] || false
    [[ "$output" == *"déjà actif, rien à faire"* ]] || false
    [ ! -e "$DEVZONE_ETAT-echec-gitlab" ] || false
    FAUX_RUNNERS='[{"id":1}]' run bash "$DEVZONE"
    [[ "$output" == *"✔ module gitlab"* ]] || false
    [[ "$output" != *"en échec"* ]] || false
}
