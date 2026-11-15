#!/usr/bin/env bats
# GitLab held by Argo CD (#538 étape 4): with the module argocd on and
# installed, the installation is the Application devzone-gitlab on the
# wrapper chart, not a helm pass; the seed writes the runner Secret; the
# seed command and services-admin.sh seed refuse what is not gitlab's.
# Faux kubectl, helm, curl, git and setsid in $BATS_TEST_TMPDIR/bin.

setup() {
    load commun
    kind_vide
    relais_docker_isole
    kube_isole
    DEPOT="$BATS_TEST_DIRNAME/../.."
    GITLAB="$DEPOT/.devcontainer/gitlab/gitlab.sh"
    SERVICES_ADMIN="$DEPOT/.devcontainer/services-admin.sh"
    export DEVZONE_RACINE="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_ETAT="$BATS_TEST_TMPDIR/modules"
    export DEVZONE_HOSTS="$BATS_TEST_TMPDIR/hosts"
    export KIND_CLUSTERS="$BATS_TEST_TMPDIR/clusters"
    mkdir -p "$HOME" "$DEVZONE_RACINE/workspace" "$BATS_TEST_TMPDIR/bin"
    : >"$KIND_CLUSTERS"
    printf '127.0.0.1 localhost\n' >"$DEVZONE_HOSTS"
    : >"$DEVZONE_ETAT"

    # The charts and the scripts are read from the repository (symbolic links);
    # a package version gives the revision of the Applications
    ln -s "$DEPOT/.devcontainer" "$DEVZONE_RACINE/.devcontainer"
    ln -s "$DEPOT/charts" "$DEVZONE_RACINE/charts"
    printf '{"version": "1.2.3"}\n' >"$DEVZONE_RACINE/package.json"

    # kubectl : memory of the nodes, namespaces (a file per namespace created),
    # secrets and API of the seed; the applied manifests are logged
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"$BATS_TEST_TMPDIR/kubectl.log"
T="$BATS_TEST_TMPDIR"
case "$*" in
    *"get nodes -o jsonpath"*) printf '16777216Ki\n' ;;
    *"create namespace"*) printf 'kind: Namespace\nmetadata:\n  name: devzone-gitlab\n' ;;
    *"apply -f -"*) tee -a "$T/apply.log" >/dev/null ;;
    *"get namespace "*) [ -f "$T/namespace" ] && exit 0; exit 1 ;;
    *"label namespace "*) touch "$T/namespace" ;;
    *"get secret"*) echo "cGFzc3dvcmQxMjM=" ;;
    *"get pod"*) echo "gitlab-toolbox-1" ;;
    *"gitlab-rails runner"*) echo "jeton-root-secret" ;;
esac
exit 0
KUBE

    # helm : journalises each call
    cat >"$BATS_TEST_TMPDIR/bin/helm" <<'HELM'
#!/usr/bin/env bash
echo "helm $*" >>"$BATS_TEST_TMPDIR/helm.log"
exit 0
HELM

    # curl : GitLab ready, API of the seed simulated
    cat >"$BATS_TEST_TMPDIR/bin/curl" <<'CURL'
#!/usr/bin/env bash
case "$*" in
    *"api/v4/runners/verify"*) echo 200 ;;
    *"api/v4/groups/devzone"*) echo '{"id":42}' ;;
    *"--request POST"*"api/v4/user/runners"*) echo '{"token":"jeton-runner"}' ;;
    *"api/v4/projects/devzone%2Fdemo/repository"*) exit 0 ;;
    *"api/v4/users?username=dev"*) echo '[]' ;;
    *"api/v4/runners/all"*) echo '[]' ;;
esac
exit 0
CURL

    # git and setsid: nothing real (the push of the demo project is skipped)
    printf '#!/usr/bin/env bash\nexit 0\n' >"$BATS_TEST_TMPDIR/bin/git"
    printf '#!/usr/bin/env bash\necho "setsid $*" >>"$BATS_TEST_TMPDIR/setsid.log"\nexit 0\n' >"$BATS_TEST_TMPDIR/bin/setsid"
    printf '#!/usr/bin/env bash\necho motdepasse-test\n' >"$BATS_TEST_TMPDIR/bin/openssl"
    chmod +x "$BATS_TEST_TMPDIR"/bin/*
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "gitlab : module argocd on → Application devzone-gitlab, aucun helm upgrade de GitLab" {
    printf 'argocd=on\n' >"$DEVZONE_ETAT"
    touch "$BATS_TEST_TMPDIR/namespace"
    run bash "$GITLAB" install
    [ "$status" -eq 0 ] || false
    grep -q "kind: Application" "$BATS_TEST_TMPDIR/apply.log" || false
    grep -q "devzone-gitlab" "$BATS_TEST_TMPDIR/apply.log" || false
    grep -q "charts/devzone-gitlab" "$BATS_TEST_TMPDIR/apply.log" || false
    grep -q "gitlab-runner.gitlabUrl" "$BATS_TEST_TMPDIR/apply.log" || false
    ! grep -q "upgrade --install gitlab " "$BATS_TEST_TMPDIR/helm.log" || false
    # Adoption: the release secrets of a former helm install are removed
    grep -q "delete secret -l owner=helm,name=gitlab" "$BATS_TEST_TMPDIR/kubectl.log" || false
}

@test "gitlab : module argocd on mais révision inconnue (clone 0.0.0) → helm direct" {
    printf 'argocd=on\n' >"$DEVZONE_ETAT"
    touch "$BATS_TEST_TMPDIR/namespace"
    printf '{"version": "0.0.0"}\n' >"$DEVZONE_RACINE/package.json"
    run bash "$GITLAB" install
    [ "$status" -eq 0 ] || false
    ! grep -q "kind: Application" "$BATS_TEST_TMPDIR/apply.log" 2>/dev/null || false
    grep -q "upgrade --install gitlab .*charts/devzone-gitlab" "$BATS_TEST_TMPDIR/helm.log" || false
}

@test "gitlab : seed → Secret gitlab-runner-secret écrit (token du runner, jamais sur la ligne de commande)" {
    run bash "$GITLAB" seed
    [ "$status" -eq 0 ] || false
    grep -q "create secret generic gitlab-runner-secret" "$BATS_TEST_TMPDIR/kubectl.log" || false
    grep -q "runner-token=" "$BATS_TEST_TMPDIR/kubectl.log" || false
    ! grep -q "jeton-runner" "$BATS_TEST_TMPDIR/kubectl.log" || false
    [ -f "$DEVZONE_RACINE/workspace/.gitlab/runner-token" ] || false
}

@test "services-admin : seed refusé pour un service autre que gitlab" {
    run bash "$SERVICES_ADMIN" seed postgres
    [ "$status" -eq 2 ] || false
    [[ "$output" == *"seed: only gitlab"* ]] || false
}
