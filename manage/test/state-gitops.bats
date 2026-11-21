#!/usr/bin/env bats
# GitOps repository line of the state in the Kubernetes workspace pod (#639):
# one short kubectl read of the root Application, the workstation fallback
# when it is refused or absent, and the unchanged message outside the pod.
# No cluster, no network: a fake kubectl under $BATS_TEST_TMPDIR/bin.

setup() {
    load commun
    kube_isole
    unset DEVZONE_WORKSPACE
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    export DEVZONE_ROOT="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_STATE="$BATS_TEST_TMPDIR/racine/.devzone.modules"
    export DEVZONE_INSTANCE=devzone
    export DEVZONE_PORTS_AUTO_DIR="$BATS_TEST_TMPDIR/ports-auto"
    export GIT_CONFIG_NOSYSTEM=1
    mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/relais" "$DEVZONE_ROOT/workspace"
    cd "$BATS_TEST_TMPDIR" || return 1

    # fake kubectl: the root Application answer follows FAUX_APP (#639)
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"$BATS_TEST_TMPDIR/kubectl.log"
case "$*" in
    "config get-contexts -o name") printf 'devzone\ndocker-desktop\n' ;;
    get\ namespaces*)
        for n in ${FAUX_NS:-}; do printf 'namespace/%s\n' "$n"; done
        ;;
    *"config view"*) echo docker-desktop ;;
    get\ application\ devzone*)
        case "${FAUX_APP:-absent}" in
            present)
                printf '%s\n' "${FAUX_URL:-https://github.com/tester/devzone-argocd.git}"
                ;;
            absent)
                echo 'Error from server (NotFound): applications.argoproj.io "devzone" not found' >&2
                exit 1
                ;;
            forbidden)
                echo 'Error from server (Forbidden): applications.argoproj.io "devzone" is forbidden: User "system:serviceaccount:devzone-workspace:workspace" cannot get resource "applications" in API group "argoproj.io" in the namespace "devzone-argocd"' >&2
                exit 1
                ;;
        esac
        ;;
    *) exit 1 ;;
esac
exit 0
KUBE
    # fake docker: relays noted in a file, no container
    cat >"$BATS_TEST_TMPDIR/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
echo "docker $*" >>"$BATS_TEST_TMPDIR/docker.log"
case "${1:-}" in
    inspect) echo "devzone_default 172.18.0.5" ;;
    run)
        nom=""; prec=""
        for a in "$@"; do
            [ "$prec" = --name ] && nom="$a"
            prec="$a"
        done
        mkdir -p "$BATS_TEST_TMPDIR/relais"; : >"$BATS_TEST_TMPDIR/relais/$nom"; echo "id-$nom"
        ;;
    rm) rm -f "$BATS_TEST_TMPDIR/relais/${3:-${2:-}}" ;;
    ps) ;;
esac
exit 0
DOCKER
    # fake ss and socat: the watcher sees a port, nothing is started
    cat >"$BATS_TEST_TMPDIR/bin/ss" <<'SS'
#!/usr/bin/env bash
cat "$BATS_TEST_TMPDIR/ss.listen" 2>/dev/null
exit 0
SS
    cat >"$BATS_TEST_TMPDIR/bin/socat" <<'SOCAT'
#!/usr/bin/env bash
echo "socat $*" >>"$BATS_TEST_TMPDIR/socat.log"
exit 0
SOCAT
    # fake npm: versions.sh --installees answers with no tool installed
    cat >"$BATS_TEST_TMPDIR/bin/npm" <<'NPM'
#!/usr/bin/env bash
echo "npm $*" >>"$BATS_TEST_TMPDIR/npm.log"
case "${1:-}" in ls) printf '{"dependencies":{}}\n' ;; esac
exit 0
NPM
    chmod +x "$BATS_TEST_TMPDIR/bin/"*
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    : >"$BATS_TEST_TMPDIR/kubectl.log"
    : >"$BATS_TEST_TMPDIR/docker.log"
    : >"$BATS_TEST_TMPDIR/ss.listen"
}

@test "etat-gitops : in the pod, the root Application gives its repository URL" {
    export DEVZONE_WORKSPACE=kubernetes
    FAUX_APP=present run bash "$DEVZONE" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"  ○ argocd          GitOps repository: https://github.com/tester/devzone-argocd.git"* ]] || false
    [[ "$output" != *"no GitOps repository"* ]] || false
    run grep -c 'get application devzone' "$BATS_TEST_TMPDIR/kubectl.log"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]
}

@test "etat-gitops : in the pod, an absent Application falls back to the workstation" {
    export DEVZONE_WORKSPACE=kubernetes
    FAUX_APP=absent run bash "$DEVZONE" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"  ○ argocd          managed from the workstation: devzone workspace argocd status"* ]] || false
    [[ "$output" != *"no GitOps repository"* ]] || false
}

@test "etat-gitops : in the pod, a forbidden read falls back to the workstation" {
    export DEVZONE_WORKSPACE=kubernetes
    FAUX_APP=forbidden run bash "$DEVZONE" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"  ○ argocd          managed from the workstation: devzone workspace argocd status"* ]] || false
    [[ "$output" != *"no GitOps repository"* ]] || false
}

@test "etat-gitops : outside the pod, the init notice stays and kubectl is not read" {
    run bash "$DEVZONE" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"  ○ argocd          no GitOps repository: devzone argocd init"* ]] || false
    run grep -c 'get application devzone' "$BATS_TEST_TMPDIR/kubectl.log"
    [ "$status" -ne 0 ]
}
