#!/usr/bin/env bats
# Projets du workspace dans un volume (#399) : montage sur /workspaces/projets,
# workingDir, annotation helm.sh/resource-policy: keep et taille (workspace.taille).
# helm est le vrai helm (lint et template exigés par la conception, comme dans
# workspace-sans-docker.bats) ; kubectl est un faux outil dans
# $BATS_TEST_TMPDIR/bin : aucun cluster n'est touché.

setup() {
    load commun
    relais_docker_isole
    kube_isole
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CHART="$RACINE/charts/devzone-workspace"
    T="$BATS_TEST_TMPDIR"
    mkdir -p "$T/bin"
    cat >"$T/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"$BATS_TEST_TMPDIR/kubectl.log"
exit 0
KUBE
    chmod +x "$T/bin/kubectl"
    export PATH="$T/bin:$PATH"
    command -v helm >/dev/null 2>&1 || skip "helm absent"
}

# Rendu complet du chart, avec les options passees en arguments.
rendu() {
    helm template t "$CHART" --namespace devzone-workspace "$@"
}

# Bloc volumeClaimTemplates (du mot-cle jusqu'a la fin du rendu).
bloc_pvc() {
    awk '/^  volumeClaimTemplates:/{p=1} p' <<<"$1"
}

@test "projets : helm lint du chart" {
    run helm lint "$CHART"
    [ "$status" -eq 0 ]
}

@test "projets : le PVC workspace est monte sur /workspaces/projets" {
    run rendu
    [ "$status" -eq 0 ]
    grep -q -- "mountPath: /workspaces/projets" <<<"$output" || false
    # L'ancien montage /workspace n'existe plus
    ! grep -q -- "mountPath: /workspace$" <<<"$output" || false
}

@test "projets : le conteneur demarre dans /workspaces/projets (workingDir)" {
    run rendu --show-only templates/statefulset.yaml
    [ "$status" -eq 0 ]
    grep -q -- "workingDir: /workspaces/projets" <<<"$output" || false
}

@test "projets : le PVC workspace porte l'annotation helm.sh/resource-policy: keep" {
    run rendu --show-only templates/statefulset.yaml
    [ "$status" -eq 0 ]
    local pvc
    pvc="$(bloc_pvc "$output")"
    grep -q -- "name: workspace" <<<"$pvc" || false
    grep -q -- "helm.sh/resource-policy: keep" <<<"$pvc" || false
}

@test "projets : taille du volume workspace, 20Gi par defaut et workspace.taille reglable" {
    run rendu --show-only templates/statefulset.yaml
    [ "$status" -eq 0 ]
    grep -q -- "storage: 20Gi" <<<"$output" || false
    run rendu --show-only templates/statefulset.yaml --set workspace.taille=50Gi
    [ "$status" -eq 0 ]
    grep -q -- "storage: 50Gi" <<<"$output" || false
}

@test "projets : helm template complet passe" {
    run helm template devzone-workspace "$CHART" --namespace devzone-workspace
    [ "$status" -eq 0 ]
}
