#!/usr/bin/env bats
# GitLab dans le cluster des services (#396 étape B) : Helm avec le contexte
# devzone et le namespace devzone-gitlab, valeurs ClusterIP, aucune création
# kind, refus sous 8 Go de mémoire allouable, relais port-forward et migration
# depuis l'ancien cluster kind-gitlab. Faux kubectl, helm, kind, curl, git et
# setsid dans $BATS_TEST_TMPDIR/bin : aucun cluster n'est touché.

setup() {
    load commun
    kind_vide
    relais_docker_isole
    kube_isole
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    GITLAB="$BATS_TEST_DIRNAME/../../.devcontainer/gitlab/gitlab.sh"
    export DEVZONE_RACINE="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_ETAT="$BATS_TEST_TMPDIR/modules"
    export DEVZONE_HOSTS="$BATS_TEST_TMPDIR/hosts"
    export KIND_CLUSTERS="$BATS_TEST_TMPDIR/clusters"
    SECRETS="$DEVZONE_RACINE/workspace/.gitlab"
    mkdir -p "$HOME" "$DEVZONE_RACINE/workspace" "$BATS_TEST_TMPDIR/bin"
    : >"$DEVZONE_ETAT"
    : >"$KIND_CLUSTERS"
    printf '127.0.0.1 localhost\n' >"$DEVZONE_HOSTS"

    # kubectl : mémoire des nœuds (FAUX_MEMOIRE_CLUSTER), namespace présent
    # dès qu'une création ou un apply a eu lieu, secrets et API du seed.
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"$BATS_TEST_TMPDIR/kubectl.log"
T="$BATS_TEST_TMPDIR"
case "$*" in
    *"get nodes -o jsonpath"*)
        printf '%s\n' "${FAUX_MEMOIRE_CLUSTER:-16777216Ki}" ;;
    *"create namespace"*)
        printf 'kind: Namespace\nmetadata:\n  name: devzone-gitlab\n' ;;
    *"apply -f -"*)
        tee -a "$T/apply.log" ;;
    *"get namespace "*)
        [ -f "$T/namespace" ] && exit 0
        exit 1 ;;
    *"label namespace "*)
        touch "$T/namespace" ;;
    *"get secret"*)
        echo "cGFzc3dvcmQxMjM=" ;;
    *"get pod"*)
        echo "gitlab-toolbox-1" ;;
    *"gitlab-rails runner"*)
        echo "jeton-root-secret" ;;
    *"config delete-"*)
        ;;
esac
exit 0
KUBE

    # helm : journalise chaque appel et le contenu des fichiers de valeurs
    cat >"$BATS_TEST_TMPDIR/bin/helm" <<'HELM'
#!/usr/bin/env bash
echo "helm $*" >>"$BATS_TEST_TMPDIR/helm.log"
precedent=""
for a in "$@"; do
    if [ "$precedent" = -f ] && [ -f "$a" ]; then
        cat "$a" >>"$BATS_TEST_TMPDIR/helm.log"
    fi
    precedent="$a"
done
exit 0
HELM

    # kind : clusters dans $KIND_CLUSTERS ; create est journalisé (il ne doit
    # plus être appelé pour GitLab), delete retire le nom
    cat >"$BATS_TEST_TMPDIR/bin/kind" <<'KIND'
#!/usr/bin/env bash
echo "kind $*" >>"$BATS_TEST_TMPDIR/kind.log"
sous="$1 $2"
nom=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --name) nom="$2"; shift ;;
    esac
    shift
done
case "$sous" in
    "get clusters") cat "$KIND_CLUSTERS" ;;
    "delete cluster")
        grep -vx "$nom" "$KIND_CLUSTERS" >"$KIND_CLUSTERS.tmp" || true
        mv "$KIND_CLUSTERS.tmp" "$KIND_CLUSTERS"
        ;;
esac
exit 0
KIND

    # curl : GitLab prêt et API du seed simulée ; la branche main n'existe
    # qu'après le push du faux git (fichier pousse)
    cat >"$BATS_TEST_TMPDIR/bin/curl" <<'CURL'
#!/usr/bin/env bash
case "$*" in
    *"api/v4/runners/verify"*) echo 200 ;;
    *"api/v4/groups/devzone"*) echo '{"id":42}' ;;
    *"--request POST"*"api/v4/user/runners"*) echo '{"token":"jeton-runner"}' ;;
    *"api/v4/projects/devzone%2Fdemo/repository"*) [ -f "$BATS_TEST_TMPDIR/pousse" ] || exit 22 ;;
    *"--request POST"*) ;;
    *"api/v4/projects/devzone%2Fdemo"*) exit 22 ;;
    *"api/v4/users?username=dev"*) echo '[]' ;;
    *"api/v4/runners/all"*) echo '[]' ;;
esac
exit 0
CURL

    # git : le push du seed marque la branche main comme poussée
    cat >"$BATS_TEST_TMPDIR/bin/git" <<'GIT'
#!/usr/bin/env bash
echo "git $*" >>"$BATS_TEST_TMPDIR/git.log"
case "$*" in *" push "*) touch "$BATS_TEST_TMPDIR/pousse" ;; esac
exit 0
GIT

    # setsid : journalise le relais sans lancer de vrai port-forward
    cat >"$BATS_TEST_TMPDIR/bin/setsid" <<'SETSID'
#!/usr/bin/env bash
echo "setsid $*" >>"$BATS_TEST_TMPDIR/setsid.log"
exit 0
SETSID

    # openssl : mot de passe de test, jamais utilisé pour un vrai secret
    printf '#!/usr/bin/env bash\necho motdepasse-test\n' >"$BATS_TEST_TMPDIR/bin/openssl"
    chmod +x "$BATS_TEST_TMPDIR"/bin/*
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "gitlab : helm dans le contexte devzone et le namespace devzone-gitlab, aucun kind créé" {
    run bash "$GITLAB" installer
    [ "$status" -eq 0 ] || false
    grep -Eq -- "--kubeconfig [^ ]+ upgrade --install gitlab gitlab/gitlab --version 9.11.16 --namespace devzone-gitlab" "$BATS_TEST_TMPDIR/helm.log" || false
    grep -Eq -- "--kubeconfig [^ ]+ upgrade --install gitlab-runner gitlab/gitlab-runner --version 0.88.2 --namespace devzone-gitlab" "$BATS_TEST_TMPDIR/helm.log" || false
    ! grep -q "create cluster" "$BATS_TEST_TMPDIR/kind.log" || false
}

@test "gitlab : namespace devzone-gitlab étiqueté et isolé par NetworkPolicy" {
    run bash "$GITLAB" installer
    [ "$status" -eq 0 ] || false
    grep -q "label namespace devzone-gitlab app.kubernetes.io/managed-by=devzone" "$BATS_TEST_TMPDIR/kubectl.log" || false
    grep -q "devzone-meme-namespace" "$BATS_TEST_TMPDIR/apply.log" || false
    grep -q "kind: NetworkPolicy" "$BATS_TEST_TMPDIR/apply.log" || false
}

@test "gitlab : valeurs ClusterIP sans NodePort, LoadBalancer ni Ingress ouvert" {
    local values="$BATS_TEST_DIRNAME/../../.devcontainer/gitlab/values.yaml"
    grep -q "type: ClusterIP" "$values" || false
    grep -q "nginx-ingress:" "$values" || false
    grep -A1 "nginx-ingress:" "$values" | grep -q "enabled: false" || false
    ! grep -q "NodePort" "$values" || false
    ! grep -q "LoadBalancer" "$values" || false
    ! grep -q "hostPort" "$values" || false
    [ ! -e "$BATS_TEST_DIRNAME/../../.devcontainer/gitlab/kind.yaml" ] || false
}

@test "gitlab : runner pointe vers le namespace de l'instance" {
    run bash "$GITLAB" installer
    [ "$status" -eq 0 ] || false
    grep -q "gitlab-webservice-default.devzone-gitlab.svc:8181" "$BATS_TEST_TMPDIR/helm.log" || false
    ! grep -q "__NAMESPACE__" "$BATS_TEST_TMPDIR/helm.log" || false
}

@test "gitlab : moins de 8 Go de mémoire allouable dans le cluster → refus, rien lancé" {
    FAUX_MEMOIRE_CLUSTER='4000000Ki' run bash "$GITLAB" installer
    [ "$status" -eq 2 ] || false
    [[ "$output" == *"8 Go"* ]] || false
    [ ! -e "$BATS_TEST_TMPDIR/helm.log" ] || false
}

@test "gitlab : relais web et SSH en port-forward vers les services du namespace" {
    run bash "$GITLAB" relais-lancer
    [ "$status" -eq 0 ] || false
    grep -q "devzone devzone-gitlab svc/gitlab-webservice-default 8929:8181" "$BATS_TEST_TMPDIR/setsid.log" || false
    grep -q "devzone devzone-gitlab svc/gitlab-gitlab-shell 2224:22" "$BATS_TEST_TMPDIR/setsid.log" || false
    ! grep -q "socat" "$BATS_TEST_TMPDIR/setsid.log" || false
    ! grep -q "network connect" "$BATS_TEST_TMPDIR/setsid.log" || false
}

@test "gitlab : instance suffixée → namespace devzone-gitlab-<instance>" {
    DEVZONE_INSTANCE=autre run bash "$GITLAB" installer
    [ "$status" -eq 0 ] || false
    grep -q -- "--namespace devzone-gitlab-autre" "$BATS_TEST_TMPDIR/helm.log" || false
    grep -q "label namespace devzone-gitlab-autre" "$BATS_TEST_TMPDIR/kubectl.log" || false
}

@test "gitlab migrer : sans confirmation, ancien cluster kind-gitlab gardé" {
    printf 'gitlab\n' >"$KIND_CLUSTERS"
    run bash "$DEVZONE" gitlab migrer </dev/null
    [ "$status" -eq 2 ] || false
    grep -qx "gitlab" "$KIND_CLUSTERS" || false
    ! grep -q "delete cluster" "$BATS_TEST_TMPDIR/kind.log" || false
    # L'installation dans le cluster des services a bien eu lieu avant la question
    grep -Eq -- "--kubeconfig [^ ]+ upgrade --install gitlab gitlab/gitlab" "$BATS_TEST_TMPDIR/helm.log" || false
}

@test "gitlab migrer --oui : installe, refait le seed, puis supprime kind-gitlab" {
    printf 'gitlab\n' >"$KIND_CLUSTERS"
    run bash "$DEVZONE" gitlab migrer --oui
    [ "$status" -eq 0 ] || false
    grep -Eq -- "--kubeconfig [^ ]+ upgrade --install gitlab gitlab/gitlab" "$BATS_TEST_TMPDIR/helm.log" || false
    grep -q "api/v4/projects" "$BATS_TEST_TMPDIR/curl.log" 2>/dev/null ||
        grep -q "gitlab-rails runner" "$BATS_TEST_TMPDIR/kubectl.log" || false
    grep -q "kind delete cluster --name gitlab" "$BATS_TEST_TMPDIR/kind.log" || false
    [ ! -s "$KIND_CLUSTERS" ] || false
}

@test "devzone : récapitulatif signale l'ancien cluster kind-gitlab" {
    printf 'gitlab\n' >"$KIND_CLUSTERS"
    run bash "$DEVZONE"
    [ "$status" -eq 0 ] || false
    [[ "$output" == *"⚠ ancien cluster kind-gitlab : devzone gitlab migrer"* ]] || false
}

@test "devzone : récapitulatif sans avertissement quand kind-gitlab a disparu" {
    run bash "$DEVZONE"
    [ "$status" -eq 0 ] || false
    [[ "$output" != *"ancien cluster kind-gitlab"* ]] || false
}
