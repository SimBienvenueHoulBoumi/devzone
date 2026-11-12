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
    *"get applications.argoproj.io"*) echo "APPLICATION KIND SYNC HEALTH" ;;
    *"get application.argoproj.io app-"*"-o jsonpath"*)
        all="$*"; n="${all#*application.argoproj.io app-}"; n="${n%% *}"
        [ -f "$T/app-$n" ] && printf 'devzone-app-%s' "$n"
        [ -f "$T/app-$n" ]; exit $?
        ;;
    *"get application.argoproj.io devzone-workspace"*) [ -f "$T/app-workspace" ]; exit $? ;;
    *"get statefulset devzone-workspace "*) echo rev-1 ;;
    *"get pod devzone-workspace-0 "*controller-revision-hash*) echo rev-1 ;;
    *"get pod devzone-workspace-0 "*) echo Running ;;
    *"create token "*) echo TOKEN ;;
    *"exec -i "*) cat >/dev/null ;;
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
    chmod +x "$T/bin/kubectl" "$T/bin/helm"
    export PATH="$T/bin:$PATH"
    export DEVZONE_WORKSPACE_ATTENTE=1 DEVZONE_WORKSPACE_PAS=0.1
    export DEVZONE_ARGOCD_REVISION="feat/essai"
    cd "$T" || return 1
    printf 'workspace=kubernetes\n' >"$T/.devzone.modules"
}

argocd_installed() { touch "$T/argocd-ns"; }

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

@test "workspace start: Argo CD installed when missing, then the workspace Application at the revision" {
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
    [ ! -f "$T/application.yaml" ]
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

@test "services disable postgres with Argo CD: --oui required without a terminal, then Application and namespace removed" {
    argocd_installed
    mkdir -p "$T/workspace/.postgres" && : >"$T/workspace/.postgres/admin-password"
    run bash "$CLI" workspace services disable postgres </dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"--oui"* ]] || false
    ! grep -q 'delete application' "$T/kubectl.log" || false
    run bash "$CLI" workspace services disable postgres --oui
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

@test "workspace argocd app list and remove" {
    argocd_installed
    run bash "$CLI" workspace argocd app list
    [ "$status" -eq 0 ]
    grep -q 'get applications.argoproj.io -l devzone.io/kind=project' "$T/kubectl.log"
    touch "$T/app-demo"
    run bash "$CLI" workspace argocd app remove demo
    [ "$status" -eq 0 ]
    [[ "$output" == *"✔ Application app-demo removed"* ]] || false
    grep -q 'delete application.argoproj.io app-demo --wait=true' "$T/kubectl.log"
    grep -q 'delete namespace devzone-app-demo --ignore-not-found --wait=true' "$T/kubectl.log"
    run bash "$CLI" workspace argocd app remove absent
    [ "$status" -eq 1 ]
    [[ "$output" == *"no Application app-absent"* ]] || false
}
