#!/usr/bin/env bats
# GitLab held by Argo CD (#538 step 4): with the argocd module on and
# installed, the installation is the Application devzone-gitlab on the
# wrapper chart, not a helm pass; the seed writes the runner Secret; the
# seed command and services-admin.sh seed refuse what is not gitlab's.
# Fake kubectl, helm, curl, git and setsid in $BATS_TEST_TMPDIR/bin.

setup() {
    load commun
    kind_vide
    relais_docker_isole
    kube_isole
    REPO="$BATS_TEST_DIRNAME/../.."
    GITLAB="$REPO/.devcontainer/gitlab/gitlab.sh"
    SERVICES_ADMIN="$REPO/.devcontainer/services-admin.sh"
    export DEVZONE_ROOT="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_STATE="$BATS_TEST_TMPDIR/modules"
    export DEVZONE_HOSTS="$BATS_TEST_TMPDIR/hosts"
    export KIND_CLUSTERS="$BATS_TEST_TMPDIR/clusters"
    mkdir -p "$HOME" "$DEVZONE_ROOT/workspace" "$BATS_TEST_TMPDIR/bin"
    : >"$KIND_CLUSTERS"
    printf '127.0.0.1 localhost\n' >"$DEVZONE_HOSTS"
    : >"$DEVZONE_STATE"

    # The charts and the scripts are read from the repository (symbolic links);
    # a package version gives the revision of the Applications
    ln -s "$REPO/.devcontainer" "$DEVZONE_ROOT/.devcontainer"
    ln -s "$REPO/charts" "$DEVZONE_ROOT/charts"
    printf '{"version": "1.2.3"}\n' >"$DEVZONE_ROOT/package.json"

    # kubectl: memory of the nodes, namespaces (a file per namespace created),
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
    *"gitlab-rails runner"*) echo "token-root-secret" ;;
esac
exit 0
KUBE

    # helm: logs each call
    cat >"$BATS_TEST_TMPDIR/bin/helm" <<'HELM'
#!/usr/bin/env bash
echo "helm $*" >>"$BATS_TEST_TMPDIR/helm.log"
exit 0
HELM

    # curl: GitLab ready, API of the seed simulated
    cat >"$BATS_TEST_TMPDIR/bin/curl" <<'CURL'
#!/usr/bin/env bash
case "$*" in
    *"api/v4/runners/verify"*) echo 200 ;;
    *"api/v4/groups/devzone"*) echo '{"id":42}' ;;
    *"--request POST"*"api/v4/user/runners"*) echo '{"token":"token-runner"}' ;;
    *"api/v4/projects/devzone%2Fdemo/repository"*) exit 0 ;;
    *"api/v4/users?username=dev"*) echo '[]' ;;
    *"api/v4/runners/all"*) echo '[]' ;;
esac
exit 0
CURL

    # git and setsid: nothing real (the push of the demo project is skipped)
    printf '#!/usr/bin/env bash\nexit 0\n' >"$BATS_TEST_TMPDIR/bin/git"
    printf '#!/usr/bin/env bash\necho "setsid $*" >>"$BATS_TEST_TMPDIR/setsid.log"\nexit 0\n' >"$BATS_TEST_TMPDIR/bin/setsid"
    printf '#!/usr/bin/env bash\necho test-password\n' >"$BATS_TEST_TMPDIR/bin/openssl"
    chmod +x "$BATS_TEST_TMPDIR"/bin/*
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "gitlab : argocd module on → Application devzone-gitlab, no helm upgrade of GitLab" {
    printf 'argocd=on\n' >"$DEVZONE_STATE"
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

@test "gitlab : argocd module on but unknown revision (clone 0.0.0) → direct helm" {
    printf 'argocd=on\n' >"$DEVZONE_STATE"
    touch "$BATS_TEST_TMPDIR/namespace"
    printf '{"version": "0.0.0"}\n' >"$DEVZONE_ROOT/package.json"
    run bash "$GITLAB" install
    [ "$status" -eq 0 ] || false
    ! grep -q "kind: Application" "$BATS_TEST_TMPDIR/apply.log" 2>/dev/null || false
    grep -q "upgrade --install gitlab .*charts/devzone-gitlab" "$BATS_TEST_TMPDIR/helm.log" || false
}

@test "gitlab : seed → Secret gitlab-runner-secret written (runner token, never on the command line)" {
    run bash "$GITLAB" seed
    [ "$status" -eq 0 ] || false
    grep -q "create secret generic gitlab-runner-secret" "$BATS_TEST_TMPDIR/kubectl.log" || false
    grep -q "runner-token=" "$BATS_TEST_TMPDIR/kubectl.log" || false
    ! grep -q "token-runner" "$BATS_TEST_TMPDIR/kubectl.log" || false
    [ -f "$DEVZONE_ROOT/workspace/.gitlab/runner-token" ] || false
}

@test "services-admin : seed refused for a service other than gitlab" {
    run bash "$SERVICES_ADMIN" seed postgres
    [ "$status" -eq 2 ] || false
    [[ "$output" == *"seed: only gitlab"* ]] || false
}
