#!/usr/bin/env bats
# GitLab in the services cluster (#396 step B): Helm with the context
# devzone and the devzone-gitlab namespace, ClusterIP values, no creation
# kind, refusal under 8 GB of allocatable memory, port-forward relay and migration
# from the old kind-gitlab cluster. Fake kubectl, helm, kind, curl, git and
# setsid in $BATS_TEST_TMPDIR/bin: no cluster is touched.

setup() {
    load commun
    kind_vide
    relais_docker_isole
    kube_isole
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    GITLAB="$BATS_TEST_DIRNAME/../../.devcontainer/gitlab/gitlab.sh"
    export DEVZONE_ROOT="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_STATE="$BATS_TEST_TMPDIR/modules"
    export DEVZONE_HOSTS="$BATS_TEST_TMPDIR/hosts"
    export KIND_CLUSTERS="$BATS_TEST_TMPDIR/clusters"
    SECRETS="$DEVZONE_ROOT/workspace/.gitlab"
    mkdir -p "$HOME" "$DEVZONE_ROOT/workspace" "$BATS_TEST_TMPDIR/bin"
    : >"$DEVZONE_STATE"
    : >"$KIND_CLUSTERS"
    printf '127.0.0.1 localhost\n' >"$DEVZONE_HOSTS"

    # kubectl: node memory (FAKE_MEMORY_CLUSTER), namespace present
    # as soon as a creation or an apply took place, secrets and seed API.
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"$BATS_TEST_TMPDIR/kubectl.log"
T="$BATS_TEST_TMPDIR"
case "$*" in
    *"get nodes -o jsonpath"*)
        printf '%s\n' "${FAKE_MEMORY_CLUSTER:-16777216Ki}" ;;
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

    # helm: logs each call and the content of the values files
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

    # kind: clusters in $KIND_CLUSTERS; create is logged (it must no longer
    # be called for GitLab), delete removes the name
    cat >"$BATS_TEST_TMPDIR/bin/kind" <<'KIND'
#!/usr/bin/env bash
echo "kind $*" >>"$BATS_TEST_TMPDIR/kind.log"
sous="$1 $2"
name=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --name) name="$2"; shift ;;
    esac
    shift
done
case "$sous" in
    "get clusters") cat "$KIND_CLUSTERS" ;;
    "delete cluster")
        grep -vx "$name" "$KIND_CLUSTERS" >"$KIND_CLUSTERS.tmp" || true
        mv "$KIND_CLUSTERS.tmp" "$KIND_CLUSTERS"
        ;;
esac
exit 0
KIND

    # curl: GitLab ready and seed API simulated; the main branch exists
    # only after the push of the fake git (file pushed)
    cat >"$BATS_TEST_TMPDIR/bin/curl" <<'CURL'
#!/usr/bin/env bash
case "$*" in
    *"api/v4/runners/verify"*) echo 200 ;;
    *"api/v4/groups/devzone"*) echo '{"id":42}' ;;
    *"--request POST"*"api/v4/user/runners"*) echo '{"token":"jeton-runner"}' ;;
    *"api/v4/projects/devzone%2Fdemo/repository"*) [ -f "$BATS_TEST_TMPDIR/pushed" ] || exit 22 ;;
    *"--request POST"*) ;;
    *"api/v4/projects/devzone%2Fdemo"*) exit 22 ;;
    *"api/v4/users?username=dev"*) echo '[]' ;;
    *"api/v4/runners/all"*) echo '[]' ;;
esac
exit 0
CURL

    # git: the seed push marks the main branch as pushed
    cat >"$BATS_TEST_TMPDIR/bin/git" <<'GIT'
#!/usr/bin/env bash
echo "git $*" >>"$BATS_TEST_TMPDIR/git.log"
case "$*" in *" push "*) touch "$BATS_TEST_TMPDIR/pushed" ;; esac
exit 0
GIT

    # setsid: logs the relay without starting a real port-forward
    cat >"$BATS_TEST_TMPDIR/bin/setsid" <<'SETSID'
#!/usr/bin/env bash
echo "setsid $*" >>"$BATS_TEST_TMPDIR/setsid.log"
exit 0
SETSID

    # openssl: test password, never used for a real secret
    printf '#!/usr/bin/env bash\necho password-test\n' >"$BATS_TEST_TMPDIR/bin/openssl"
    chmod +x "$BATS_TEST_TMPDIR"/bin/*
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "gitlab : helm in the devzone context and the devzone-gitlab namespace, no kind created" {
    run bash "$GITLAB" install
    [ "$status" -eq 0 ] || false
    # Wrapper chart charts/devzone-gitlab (#538): dependencies built, then one
    # pass with the runner held back and a second once the seed wrote its Secret
    grep -q "dependency build" "$BATS_TEST_TMPDIR/helm.log" || false
    grep -Eq -- "--kubeconfig [^ ]+ upgrade --install gitlab [^ ]*charts/devzone-gitlab --namespace devzone-gitlab" "$BATS_TEST_TMPDIR/helm.log" || false
    grep -Eq -- "--kubeconfig [^ ]+ upgrade --install gitlab [^ ]*charts/devzone-gitlab .*--set gitlab-runner.replicas=1" "$BATS_TEST_TMPDIR/helm.log" || false
    ! grep -q "create cluster" "$BATS_TEST_TMPDIR/kind.log" || false
}

@test "gitlab : devzone-gitlab namespace labelled and isolated by NetworkPolicy" {
    run bash "$GITLAB" install
    [ "$status" -eq 0 ] || false
    grep -q "label namespace devzone-gitlab app.kubernetes.io/managed-by=devzone" "$BATS_TEST_TMPDIR/kubectl.log" || false
    grep -q "devzone-meme-namespace" "$BATS_TEST_TMPDIR/apply.log" || false
    grep -q "kind: NetworkPolicy" "$BATS_TEST_TMPDIR/apply.log" || false
}

@test "gitlab : ClusterIP values without NodePort, LoadBalancer nor open Ingress" {
    local values="$BATS_TEST_DIRNAME/../../charts/devzone-gitlab/values.yaml"
    grep -q "type: ClusterIP" "$values" || false
    grep -q "nginx-ingress:" "$values" || false
    grep -A1 "nginx-ingress:" "$values" | grep -q "enabled: false" || false
    ! grep -q "NodePort" "$values" || false
    ! grep -q "LoadBalancer" "$values" || false
    ! grep -q "hostPort" "$values" || false
    [ ! -e "$BATS_TEST_DIRNAME/../../.devcontainer/gitlab/kind.yaml" ] || false
}

@test "gitlab : runner points to the instance namespace" {
    run bash "$GITLAB" install
    [ "$status" -eq 0 ] || false
    grep -q "gitlab-webservice-default.devzone-gitlab.svc:8181" "$BATS_TEST_TMPDIR/helm.log" || false
    ! grep -q "__NAMESPACE__" "$BATS_TEST_TMPDIR/helm.log" || false
}

@test "gitlab : less than 8 GB of allocatable memory in the cluster → refusal, nothing started" {
    FAKE_MEMORY_CLUSTER='4000000Ki' run bash "$GITLAB" install
    [ "$status" -eq 2 ] || false
    [[ "$output" == *"8 GiB"* ]] || false
    [ ! -e "$BATS_TEST_TMPDIR/helm.log" ] || false
}

@test "gitlab : web and SSH relay by port-forward to the namespace services" {
    run bash "$GITLAB" relay-start
    [ "$status" -eq 0 ] || false
    grep -q "devzone devzone-gitlab svc/gitlab-webservice-default 8929:8181" "$BATS_TEST_TMPDIR/setsid.log" || false
    grep -q "devzone devzone-gitlab svc/gitlab-gitlab-shell 2224:22" "$BATS_TEST_TMPDIR/setsid.log" || false
    ! grep -q "socat" "$BATS_TEST_TMPDIR/setsid.log" || false
    ! grep -q "network connect" "$BATS_TEST_TMPDIR/setsid.log" || false
}

@test "gitlab : suffixed instance → namespace devzone-gitlab-<instance>" {
    DEVZONE_INSTANCE=other run bash "$GITLAB" install
    [ "$status" -eq 0 ] || false
    grep -q -- "--namespace devzone-gitlab-other" "$BATS_TEST_TMPDIR/helm.log" || false
    grep -q "label namespace devzone-gitlab-other" "$BATS_TEST_TMPDIR/kubectl.log" || false
}

@test "gitlab migrate : without confirmation, old kind-gitlab cluster kept" {
    printf 'gitlab\n' >"$KIND_CLUSTERS"
    run bash "$DEVZONE" gitlab migrate </dev/null
    [ "$status" -eq 2 ] || false
    grep -qx "gitlab" "$KIND_CLUSTERS" || false
    ! grep -q "delete cluster" "$BATS_TEST_TMPDIR/kind.log" || false
    # The installation in the services cluster took place before the question
    grep -Eq -- "--kubeconfig [^ ]+ upgrade --install gitlab [^ ]*charts/devzone-gitlab" "$BATS_TEST_TMPDIR/helm.log" || false
}

@test "gitlab migrate --yes : installs, redoes the seed, then deletes kind-gitlab" {
    printf 'gitlab\n' >"$KIND_CLUSTERS"
    run bash "$DEVZONE" gitlab migrate --yes
    [ "$status" -eq 0 ] || false
    grep -Eq -- "--kubeconfig [^ ]+ upgrade --install gitlab [^ ]*charts/devzone-gitlab" "$BATS_TEST_TMPDIR/helm.log" || false
    grep -q "api/v4/projects" "$BATS_TEST_TMPDIR/curl.log" 2>/dev/null ||
        grep -q "gitlab-rails runner" "$BATS_TEST_TMPDIR/kubectl.log" || false
    grep -q "kind delete cluster --name gitlab" "$BATS_TEST_TMPDIR/kind.log" || false
    [ ! -s "$KIND_CLUSTERS" ] || false
}

@test "devzone : summary reports the old kind-gitlab cluster" {
    printf 'gitlab\n' >"$KIND_CLUSTERS"
    run bash "$DEVZONE"
    [ "$status" -eq 0 ] || false
    [[ "$output" == *"⚠ old kind-gitlab cluster: devzone gitlab migrate"* ]] || false
}

@test "devzone : summary without warning when kind-gitlab is gone" {
    run bash "$DEVZONE"
    [ "$status" -eq 0 ] || false
    [[ "$output" != *"old kind-gitlab cluster"* ]] || false
}
