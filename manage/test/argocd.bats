#!/usr/bin/env bats
# Module argocd (#411): isolated install, admin password and relay access.
# Fake helm, kubectl and nohup in the PATH: no cluster touched.

setup() {
    bats_require_minimum_version 1.5.0
    load commun
    relais_docker_isole
    kube_isole
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    ARGOCD="$BATS_TEST_DIRNAME/../../.devcontainer/argocd/argocd.sh"
    export DEVZONE_RACINE="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_ETAT="$BATS_TEST_TMPDIR/modules"
    SECRETS="$DEVZONE_RACINE/workspace/.argocd"
    mkdir -p "$HOME" "$DEVZONE_RACINE/workspace" "$BATS_TEST_TMPDIR/bin"
    printf 'argocd=off\ncluster=docker-desktop\n' >"$DEVZONE_ETAT"
    # Host cluster: docker-desktop, with its empty kubeconfig (isolated)
    : >"$DEVZONE_KUBE_HOTE"

    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"$BATS_TEST_TMPDIR/kubectl.log"
T="$BATS_TEST_TMPDIR"
case "$*" in
    *"config get-contexts -o name"*) echo "docker-desktop" ;;
    *"get nodes"*)
        case "${FAUX_MEMOIRE_CLUSTER:-2Gi}" in
            injoignable) exit 1 ;;
            *) echo "${FAUX_MEMOIRE_CLUSTER:-2Gi}" ;;
        esac
        ;;
    *"get namespace devzone-argocd"*) [ -f "$T/ns" ]; exit $? ;;
    *"create namespace"*) printf 'kind: Namespace\nmetadata:\n  name: devzone-argocd\n' ;;
    *"label namespace"*) ;;
    *"apply -f -"*)
        cat >>"$T/apply.log"
        touch "$T/ns"
        ;;
    *"get secret argocd-initial-admin-secret"*) printf 'c2VjcmV0LWFkbWlu' ;;
    *"delete namespace devzone-argocd"*) rm -f "$T/ns" ;;
    *"config current-context"*) echo "docker-desktop" ;;
    *"auth can-i"*) echo no ;;
    *"port-forward"*) exec sleep 300 ;;
esac
exit 0
KUBE

    cat >"$BATS_TEST_TMPDIR/bin/helm" <<'HELM'
#!/usr/bin/env bash
echo "helm $*" >>"$BATS_TEST_TMPDIR/helm.log"
exit 0
HELM

    cat >"$BATS_TEST_TMPDIR/bin/kind" <<'KIND'
#!/usr/bin/env bash
case "$1 $2" in
    "get clusters") ;;
esac
exit 0
KIND

    cat >"$BATS_TEST_TMPDIR/bin/nohup" <<'NOHUP'
#!/usr/bin/env bash
echo "nohup $*" >>"$BATS_TEST_TMPDIR/nohup.log"
exec sleep 300
NOHUP

    printf '#!/usr/bin/env bash\nexit 1\n' >"$BATS_TEST_TMPDIR/bin/gh"
    chmod +x "$BATS_TEST_TMPDIR/bin/"*
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

teardown() {
    bash "$ARGOCD" relay-stop >/dev/null 2>&1 || true
}

# Prepares an already installed module: namespace present, admin.env and relay.
argocd_installed() {
    touch "$BATS_TEST_TMPDIR/ns"
    mkdir -p "$SECRETS"
    printf 'ARGOCD_URL=https://127.0.0.1:8443\nARGOCD_USER=admin\nARGOCD_PASSWORD=secret-admin\n' \
        >"$SECRETS/admin.env"
    printf 'argocd=on\ncluster=docker-desktop\n' >"$DEVZONE_ETAT"
}

wait_nohup() {
    local pattern="$1" i=0
    while [ "$i" -lt 50 ]; do
        if grep -q -- "$pattern" "$BATS_TEST_TMPDIR/nohup.log" 2>/dev/null; then return 0; fi
        i=$((i + 1))
        sleep 0.1
    done
    echo "nohup.log: line missing after 5 s: $pattern" >&2
    return 1
}

@test "argocd: disabled by default, module status optional" {
    run bash "$DEVZONE" is-enabled argocd
    [ "$status" -ne 0 ]
    run bash "$ARGOCD" status
    [ "$status" -eq 0 ]
    [ "$output" = "désactivé" ]
}

@test "enable argocd: isolated namespace, pinned chart, password stored, relay started" {
    run bash "$DEVZONE" enable argocd </dev/null
    [ "$status" -eq 0 ]
    grep -qx 'argocd=on' "$DEVZONE_ETAT"
    grep -q 'kind: NetworkPolicy' "$BATS_TEST_TMPDIR/apply.log"
    grep -q 'name: devzone-meme-namespace' "$BATS_TEST_TMPDIR/apply.log"
    # Namespace label set by the administrator, not by the limited account (#430)
    grep -q -- '--context docker-desktop label namespace devzone-argocd app.kubernetes.io/managed-by=devzone' "$BATS_TEST_TMPDIR/kubectl.log"
    # Wrapper chart charts/devzone-argocd: dependency built, then the local chart
    # installed with the devzone context (#538)
    grep -Eq 'helm dependency build .*charts/devzone-argocd' "$BATS_TEST_TMPDIR/helm.log"
    grep -Eq 'helm --kubeconfig [^ ]+ --kube-context docker-desktop upgrade --install argocd .*charts/devzone-argocd --namespace devzone-argocd' "$BATS_TEST_TMPDIR/helm.log"
    ! grep -q 'argo/argo-cd' "$BATS_TEST_TMPDIR/helm.log" || false
    [ -f "$SECRETS/admin.env" ]
    [ "$(stat -c '%a' "$SECRETS/admin.env")" = 600 ]
    grep -qx 'ARGOCD_PASSWORD=secret-admin' "$SECRETS/admin.env"
    grep -qx 'ARGOCD_URL=https://127.0.0.1:8443' "$SECRETS/admin.env"
    [ -f "$DEVZONE_RACINE/.password" ]
    [ "$(stat -c '%a' "$DEVZONE_RACINE/.password")" = 600 ]
    grep -q "$(printf 'argocd\thttps://127.0.0.1:8443\tadmin\tsecret-admin')" "$DEVZONE_RACINE/.password"
    wait_nohup '8443:443'
    [[ "$output" == *"✔ argocd module ready: https://127.0.0.1:8443"* ]] || false
    [[ "$output" != *"secret-admin"* ]] || false
}

@test "enable argocd: less than 1 GB of allocatable memory → refused, nothing installed" {
    run env FAUX_MEMOIRE_CLUSTER=512Mi bash "$DEVZONE" enable argocd </dev/null
    [ "$status" -ne 0 ]
    [[ "$output" == *"at least 1 GB of allocatable memory"* ]] || false
    [ ! -f "$BATS_TEST_TMPDIR/ns" ]
    [ ! -f "$BATS_TEST_TMPDIR/helm.log" ]
}

@test "status after installation: ready, relay stopped reported" {
    argocd_installed
    run bash "$ARGOCD" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"relais arrêté"* ]] || false
}

@test "enable argocd already installed: relay restarted, no new installation" {
    argocd_installed
    rm -f "$BATS_TEST_TMPDIR/helm.log"
    run bash "$DEVZONE" enable argocd </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"relais relancé"* ]] || false
    [ ! -f "$BATS_TEST_TMPDIR/helm.log" ]
    wait_nohup '8443:443'
}

@test "argocd app add: Application of the project applied with the devzone context (#516)" {
    argocd_installed
    run bash "$DEVZONE" argocd app add https://github.com/argoproj/argocd-example-apps guestbook
    [ "$status" -eq 0 ]
    [[ "$output" == *"✔ Application app-argocd-example-apps"* ]] || false
    grep -q 'kind: Application' "$BATS_TEST_TMPDIR/apply.log"
    grep -q 'name: app-argocd-example-apps' "$BATS_TEST_TMPDIR/apply.log"
    grep -q 'devzone.io/kind: project' "$BATS_TEST_TMPDIR/apply.log"
    grep -q 'path: guestbook' "$BATS_TEST_TMPDIR/apply.log"
    grep -q 'namespace: devzone-app-argocd-example-apps' "$BATS_TEST_TMPDIR/apply.log"
    grep -q -- '--context devzone apply -f -' "$BATS_TEST_TMPDIR/kubectl.log"
}

@test "argocd app add: devzone GitLab, internal URL and module root token in a repository Secret" {
    argocd_installed
    mkdir -p "$DEVZONE_RACINE/workspace/.gitlab"
    printf 'glpat-SECRET' >"$DEVZONE_RACINE/workspace/.gitlab/root-token"
    run bash "$DEVZONE" argocd app add http://gitlab.localhost:8929/devzone/demo.git k8s
    [ "$status" -eq 0 ]
    [[ "$output" != *"glpat-SECRET"* ]] || false
    grep -q 'repoURL: http://gitlab-webservice-default.devzone-gitlab.svc:8181/devzone/demo.git' "$BATS_TEST_TMPDIR/apply.log"
    grep -q 'argocd.argoproj.io/secret-type: repository' "$BATS_TEST_TMPDIR/apply.log"
    grep -q 'password: glpat-SECRET' "$BATS_TEST_TMPDIR/apply.log"
    grep -q -- '--context devzone -n devzone-gitlab patch networkpolicy devzone-meme-namespace' "$BATS_TEST_TMPDIR/kubectl.log"
}

@test "argocd app: module disabled refused, and redirect to the workstation in the workspace pod" {
    run bash "$DEVZONE" argocd app list
    [ "$status" -eq 2 ]
    [[ "$output" == *"module off: devzone enable argocd"* ]] || false
    argocd_installed
    run env DEVZONE_WORKSPACE=kubernetes bash "$DEVZONE" argocd app list
    [ "$status" -eq 2 ]
    [[ "$output" == *"devzone workspace argocd app list"* ]] || false
}

@test "disable argocd: helm uninstall, namespace deleted, services kept" {
    argocd_installed
    run bash "$DEVZONE" disable argocd
    [ "$status" -eq 0 ]
    grep -qx 'argocd=off' "$DEVZONE_ETAT"
    grep -Eq 'helm --kubeconfig [^ ]+ --kube-context docker-desktop uninstall argocd -n devzone-argocd' "$BATS_TEST_TMPDIR/helm.log"
    # Namespace deleted by the administrator, not by the limited account (#430)
    grep -q -- '--context docker-desktop delete namespace devzone-argocd' "$BATS_TEST_TMPDIR/kubectl.log"
    [ ! -e "$SECRETS" ]
    [[ "$output" == *"the services stay, under direct helm"* ]] || false
}

# ---- French names (#557): same result as the English name, with the warning ----
# argocd has no French option (its table only holds subcommands)

@test "argocd: English names give no warning" {
    argocd_installed
    run --separate-stderr bash "$ARGOCD" status
    [ "$status" -eq 0 ] || false
    [[ "$stderr" != *"deprecated"* ]] || false
    run --separate-stderr bash "$ARGOCD" relay-start
    [ "$status" -eq 0 ] || false
    [[ "$stderr" != *"deprecated"* ]] || false
    run --separate-stderr bash "$ARGOCD" relay-stop
    [ "$status" -eq 0 ] || false
    [[ "$stderr" != *"deprecated"* ]] || false
}
