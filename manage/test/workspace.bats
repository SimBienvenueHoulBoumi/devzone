#!/usr/bin/env bats
# Commandes du poste pour le workspace Kubernetes (#398). Faux helm et kubectl
# dans $BATS_TEST_TMPDIR/bin : aucun cluster n'est touche.

setup() {
    load commun
    relais_docker_isole
    kube_isole
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CLI="$RACINE/manage/devzone"
    T="$BATS_TEST_TMPDIR"
    mkdir -p "$T/bin"
    cat >"$T/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
echo "kubectl $*" >>"$T/kubectl.log"
case "$*" in
    "config get-contexts -o name")
        for c in ${FAUX_CONTEXTES:-docker-desktop}; do
            [ -n "$c" ] && echo "$c"
        done
        ;;
    "config current-context")
        echo "${FAUX_CONTEXTE_COURANT:-docker-desktop}"
        ;;
esac
exit 0
KUBE
    cat >"$T/bin/helm" <<'HELM'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
echo "helm $*" >>"$T/helm.log"
exit 0
HELM
    chmod +x "$T/bin/kubectl" "$T/bin/helm"
    export PATH="$T/bin:$PATH"
}

@test "workspace demarrer : helm upgrade --install avec contexte devzone s'il existe" {
    export FAUX_CONTEXTES="devzone docker-desktop"
    : >"$T/helm.log"
    run bash "$CLI" workspace demarrer
    [ "$status" -eq 0 ]
    grep -q -- "--kube-context devzone" "$T/helm.log" || false
    grep -q -- "upgrade --install devzone-workspace" "$T/helm.log" || false
    grep -q "charts/devzone-workspace" "$T/helm.log" || false
    grep -q -- "--namespace devzone-workspace" "$T/helm.log" || false
}

@test "workspace demarrer : contexte courant si devzone absent" {
    export FAUX_CONTEXTES="docker-desktop"
    export FAUX_CONTEXTE_COURANT="docker-desktop"
    : >"$T/helm.log"
    run bash "$CLI" workspace demarrer
    [ "$status" -eq 0 ]
    ! grep -q -- "--kube-context" "$T/helm.log" || false
    grep -q -- "upgrade --install devzone-workspace" "$T/helm.log" || false
}

@test "workspace arreter : helm uninstall" {
    export FAUX_CONTEXTES="devzone docker-desktop"
    : >"$T/helm.log"
    run bash "$CLI" workspace arreter
    [ "$status" -eq 0 ]
    grep -q -- "--kube-context devzone" "$T/helm.log" || false
    grep -q -- "uninstall devzone-workspace" "$T/helm.log" || false
}

@test "workspace etat : kubectl get pods" {
    export FAUX_CONTEXTES="docker-desktop"
    export FAUX_CONTEXTE_COURANT="docker-desktop"
    : >"$T/kubectl.log"
    run bash "$CLI" workspace etat
    [ "$status" -eq 0 ]
    grep -q -- "get pods" "$T/kubectl.log" || false
    grep -q -- "--namespace devzone-workspace" "$T/kubectl.log" || false
}

@test "workspace shell : kubectl exec dans le conteneur workspace" {
    export FAUX_CONTEXTES="devzone docker-desktop"
    : >"$T/kubectl.log"
    run bash "$CLI" workspace shell
    [ "$status" -eq 0 ]
    grep -q -- "exec -it devzone-workspace-0" "$T/kubectl.log" || false
    grep -q -- "-c workspace" "$T/kubectl.log" || false
}

@test "chart : helm lint et helm template" {
    command -v helm >/dev/null 2>&1 || skip "helm absent"
    run helm lint "$RACINE/charts/devzone-workspace"
    [ "$status" -eq 0 ]
    run helm template devzone-workspace "$RACINE/charts/devzone-workspace" --namespace devzone-workspace
    [ "$status" -eq 0 ]
}
