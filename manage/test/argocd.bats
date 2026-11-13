#!/usr/bin/env bats
# Module argocd (#411) : installation isolée, mot de passe admin et accès par
# relais. Faux helm, kubectl et nohup dans le PATH : aucun cluster touché.

setup() {
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
    # Cluster de l'hôte : docker-desktop, avec son kubeconfig vide (isolé)
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
    bash "$ARGOCD" relais-arreter >/dev/null 2>&1 || true
}

# Prépare un module déjà installé : namespace présent, admin.env et relais.
argocd_installe() {
    touch "$BATS_TEST_TMPDIR/ns"
    mkdir -p "$SECRETS"
    printf 'ARGOCD_URL=https://127.0.0.1:8443\nARGOCD_USER=admin\nARGOCD_PASSWORD=secret-admin\n' \
        >"$SECRETS/admin.env"
    printf 'argocd=on\ncluster=docker-desktop\n' >"$DEVZONE_ETAT"
}

attendre_nohup() {
    local motif="$1" i=0
    while [ "$i" -lt 50 ]; do
        if grep -q -- "$motif" "$BATS_TEST_TMPDIR/nohup.log" 2>/dev/null; then return 0; fi
        i=$((i + 1))
        sleep 0.1
    done
    echo "nohup.log : ligne absente après 5 s : $motif" >&2
    return 1
}

@test "argocd : désactivé par défaut, état du module facultatif" {
    run bash "$DEVZONE" actif argocd
    [ "$status" -ne 0 ]
    run bash "$ARGOCD" etat
    [ "$status" -eq 0 ]
    [ "$output" = "désactivé" ]
}

@test "activer argocd : namespace isolé, chart figé, mot de passe rangé, relais lancé" {
    run bash "$DEVZONE" activer argocd </dev/null
    [ "$status" -eq 0 ]
    grep -qx 'argocd=on' "$DEVZONE_ETAT"
    grep -q 'kind: NetworkPolicy' "$BATS_TEST_TMPDIR/apply.log"
    grep -q 'name: devzone-meme-namespace' "$BATS_TEST_TMPDIR/apply.log"
    # Étiquette du namespace posée par l'administrateur, pas par le compte
    # limité (#430)
    grep -q -- '--context docker-desktop label namespace devzone-argocd app.kubernetes.io/managed-by=devzone' "$BATS_TEST_TMPDIR/kubectl.log"
    # Chart enveloppe charts/devzone-argocd : dépendance construite puis
    # installation du chart local, avec le contexte devzone (#538)
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
    attendre_nohup '8443:443'
    [[ "$output" == *"✔ module argocd prêt : https://127.0.0.1:8443"* ]] || false
    [[ "$output" != *"secret-admin"* ]] || false
}

@test "activer argocd : moins de 1 Go de mémoire allouable → refus, rien installé" {
    run env FAUX_MEMOIRE_CLUSTER=512Mi bash "$DEVZONE" activer argocd </dev/null
    [ "$status" -ne 0 ]
    [[ "$output" == *"au moins 1 Go de mémoire allouable"* ]] || false
    [ ! -f "$BATS_TEST_TMPDIR/ns" ]
    [ ! -f "$BATS_TEST_TMPDIR/helm.log" ]
}

@test "etat après installation : prêt, relais arrêté signalé" {
    argocd_installe
    run bash "$ARGOCD" etat
    [ "$status" -eq 0 ]
    [[ "$output" == *"relais arrêté"* ]] || false
}

@test "activer argocd déjà installé : relais relancé, pas de nouvelle installation" {
    argocd_installe
    rm -f "$BATS_TEST_TMPDIR/helm.log"
    run bash "$DEVZONE" activer argocd </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"relais relancé"* ]] || false
    [ ! -f "$BATS_TEST_TMPDIR/helm.log" ]
    attendre_nohup '8443:443'
}

@test "argocd app add : Application of the project applied with the devzone context (#516)" {
    argocd_installe
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

@test "argocd app add : GitLab de devzone, URL interne et jeton root du module dans un Secret de dépôt" {
    argocd_installe
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

@test "argocd app : module inactif refusé, et renvoi au poste dans le pod du workspace" {
    run bash "$DEVZONE" argocd app list
    [ "$status" -eq 2 ]
    [[ "$output" == *"module off: devzone enable argocd"* ]] || false
    argocd_installe
    run env DEVZONE_WORKSPACE=kubernetes bash "$DEVZONE" argocd app list
    [ "$status" -eq 2 ]
    [[ "$output" == *"devzone workspace argocd app list"* ]] || false
}

@test "desactiver argocd : helm uninstall, namespace supprimé, services conservés" {
    argocd_installe
    run bash "$DEVZONE" desactiver argocd
    [ "$status" -eq 0 ]
    grep -qx 'argocd=off' "$DEVZONE_ETAT"
    grep -Eq 'helm --kubeconfig [^ ]+ --kube-context docker-desktop uninstall argocd -n devzone-argocd' "$BATS_TEST_TMPDIR/helm.log"
    # Namespace supprimé par l'administrateur, pas par le compte limité (#430)
    grep -q -- '--context docker-desktop delete namespace devzone-argocd' "$BATS_TEST_TMPDIR/kubectl.log"
    [ ! -e "$SECRETS" ]
    [[ "$output" == *"les services restent, sous helm direct"* ]] || false
}
