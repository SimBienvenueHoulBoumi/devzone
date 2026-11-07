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

@test "workspace copier-vers : kubectl cp du poste vers /workspaces/projets du pod" {
    export FAUX_CONTEXTES="devzone docker-desktop"
    mkdir -p "$T/mon-projet"
    : >"$T/kubectl.log"
    run bash "$CLI" workspace copier-vers "$T/mon-projet"
    [ "$status" -eq 0 ]
    grep -q -- "cp $T/mon-projet devzone-workspace-0:/workspaces/projets/mon-projet" "$T/kubectl.log" || false
    grep -q -- "--context devzone" "$T/kubectl.log" || false
    grep -q -- "--namespace devzone-workspace" "$T/kubectl.log" || false
    grep -q -- "-c workspace" "$T/kubectl.log" || false
}

@test "workspace copier-vers : sans dossier, usage et aucun kubectl" {
    export FAUX_CONTEXTES="devzone docker-desktop"
    : >"$T/kubectl.log"
    run bash "$CLI" workspace copier-vers
    [ "$status" -eq 1 ]
    [[ "$output" == *"devzone workspace copier-vers <dossier>"* ]] || false
    [ ! -s "$T/kubectl.log" ]
}

@test "workspace copier-vers : dossier introuvable, aucun kubectl" {
    export FAUX_CONTEXTES="devzone docker-desktop"
    : >"$T/kubectl.log"
    run bash "$CLI" workspace copier-vers "$T/absent"
    [ "$status" -eq 1 ]
    [[ "$output" == *"dossier introuvable"* ]] || false
    [ ! -s "$T/kubectl.log" ]
}

@test "workspace copier-depuis : kubectl cp de /workspaces/projets vers le poste" {
    export FAUX_CONTEXTES="devzone docker-desktop"
    : >"$T/kubectl.log"
    run bash "$CLI" workspace copier-depuis "$T/recup/mon-projet"
    [ "$status" -eq 0 ]
    grep -q -- "cp devzone-workspace-0:/workspaces/projets/mon-projet $T/recup/mon-projet" "$T/kubectl.log" || false
    grep -q -- "--context devzone" "$T/kubectl.log" || false
    grep -q -- "--namespace devzone-workspace" "$T/kubectl.log" || false
    grep -q -- "-c workspace" "$T/kubectl.log" || false
}

@test "workspace copier-depuis . : le projet porte le nom du dossier courant" {
    export FAUX_CONTEXTES="devzone docker-desktop"
    mkdir -p "$T/cwd-projet"
    cd "$T/cwd-projet"
    : >"$T/kubectl.log"
    run bash "$CLI" workspace copier-depuis .
    [ "$status" -eq 0 ]
    grep -q -- "cp devzone-workspace-0:/workspaces/projets/cwd-projet $T/cwd-projet" "$T/kubectl.log" || false
    ! grep -q -- "projets/\.$" "$T/kubectl.log" || false
}

@test "workspace copier-depuis : sans dossier, usage et aucun kubectl" {
    export FAUX_CONTEXTES="devzone docker-desktop"
    : >"$T/kubectl.log"
    run bash "$CLI" workspace copier-depuis
    [ "$status" -eq 1 ]
    [[ "$output" == *"devzone workspace copier-depuis <dossier>"* ]] || false
    [ ! -s "$T/kubectl.log" ]
}

@test "workspace vscode : marche à suivre (contexte, namespace, pod, dossier)" {
    run bash "$CLI" workspace vscode
    [ "$status" -eq 0 ]
    [[ "$output" == *"Contexte kubectl : devzone"* ]] || false
    [[ "$output" == *"pod devzone-workspace-0"* ]] || false
    [[ "$output" == *"Attach to Running Kubernetes Container"* ]] || false
    [[ "$output" == *"/workspaces/projets"* ]] || false
    [[ "$output" == *"devzone workspace etat"* ]] || false
    # Aucune variable devzone proposée à l'utilisateur (#341)
    ! grep -q "DEVZONE_" <<<"$output" || false
}

@test "workspace aide : toutes les sous-commandes listées" {
    run bash "$CLI" workspace
    [ "$status" -eq 0 ]
    [[ "$output" == *"demarrer|arreter|etat|shell|vscode|copier-vers|copier-depuis"* ]] || false
}

@test "chart : helm lint et helm template" {
    command -v helm >/dev/null 2>&1 || skip "helm absent"
    run helm lint "$RACINE/charts/devzone-workspace"
    [ "$status" -eq 0 ]
    run helm template devzone-workspace "$RACINE/charts/devzone-workspace" --namespace devzone-workspace
    [ "$status" -eq 0 ]
}
