#!/usr/bin/env bats
# Argo CD of the Kubernetes workspace, from the workstation (#516): install
# and removal, the workspace and postgres as Applications, the projects
# (argocd app). Fake kubectl and helm in $BATS_TEST_TMPDIR/bin: no cluster
# is touched; the devzone folder of the workstation is $BATS_TEST_TMPDIR.

setup() {
    load commun
    relais_docker_isole
    kube_isole
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CLI="$RACINE/manage/devzone"
    T="$BATS_TEST_TMPDIR"
    mkdir -p "$T/bin" "$T/workspace"
    : >"$T/kubectl.log"
    : >"$T/helm.log"
    cat >"$T/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
echo "kubectl $*" >>"$T/kubectl.log"
case "$*" in
    "config get-contexts -o name") echo docker-desktop ;;
    *"get namespace devzone-argocd"*) [ -f "$T/argocd-ns" ]; exit $? ;;
    *"get nodes "*) echo "${FAKE_MEMORY:-4Gi}" ;;
    *"create namespace "*"--dry-run=client"*) echo "kind: Namespace" ;;
    *"apply -f -"*)
        data="$(cat)"
        printf '%s\n---\n' "$data" >>"$T/apply.yaml"
        case "$data" in *"kind: Application"*) printf '%s\n' "$data" >"$T/application.yaml" ;; esac
        ;;
    *"get secret argocd-initial-admin-secret"*) printf 'secret-admin' ;;
    *"get secret postgres-admin"*) [ -f "$T/pg-secret" ] && cat "$T/pg-secret"; [ -f "$T/pg-secret" ]; exit $? ;;
    *"create secret generic postgres-admin"*) touch "$T/pg-secret-created" ;;
    *"get applications.argoproj.io -o name"*) [ -f "$T/apps" ] && cat "$T/apps" ;;
    *"get applications.argoproj.io -l devzone.io/kind=project -o name"*) [ -f "$T/project-apps" ] && cat "$T/project-apps" ;;
    *"get applications.argoproj.io"*) echo "APPLICATION KIND SYNC HEALTH" ;;
    *"get application.argoproj.io app-"*"-o jsonpath"*)
        all="$*"; n="${all#*application.argoproj.io app-}"; n="${n%% *}"
        [ -f "$T/app-$n" ] && printf 'devzone-app-%s' "$n"
        [ -f "$T/app-$n" ]; exit $?
        ;;
    *"get application.argoproj.io devzone-workspace"*) [ -f "$T/app-workspace" ]; exit $? ;;
    *"get application.argoproj.io app-"*)
        all="$*"; n="${all#*application.argoproj.io app-}"; n="${n%% *}"
        [ -f "$T/app-$n" ]; exit $?
        ;;
    *"get statefulset devzone-workspace "*) echo rev-1 ;;
    *"get pod devzone-workspace-0 "*controller-revision-hash*) echo rev-1 ;;
    *"get pod devzone-workspace-0 "*) echo Running ;;
    *"create token "*) echo TOKEN ;;
    *"exec -i "*) cat >/dev/null ;;
    *"exec devzone-workspace-0 -c workspace -- cat "*root-token*) [ -f "$T/pod-root-token" ] && cat "$T/pod-root-token"; [ -f "$T/pod-root-token" ]; exit $? ;;
esac
exit 0
KUBE
    cat >"$T/bin/helm" <<'HELM'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
echo "helm $*" >>"$T/helm.log"
case "$*" in
    *"upgrade --install argocd "*) touch "$T/argocd-ns" ;;
    *"uninstall argocd "*) rm -f "$T/argocd-ns" ;;
esac
exit 0
HELM
    # Fake gh: the GitOps repository tester/devzone-argocd lives in $T/gitops
    cat >"$T/bin/gh" <<'GH'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
all="$*"
echo "gh $all" >>"$T/gh.log"
[ -n "${FAKE_GH_OUT:-}" ] && exit 1
case "$all" in
    "auth status") exit 0 ;;
    "auth token") echo gh-token ;;
    "api user --jq .login") echo tester ;;
    "repo view "*) [ -f "$T/gitops-repo" ]; exit $? ;;
    "repo create "*) touch "$T/gitops-repo" ;;
    "api repos/tester/devzone-argocd/contents/"*" --jq .sha")
        p="${all#api repos/tester/devzone-argocd/contents/}"; p="${p%% *}"
        [ -f "$T/gitops/$p" ] || exit 1
        git hash-object "$T/gitops/$p"
        ;;
    "api -X PUT repos/tester/devzone-argocd/contents/"*)
        p="${all#api -X PUT repos/tester/devzone-argocd/contents/}"; p="${p%% *}"
        mkdir -p "$T/gitops/$(dirname "$p")"
        for a in "$@"; do case "$a" in content=*) printf '%s' "${a#content=}" | base64 -d >"$T/gitops/$p" ;; esac; done
        echo "put $p" >>"$T/gitops.log"
        ;;
    "api -X DELETE repos/tester/devzone-argocd/contents/"*)
        p="${all#api -X DELETE repos/tester/devzone-argocd/contents/}"; p="${p%% *}"
        rm -f "$T/gitops/$p"
        echo "delete $p" >>"$T/gitops.log"
        ;;
esac
exit 0
GH
    chmod +x "$T/bin/kubectl" "$T/bin/helm" "$T/bin/gh"
    export PATH="$T/bin:$PATH"
    export DEVZONE_WORKSPACE_ATTENTE=1 DEVZONE_WORKSPACE_PAS=0.1
    export DEVZONE_ARGOCD_REVISION="feat/essai"
    export GIT_CONFIG_NOSYSTEM=1
    cd "$T" || return 1
    printf 'workspace=kubernetes\n' >"$T/.devzone.modules"
}

argocd_installed() { touch "$T/argocd-ns"; }

# A GitOps repository designated and present
gitops_ready() {
    touch "$T/gitops-repo"
    printf '[argocd]\n    repo = https://github.com/tester/devzone-argocd.git\n' >"$T/.argocd.conf"
}

# ---- Argo CD itself ----

@test "services enable argocd: pinned chart, admin password in admin.env and .password, never printed" {
    run bash "$CLI" workspace services enable argocd
    [ "$status" -eq 0 ]
    [[ "$output" != *"secret-admin"* ]] || false
    [[ "$output" == *"✔ Argo CD ready: https://localhost:8443"* ]] || false
    grep -q 'label namespace devzone-argocd app.kubernetes.io/managed-by=devzone' "$T/kubectl.log"
    grep -q -- 'upgrade --install argocd argo/argo-cd --version 10.14.0 --namespace devzone-argocd -f .*/.devcontainer/argocd/values.yaml --timeout 600s --wait' "$T/helm.log"
    [ "$(stat -c '%a' "$T/workspace/.argocd/admin.env")" = 600 ]
    grep -qx 'ARGOCD_PASSWORD=secret-admin' "$T/workspace/.argocd/admin.env"
    grep -qx 'ARGOCD_URL=https://localhost:8443' "$T/workspace/.argocd/admin.env"
    [ "$(stat -c '%a' "$T/.password")" = 600 ]
    grep -q "$(printf 'argocd\thttps://127.0.0.1:8443\tadmin\tsecret-admin')" "$T/.password"
    grep -qx 'argocd=on' "$T/.devzone.modules"
    grep -qx 'workspace=kubernetes' "$T/.devzone.modules"
}

@test "services enable argocd: under 1 Gi of memory, refused and state untouched" {
    export FAKE_MEMORY=512Mi
    run bash "$CLI" workspace services enable argocd
    [ "$status" -eq 2 ]
    [[ "$output" == *"at least 1 Gi of allocatable memory"* ]] || false
    [ ! -s "$T/helm.log" ]
    ! grep -q 'argocd=on' "$T/.devzone.modules" || false
}

@test "services disable argocd: Applications released without cascade, release and namespace removed, state off" {
    argocd_installed
    printf 'application.argoproj.io/devzone-postgres\napplication.argoproj.io/app-demo\n' >"$T/apps"
    mkdir -p "$T/workspace/.argocd" && : >"$T/workspace/.argocd/admin.env"
    run bash "$CLI" workspace services disable argocd
    [ "$status" -eq 0 ]
    [[ "$output" == *"the services stay, under helm direct"* ]] || false
    grep -q 'patch application.argoproj.io devzone-postgres --type merge -p {"metadata":{"finalizers":null}}' "$T/kubectl.log"
    grep -q 'delete application.argoproj.io devzone-postgres --ignore-not-found --wait=true' "$T/kubectl.log"
    grep -q 'patch application.argoproj.io app-demo ' "$T/kubectl.log"
    grep -q 'uninstall argocd --namespace devzone-argocd' "$T/helm.log"
    grep -q 'delete namespace devzone-argocd --wait=true' "$T/kubectl.log"
    [ ! -e "$T/workspace/.argocd" ]
    grep -qx 'argocd=off' "$T/.devzone.modules"
}

@test "workspace argocd status: not installed, then installed with its Applications" {
    run bash "$CLI" workspace argocd status
    [ "$status" -eq 0 ]
    [[ "$output" == *"○ argocd not installed: devzone workspace services enable argocd"* ]] || false
    argocd_installed
    run bash "$CLI" workspace argocd
    [ "$status" -eq 0 ]
    [[ "$output" == *"✔ argocd installed: https://localhost:8443"* ]] || false
    [[ "$output" == *"APPLICATION KIND SYNC HEALTH"* ]] || false
}

# ---- the workspace as an Application ----

@test "workspace start: Argo CD installed when missing, then the workspace Application at the revision (gh not connected: direct)" {
    export FAKE_GH_OUT=1
    run bash "$CLI" workspace demarrer
    [ "$status" -eq 0 ]
    grep -q 'upgrade --install argocd argo/argo-cd' "$T/helm.log"
    ! grep -q 'upgrade --install devzone-workspace' "$T/helm.log" || false
    grep -q 'name: devzone-workspace' "$T/application.yaml"
    grep -q 'devzone.io/kind: workspace' "$T/application.yaml"
    grep -q 'repoURL: https://github.com/SimBienvenueHoulBoumi/devzone.git' "$T/application.yaml"
    grep -q 'targetRevision: feat/essai' "$T/application.yaml"
    grep -q 'path: charts/devzone-workspace' "$T/application.yaml"
    grep -q 'name: image.tag' "$T/application.yaml"
    grep -q 'value: "latest"' "$T/application.yaml"
    grep -q 'name: image.pullPolicy' "$T/application.yaml"
    grep -q 'delete secret -l owner=helm,name=devzone-workspace --ignore-not-found' "$T/kubectl.log"
    [[ "$output" == *"✔ workspace"* ]] || false
}

@test "workspace start --image: repository and tag as Helm parameters, no pullPolicy" {
    export FAKE_GH_OUT=1
    argocd_installed
    run bash "$CLI" workspace demarrer --image registre.local/ws:essai
    [ "$status" -eq 0 ]
    grep -q 'name: image.repository' "$T/application.yaml"
    grep -q 'value: "registre.local/ws"' "$T/application.yaml"
    grep -q 'value: "essai"' "$T/application.yaml"
    ! grep -q 'pullPolicy' "$T/application.yaml" || false
    ! grep -q 'upgrade --install argocd' "$T/helm.log" || false
}

@test "workspace start on a development clone without revision: helm direct and the notice" {
    unset DEVZONE_ARGOCD_REVISION
    argocd_installed
    run bash "$CLI" workspace demarrer
    [ "$status" -eq 0 ]
    [[ "$output" == *"development clone (version 0.0.0): helm direct"* ]] || false
    grep -q 'upgrade --install devzone-workspace' "$T/helm.log"
    ! grep -q 'name: devzone-workspace' "$T/application.yaml" 2>/dev/null || false
}

@test "workspace start with argocd=off: no Argo CD, helm direct, no notice" {
    printf 'workspace=kubernetes\nargocd=off\n' >"$T/.devzone.modules"
    run bash "$CLI" workspace demarrer
    [ "$status" -eq 0 ]
    ! grep -q 'argo/argo-cd' "$T/helm.log" || false
    grep -q 'upgrade --install devzone-workspace' "$T/helm.log"
    [[ "$output" != *"development clone"* ]] || false
    [ ! -f "$T/application.yaml" ]
}

@test "workspace start: Argo CD refused (memory), warning and helm direct" {
    export FAKE_MEMORY=512Mi
    run bash "$CLI" workspace demarrer
    [ "$status" -eq 0 ]
    [[ "$output" == *"⚠ Argo CD not installed: the workspace is deployed with helm directly"* ]] || false
    grep -q 'upgrade --install devzone-workspace' "$T/helm.log"
}

@test "workspace stop: the Application is deleted when it exists, helm uninstall otherwise" {
    argocd_installed
    touch "$T/app-workspace"
    run bash "$CLI" workspace arreter
    [ "$status" -eq 0 ]
    grep -q 'delete application.argoproj.io devzone-workspace --ignore-not-found --wait=true' "$T/kubectl.log"
    ! grep -q 'uninstall devzone-workspace' "$T/helm.log" || false
    rm -f "$T/app-workspace"
    run bash "$CLI" workspace arreter
    [ "$status" -eq 0 ]
    grep -q 'uninstall devzone-workspace --namespace devzone-workspace' "$T/helm.log"
}

# ---- postgres as an Application ----

@test "services enable postgres with Argo CD: namespace isolated, secret created apart, Application declared" {
    argocd_installed
    run bash "$CLI" workspace services enable postgres
    [ "$status" -eq 0 ]
    [[ "$output" == *"✔ Application devzone-postgres declared"* ]] || false
    grep -q 'label namespace devzone-postgres app.kubernetes.io/managed-by=devzone' "$T/kubectl.log"
    grep -q 'kind: NetworkPolicy' "$T/apply.yaml"
    grep -q 'name: devzone-meme-namespace' "$T/apply.yaml"
    [ -f "$T/pg-secret-created" ]
    [ "$(stat -c '%a' "$T/workspace/.postgres/admin-password")" = 600 ]
    [ "$(wc -c <"$T/workspace/.postgres/admin-password" | tr -d ' ')" -eq 48 ]
    grep -q "$(printf 'postgres\t127.0.0.1:5432\tpostgres\t')$(cat "$T/workspace/.postgres/admin-password")" "$T/.password"
    grep -q 'name: devzone-postgres' "$T/application.yaml"
    grep -q 'devzone.io/kind: service' "$T/application.yaml"
    grep -q 'path: charts/devzone-postgres' "$T/application.yaml"
    grep -q 'targetRevision: feat/essai' "$T/application.yaml"
    ! grep -q 'exec -i' "$T/kubectl.log" || false
    [[ "$output" != *"$(cat "$T/workspace/.postgres/admin-password")"* ]] || false
}

@test "services enable postgres with Argo CD: an existing secret is kept and mirrored" {
    argocd_installed
    printf 'already-there' >"$T/pg-secret"
    run bash "$CLI" workspace services enable postgres
    [ "$status" -eq 0 ]
    [ ! -f "$T/pg-secret-created" ]
    [ "$(cat "$T/workspace/.postgres/admin-password")" = "already-there" ]
}

@test "services disable postgres with Argo CD: --yes required without a terminal, then Application and namespace removed" {
    argocd_installed
    mkdir -p "$T/workspace/.postgres" && : >"$T/workspace/.postgres/admin-password"
    run bash "$CLI" workspace services disable postgres </dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"--yes"* ]] || false
    ! grep -q 'delete application' "$T/kubectl.log" || false
    run bash "$CLI" workspace services disable postgres --yes
    [ "$status" -eq 0 ]
    grep -q 'delete application.argoproj.io devzone-postgres --ignore-not-found --wait=true' "$T/kubectl.log"
    ! grep -q 'patch application.argoproj.io devzone-postgres' "$T/kubectl.log" || false
    grep -q 'delete namespace devzone-postgres --wait=true' "$T/kubectl.log"
    [ ! -e "$T/workspace/.postgres" ]
}

@test "services enable postgres without Argo CD: the installer runs in the pod (#528)" {
    printf 'workspace=kubernetes\nargocd=off\n' >"$T/.devzone.modules"
    run bash "$CLI" workspace services enable postgres
    [ "$status" -eq 0 ]
    grep -q 'exec -i devzone-workspace-0 .*services-admin.sh enable postgres' "$T/kubectl.log"
    [ ! -f "$T/application.yaml" ]
}

# ---- projects ----

@test "workspace argocd app add: Application of a public repository, name from the URL" {
    argocd_installed
    run bash "$CLI" workspace argocd app add https://github.com/argoproj/argocd-example-apps guestbook
    [ "$status" -eq 0 ]
    [[ "$output" == *"✔ Application app-argocd-example-apps"*"devzone workspace argocd app list"* ]] || false
    grep -q 'name: app-argocd-example-apps' "$T/application.yaml"
    grep -q 'devzone.io/kind: project' "$T/application.yaml"
    grep -q 'repoURL: https://github.com/argoproj/argocd-example-apps' "$T/application.yaml"
    grep -q 'path: guestbook' "$T/application.yaml"
    grep -q 'targetRevision: HEAD' "$T/application.yaml"
    grep -q 'namespace: devzone-app-argocd-example-apps' "$T/application.yaml"
    run bash "$CLI" workspace argocd app add https://github.com/x/Mon.Repo.git --name demo --revision main --namespace equipe
    [ "$status" -eq 0 ]
    grep -q 'name: app-demo' "$T/application.yaml"
    grep -q 'targetRevision: main' "$T/application.yaml"
    grep -q 'namespace: equipe' "$T/application.yaml"
    grep -q 'path: \.$' "$T/application.yaml"
}

@test "workspace argocd app add: refusals (no URL, not a URL, invalid name, unknown option, Argo CD missing)" {
    run bash "$CLI" workspace argocd app add
    [ "$status" -eq 1 ]
    [[ "$output" == *"Argo CD not installed"* ]] || false
    argocd_installed
    run bash "$CLI" workspace argocd app add
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage: devzone workspace argocd app add"* ]] || false
    run bash "$CLI" workspace argocd app add mon-projet
    [ "$status" -eq 2 ]
    [[ "$output" == *"repository URL expected"* ]] || false
    run bash "$CLI" workspace argocd app add https://x/y.git --name Demo
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid name: Demo"* ]] || false
    run bash "$CLI" workspace argocd app add https://x/y.git --oops
    [ "$status" -eq 2 ]
    [ ! -f "$T/application.yaml" ]
}

@test "workspace argocd app add: the devzone GitLab, internal URL, root token in a repository Secret, policy opened" {
    argocd_installed
    mkdir -p "$T/workspace/.gitlab" && printf 'glpat-SECRET' >"$T/workspace/.gitlab/root-token"
    run bash "$CLI" workspace argocd app add http://gitlab.localhost:8929/devzone/demo.git k8s
    [ "$status" -eq 0 ]
    [[ "$output" != *"glpat-SECRET"* ]] || false
    [[ "$output" == *"credentials in the Secret repo-demo"* ]] || false
    grep -q 'repoURL: http://gitlab-webservice-default.devzone-gitlab.svc:8181/devzone/demo.git' "$T/application.yaml"
    grep -q 'argocd.argoproj.io/secret-type: repository' "$T/apply.yaml"
    grep -q 'name: repo-demo' "$T/apply.yaml"
    grep -q 'url: http://gitlab-webservice-default.devzone-gitlab.svc:8181/devzone/demo.git' "$T/apply.yaml"
    grep -q 'username: root' "$T/apply.yaml"
    grep -q 'password: glpat-SECRET' "$T/apply.yaml"
    grep -q -- '-n devzone-gitlab patch networkpolicy devzone-meme-namespace --type merge' "$T/kubectl.log"
    ! grep -q 'glpat-SECRET' "$T/kubectl.log" || false
}

@test "workspace argocd app add: GitLab token read in the pod, or --token; refused without any" {
    argocd_installed
    printf 'from-pod' >"$T/pod-root-token"
    run bash "$CLI" workspace argocd app add http://gitlab.localhost:8929/devzone/demo.git
    [ "$status" -eq 0 ]
    grep -q 'password: from-pod' "$T/apply.yaml"
    rm -f "$T/pod-root-token" "$T/apply.yaml"
    run bash "$CLI" workspace argocd app add http://gitlab.localhost:8929/devzone/demo.git --token given
    [ "$status" -eq 0 ]
    grep -q 'password: given' "$T/apply.yaml"
    rm -f "$T/apply.yaml" "$T/application.yaml"
    run bash "$CLI" workspace argocd app add http://gitlab.localhost:8929/devzone/demo.git
    [ "$status" -eq 2 ]
    [[ "$output" == *"token of the devzone GitLab not found"*"--token"* ]] || false
    [ ! -f "$T/application.yaml" ]
}

@test "workspace argocd app add: private GitHub repository with --token and --username, URL unchanged" {
    argocd_installed
    run bash "$CLI" workspace argocd app add https://github.com/x/private.git --token ghp-x --username bob
    [ "$status" -eq 0 ]
    grep -q 'repoURL: https://github.com/x/private.git' "$T/application.yaml"
    grep -q 'url: https://github.com/x/private.git' "$T/apply.yaml"
    grep -q 'username: bob' "$T/apply.yaml"
    grep -q 'password: ghp-x' "$T/apply.yaml"
    ! grep -q 'patch networkpolicy' "$T/kubectl.log" || false
    rm -f "$T/apply.yaml"
    run bash "$CLI" workspace argocd app add https://github.com/x/public.git
    [ "$status" -eq 0 ]
    ! grep -q 'secret-type: repository' "$T/apply.yaml" || false
}

# ---- .argocd.conf and the GitOps repository ----

@test "workspace argocd init: private repository created, .argocd.conf written, root Application and repository Secret" {
    argocd_installed
    run bash "$CLI" workspace argocd init
    [ "$status" -eq 0 ]
    [[ "$output" == *"✔ GitOps repository created: https://github.com/tester/devzone-argocd (private)"* ]] || false
    [[ "$output" != *"gh-token"* ]] || false
    grep -q 'repo create tester/devzone-argocd --private' "$T/gh.log"
    grep -q '^\[argocd\]$' "$T/.argocd.conf"
    grep -q '^    repo = https://github.com/tester/devzone-argocd.git$' "$T/.argocd.conf"
    [ -s "$T/gitops/README.md" ]
    [ -f "$T/gitops/apps/.gitkeep" ]
    grep -q 'name: devzone$' "$T/application.yaml"
    grep -q 'devzone.io/kind: root' "$T/application.yaml"
    grep -q 'path: apps' "$T/application.yaml"
    grep -q 'repoURL: https://github.com/tester/devzone-argocd.git' "$T/application.yaml"
    grep -q 'name: repo-devzone-argocd' "$T/apply.yaml"
    grep -q 'password: gh-token' "$T/apply.yaml"
    run bash "$CLI" workspace argocd init
    [ "$status" -eq 0 ]
    [ "$(grep -c 'repo create' "$T/gh.log")" -eq 1 ]
}

@test "workspace argocd init --repo: missing repository created with README and apps folder" {
    argocd_installed
    run bash "$CLI" workspace argocd init --repo https://github.com/tester/devzone-argocd.git
    [ "$status" -eq 0 ]
    [[ "$output" == *"✔ GitOps repository created: https://github.com/tester/devzone-argocd (private)"* ]] || false
    grep -q 'gh repo create tester/devzone-argocd --private' "$T/gh.log"
    [ -s "$T/gitops/README.md" ]
    [ -f "$T/gitops/apps/.gitkeep" ]
    grep -q '^\[argocd\]$' "$T/.argocd.conf"
    grep -q '^    repo = https://github.com/tester/devzone-argocd.git$' "$T/.argocd.conf"
}

@test "workspace argocd init --repo: existing repository, nothing created" {
    argocd_installed
    gitops_ready
    run bash "$CLI" workspace argocd init --repo https://github.com/tester/devzone-argocd.git
    [ "$status" -eq 0 ]
    [ "$(grep -c 'repo create' "$T/gh.log")" -eq 0 ]
    [ ! -e "$T/gitops.log" ]
    grep -q '^\[argocd\]$' "$T/.argocd.conf"
    grep -q '^    repo = https://github.com/tester/devzone-argocd.git$' "$T/.argocd.conf"
}

@test "workspace argocd init: gh not connected → notice and direct apply; --none noted in .argocd.conf" {
    argocd_installed
    export FAKE_GH_OUT=1
    run bash "$CLI" workspace argocd init
    [ "$status" -eq 0 ]
    [[ "$output" == *"GitHub not connected"* ]] || false
    [ ! -f "$T/.argocd.conf" ]
    unset FAKE_GH_OUT
    run bash "$CLI" workspace argocd init --none
    [ "$status" -eq 0 ]
    grep -q '^    repo = none$' "$T/.argocd.conf"
    run bash "$CLI" workspace argocd app add https://github.com/x/y.git
    [ "$status" -eq 0 ]
    grep -q 'name: app-y' "$T/application.yaml"
    [ ! -f "$T/gitops.log" ]
}

@test "workspace start with a GitOps repository: the workspace Application goes to apps/, written once" {
    argocd_installed
    gitops_ready
    run bash "$CLI" workspace demarrer
    [ "$status" -eq 0 ]
    grep -q 'targetRevision: feat/essai' "$T/gitops/apps/devzone-workspace.yaml"
    grep -q 'name: image.tag' "$T/gitops/apps/devzone-workspace.yaml"
    grep -q 'name: devzone$' "$T/application.yaml"
    grep -q 'annotate application.argoproj.io devzone argocd.argoproj.io/refresh=normal' "$T/kubectl.log"
    run bash "$CLI" workspace demarrer
    [ "$status" -eq 0 ]
    [ "$(grep -c 'put apps/devzone-workspace.yaml' "$T/gitops.log")" -eq 1 ]
}

@test "workspace argocd app add with a GitOps repository: [app] in .argocd.conf and apps/app-<N>.yaml" {
    argocd_installed
    gitops_ready
    run bash "$CLI" workspace argocd app add https://github.com/argoproj/argocd-example-apps guestbook --name demo
    [ "$status" -eq 0 ]
    [[ "$output" == *"declared in $T/.argocd.conf"* ]] || false
    grep -q '^\[app demo\]$' "$T/.argocd.conf"
    grep -q '^    repo = https://github.com/argoproj/argocd-example-apps$' "$T/.argocd.conf"
    grep -q '^    path = guestbook$' "$T/.argocd.conf"
    grep -q '^    namespace = devzone-app-demo$' "$T/.argocd.conf"
    grep -q 'path: guestbook' "$T/gitops/apps/app-demo.yaml"
    ! grep -q 'name: app-demo' "$T/application.yaml" || false
}

@test "workspace argocd app add --token: the token in workspace/.argocd/tokens, only its path in .argocd.conf" {
    argocd_installed
    run bash "$CLI" workspace argocd app add https://github.com/x/private.git --token ghp-secret --username bob
    [ "$status" -eq 0 ]
    [ "$(cat "$T/workspace/.argocd/tokens/private")" = "ghp-secret" ]
    [ "$(stat -c '%a' "$T/workspace/.argocd/tokens/private")" = 600 ]
    grep -q '^    token-file = workspace/.argocd/tokens/private$' "$T/.argocd.conf"
    grep -q '^    username = bob$' "$T/.argocd.conf"
    ! grep -q 'ghp-secret' "$T/.argocd.conf" || false
    grep -q 'password: ghp-secret' "$T/apply.yaml"
}

@test "workspace argocd apply: every [app] of .argocd.conf applied, the project Applications absent from it removed" {
    argocd_installed
    gitops_ready
    cat >>"$T/.argocd.conf" <<'CONF'

[app one]
    repo = https://github.com/x/one.git
    path = k8s

[app two]
    repo = https://github.com/x/two.git   # comment
CONF
    echo "application.argoproj.io/app-old" >"$T/project-apps"
    touch "$T/app-old"
    mkdir -p "$T/gitops/apps" && echo x >"$T/gitops/apps/app-old.yaml"
    run bash "$CLI" workspace argocd apply
    [ "$status" -eq 0 ]
    grep -q 'path: k8s' "$T/gitops/apps/app-one.yaml"
    grep -q 'repoURL: https://github.com/x/two.git' "$T/gitops/apps/app-two.yaml"
    grep -q 'delete apps/app-old.yaml' "$T/gitops.log"
    grep -q 'delete application.argoproj.io app-old --ignore-not-found --wait=true' "$T/kubectl.log"
    grep -q 'delete namespace devzone-app-old' "$T/kubectl.log"
    [[ "$output" == *"✔ Application app-old removed"* ]] || false
}

@test "workspace argocd app remove with a GitOps repository: section, file, Secret and namespace gone" {
    argocd_installed
    gitops_ready
    printf '\n[app demo]\n    repo = https://github.com/x/demo.git\n' >>"$T/.argocd.conf"
    mkdir -p "$T/gitops/apps" && echo x >"$T/gitops/apps/app-demo.yaml"
    touch "$T/app-demo"
    run bash "$CLI" workspace argocd app remove demo
    [ "$status" -eq 0 ]
    ! grep -q 'app demo' "$T/.argocd.conf" || false
    [ ! -f "$T/gitops/apps/app-demo.yaml" ]
    grep -q 'delete secret repo-demo' "$T/kubectl.log"
    grep -q 'delete namespace devzone-app-demo' "$T/kubectl.log"
}

@test "workspace argocd app list and remove" {
    argocd_installed
    run bash "$CLI" workspace argocd app list
    [ "$status" -eq 0 ]
    grep -q 'get applications.argoproj.io -l devzone.io/kind=project' "$T/kubectl.log"
    touch "$T/app-demo"
    run bash "$CLI" workspace argocd app remove demo
    [ "$status" -eq 0 ]
    [[ "$output" == *"✔ Application app-demo removed"* ]] || false
    grep -q 'delete application.argoproj.io app-demo --ignore-not-found --wait=true' "$T/kubectl.log"
    grep -q 'delete secret repo-demo --ignore-not-found' "$T/kubectl.log"
    grep -q 'delete namespace devzone-app-demo --ignore-not-found --wait=true' "$T/kubectl.log"
    run bash "$CLI" workspace argocd app remove absent
    [ "$status" -eq 1 ]
    [[ "$output" == *"no Application app-absent"* ]] || false
}
