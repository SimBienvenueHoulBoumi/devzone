#!/usr/bin/env bats
# services_reconcile (#625): the exit code is faithful to the steps. A service
# off whose Application is absent (no file in the GitOps repository, no
# Application in the cluster) is a success: no gh error shown, exit 0, and the
# line "removed" only when the removal worked. A real failure keeps a non-zero
# code and names the service and the step on stderr, while the other services
# of the list are still processed. Fake gh (GitOps repository) and fake kubectl
# (a cluster that answers like a real one): no cluster, no network, no real gh
# write is ever reached.

setup() {
    load commun
    relais_docker_isole
    kube_isole
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CLI="$RACINE/manage/devzone"
    T="$BATS_TEST_TMPDIR"
    mkdir -p "$T/bin" "$T/workspace" "$T/gitops/apps"
    : >"$T/kubectl.log"
    : >"$T/gh.log"
    : >"$T/gitops.log"
    : >"$T/apply.yaml"
    # Fake kubectl: a cluster that answers like a real one (an Application
    # absent with --ignore-not-found: exit 0 and nothing printed)
    cat >"$T/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
echo "kubectl $*" >>"$T/kubectl.log"
case "$*" in
    "config get-contexts -o name") echo docker-desktop ;;
    "config current-context") echo docker-desktop ;;
    *"get namespace devzone-argocd"*) [ -f "$T/argocd-ns" ]; exit $? ;;
    *"create namespace "*"--dry-run=client"*) echo "kind: Namespace" ;;
    *"apply -f -"*) cat >>"$T/apply.yaml" ;;
    *"get secret postgres-admin"*)
        [ -f "$T/pg-secret" ] || { echo 'Error from server (NotFound): secrets "postgres-admin" not found' >&2; exit 1; }
        cat "$T/pg-secret"
        ;;
    *"create secret generic postgres-admin"*) touch "$T/pg-secret-created" ;;
    *"delete application.argoproj.io "*--ignore-not-found*) exit 0 ;;
esac
exit 0
KUBE
    # Fake gh: the GitOps repository lives in $T/gitops. A file read that
    # misses answers like the real gh: the error body on stdout, the message
    # on stderr, exit 1 (#625). Writes succeed; a DELETE of a file that is
    # not there is a 404, as the API answers (#625)
    cat >"$T/bin/gh" <<'GH'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
echo "gh $*" >>"$T/gh.log"
method=GET
path=""
prev=""
for a in "$@"; do
    if [ "$prev" = -X ]; then method="$a"; fi
    case "$a" in repos/*/contents/*) path="${a#*/contents/}" ;; esac
    prev="$a"
done
gh_answer_404() {
    printf '{"message":"Not Found","status":"404"}'
    echo "gh: Not Found (HTTP 404)" >&2
    exit 1
}
gh_answer_500() {
    printf '{"message":"Internal Server Error","status":"500"}'
    echo "gh: Internal Server Error (HTTP 500)" >&2
    exit 1
}
if [ -n "$path" ]; then
    case "$method" in
        GET)
            [ -f "$T/gitops/$path" ] || gh_answer_404
            git hash-object "$T/gitops/$path"
            ;;
        PUT)
            [ "${FAKE_GH_ECHEC:-}" != write ] || gh_answer_500
            mkdir -p "$T/gitops/$(dirname "$path")"
            for a in "$@"; do
                case "$a" in content=*) printf '%s' "${a#content=}" | base64 -d >"$T/gitops/$path" ;; esac
            done
            echo "put $path" >>"$T/gitops.log"
            ;;
        DELETE)
            [ "${FAKE_GH_ECHEC:-}" != write ] || gh_answer_500
            [ -f "$T/gitops/$path" ] || gh_answer_404
            rm -f "$T/gitops/$path"
            echo "delete $path" >>"$T/gitops.log"
            ;;
    esac
    exit 0
fi
case "$*" in
    "auth status") exit 0 ;;
    "auth token") echo gh-token ;;
    "api user --jq .login") echo tester ;;
    "repo view "*) [ -f "$T/gitops-repo" ]; exit $? ;;
    "repo create "*) touch "$T/gitops-repo" ;;
esac
exit 0
GH
    printf '#!/usr/bin/env bash\nexit 0\n' >"$T/bin/helm"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$T/bin/docker"
    chmod +x "$T/bin/"*
    export PATH="$T/bin:$PATH"
    export DEVZONE_ARGOCD_REVISION=v0.48.0
    export GIT_CONFIG_NOSYSTEM=1
    cd "$T" || return 1
    # Workstation folder: Argo CD installed, postgres on in [services] of
    # .argocd.conf, mysql off in .devzone.modules (#625)
    printf 'workspace=kubernetes\nmysql=off\n' >"$T/.devzone.modules"
    printf '[argocd]\n    repo = https://github.com/tester/devzone-argocd.git\n\n[services]\n    postgres = on\n' >"$T/.argocd.conf"
    touch "$T/gitops-repo" "$T/argocd-ns"
    printf 'kind: Application\n' >"$T/gitops/apps/devzone-postgres.yaml"
    # The workstation pieces, sourced with the fakes: services_reconcile called
    # on its own, the same way manage/workspace.sh does
    ARGOCD_CONF="$T/.argocd.conf"
    ARGOCD_CONF_DIR="$T"
    APPS_GENERATOR="$RACINE/.devcontainer/argocd/application.sh"
    DEVZONE_REPO_URL="https://github.com/tester/devzone.git"
    SERVICES_LIST="postgres mysql"
    # shellcheck disable=SC1091
    . "$RACINE/.devcontainer/argocd/conf.sh"
    # shellcheck disable=SC1091
    . "$RACINE/.devcontainer/argocd/gitops.sh"
    # shellcheck disable=SC1091
    . "$RACINE/.devcontainer/argocd/services.sh"
    argocd_kubectl() { kubectl "$@"; }
    argocd_revision() { printf 'v0.48.0'; }
    services_secret_postgres() { :; }
}

# ---- the scenario of #625 ----

@test "services_reconcile: postgres on, mysql off, no mysql file: exit 0 without any gh error" {
    run services_reconcile
    [ "$status" -eq 0 ]
    [[ "$output" == *"✔ Application devzone-postgres declared (chart charts/devzone-postgres)"* ]] || false
    [[ "$output" == *"✔ Application devzone-mysql removed (namespace and volumes kept)"* ]] || false
    [[ "$output" != *"Not Found"* ]] || false
    [[ "$output" != *"✖"* ]] || false
    ! grep -q 'X DELETE' "$T/gh.log" || false
}

@test "devzone workspace services enable postgres: exit 0, both lines said, no gh 404" {
    run bash "$CLI" workspace services enable postgres
    [ "$status" -eq 0 ]
    [[ "$output" == *"✔ Application devzone-postgres declared"* ]] || false
    [[ "$output" == *"✔ Application devzone-mysql removed"* ]] || false
    [[ "$output" != *"Not Found (HTTP 404)"* ]] || false
    grep -q 'postgres = on' "$T/.argocd.conf"
    [ -f "$T/gitops/apps/devzone-postgres.yaml" ]
    [ ! -f "$T/gitops/apps/devzone-mysql.yaml" ]
}

# ---- every kind of answer ----

@test "services_reconcile: an Application already up to date is written once" {
    run services_reconcile
    [ "$status" -eq 0 ]
    run services_reconcile
    [ "$status" -eq 0 ]
    [ "$(grep -c 'put apps/devzone-postgres.yaml' "$T/gitops.log")" -eq 1 ]
}

@test "services_reconcile: a service off without its file: exit 0 and no error shown" {
    SERVICES_LIST="mysql"
    run services_reconcile
    [ "$status" -eq 0 ]
    [[ "$output" == *"✔ Application devzone-mysql removed (namespace and volumes kept)"* ]] || false
    [[ "$output" != *"Not Found"* ]] || false
    [[ "$output" != *"✖"* ]] || false
    grep -q 'delete application.argoproj.io devzone-mysql --ignore-not-found' "$T/kubectl.log"
    ! grep -q 'X DELETE' "$T/gh.log" || false
}

@test "services_reconcile: a service off with its file: the file leaves the repository, exit 0" {
    printf 'kind: Application\n' >"$T/gitops/apps/devzone-mysql.yaml"
    SERVICES_LIST="mysql"
    run services_reconcile
    [ "$status" -eq 0 ]
    [ ! -f "$T/gitops/apps/devzone-mysql.yaml" ]
    grep -q 'delete apps/devzone-mysql.yaml' "$T/gitops.log"
    [[ "$output" == *"✔ Application devzone-mysql removed"* ]] || false
}

@test "services_reconcile: a write refused by gh: non-zero code, the service and the step named" {
    export FAKE_GH_ECHEC=write
    SERVICES_LIST="postgres"
    run services_reconcile
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ postgres: declare step failed"* ]] || false
    [[ "$output" != *"✔ Application devzone-postgres declared"* ]] || false
}

@test "services_reconcile: a failing service does not stop the others" {
    export FAKE_GH_ECHEC=write
    run services_reconcile
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ postgres: declare step failed"* ]] || false
    [[ "$output" == *"✔ Application devzone-mysql removed"* ]] || false
}

@test "enable postgres with a write refused by gh: exit non-zero, the service named" {
    export FAKE_GH_ECHEC=write
    run bash "$CLI" workspace services enable postgres
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ postgres: declare step failed"* ]] || false
    [[ "$output" != *"✔ Application devzone-postgres declared"* ]] || false
}
