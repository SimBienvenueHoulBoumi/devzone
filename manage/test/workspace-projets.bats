#!/usr/bin/env bats
# Workspace projects in a volume (#399): mount on /workspaces/projets,
# workingDir, helm.sh/resource-policy: keep annotation and size (workspace.size).
# helm is real helm (lint and template required by design, like
# the suite of the workspace with no Docker socket); kubectl is a fake tool there
# $BATS_TEST_TMPDIR/bin: no cluster is touched.

setup() {
    load commun
    relais_docker_isole
    kube_isole
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CHART="$ROOT/charts/devzone-workspace"
    T="$BATS_TEST_TMPDIR"
    mkdir -p "$T/bin"
    cat >"$T/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"$BATS_TEST_TMPDIR/kubectl.log"
exit 0
KUBE
    chmod +x "$T/bin/kubectl"
    export PATH="$T/bin:$PATH"
    command -v helm >/dev/null 2>&1 || skip "helm missing"
}

# Full chart render, with given options.
render() {
    helm template t "$CHART" --namespace devzone-workspace "$@"
}

# volumeClaimTemplates block (from keyword to end of render).
pvc_block() {
    awk '/^  volumeClaimTemplates:/{p=1} p' <<<"$1"
}

@test "projects: helm lint of chart" {
    run helm lint "$CHART"
    [ "$status" -eq 0 ]
}

@test "projects: workspace PVC mounted on /workspaces/projets" {
    run render
    [ "$status" -eq 0 ]
    grep -q -- "mountPath: /workspaces/projets" <<<"$output" || false
    # Old /workspace mount no longer exists
    ! grep -q -- "mountPath: /workspace$" <<<"$output" || false
}

@test "projects: container starts in /workspaces/projets (workingDir)" {
    run render --show-only templates/statefulset.yaml
    [ "$status" -eq 0 ]
    grep -q -- "workingDir: /workspaces/projets" <<<"$output" || false
}

@test "projects: workspace PVC carries helm.sh/resource-policy: keep annotation" {
    run render --show-only templates/statefulset.yaml
    [ "$status" -eq 0 ]
    local pvc
    pvc="$(pvc_block "$output")"
    grep -q -- "name: workspace" <<<"$pvc" || false
    grep -q -- "helm.sh/resource-policy: keep" <<<"$pvc" || false
}

@test "projects: workspace volume size, 20Gi by default and workspace.size configurable" {
    run render --show-only templates/statefulset.yaml
    [ "$status" -eq 0 ]
    grep -q -- "storage: 20Gi" <<<"$output" || false
    run render --show-only templates/statefulset.yaml --set workspace.size=50Gi
    [ "$status" -eq 0 ]
    grep -q -- "storage: 50Gi" <<<"$output" || false
}

@test "projects: full helm template passes" {
    run helm template devzone-workspace "$CHART" --namespace devzone-workspace
    [ "$status" -eq 0 ]
}
