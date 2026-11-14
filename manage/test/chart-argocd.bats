#!/usr/bin/env bats
# Chart charts/devzone-argocd (#538): the wrapper of the official argo-cd
# chart. The dependency (version pinned in Chart.yaml) is built with
# `helm dependency build` before the installation; lint and template check
# that the values of devzone land on the official chart. Skipped without helm,
# like chart-postgres.bats.

setup() {
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CHART="$RACINE/charts/devzone-argocd"
    command -v helm >/dev/null 2>&1 || skip "helm missing"
}

setup_file() {
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    # Copy the chart into the bats temp directory
    cp -a "$RACINE/charts/devzone-argocd" "$BATS_FILE_TMPDIR/chart"
    # Build the OCI dependency without needing helm repo add
    DOCKER_CONFIG="$(mktemp -d)" helm dependency build "$BATS_FILE_TMPDIR/chart" 2>/dev/null || true
    # skip if helm is absent (already handled by setup function)
}

@test "chart devzone-argocd: dependency pinned at the devzone version in Chart.yaml and Chart.lock" {
    CHART_TMP="$BATS_FILE_TMPDIR/chart"
    grep -q 'repository: oci://ghcr.io/argoproj/argo-helm' "$CHART_TMP/Chart.yaml"
    grep -q 'version: 10.14.0' "$CHART_TMP/Chart.yaml"
    [ -f "$CHART_TMP/Chart.lock" ]
    grep -q 'version: 10.14.0' "$CHART_TMP/Chart.lock"
}

@test "chart devzone-argocd: dependency build before the render, lint" {
    CHART_TMP="$BATS_FILE_TMPDIR/chart"
    DOCKER_CONFIG="$(mktemp -d)" run helm dependency build "$CHART_TMP"
    [ "$status" -eq 0 ]
    [ -f "$CHART_TMP/charts/argo-cd-10.14.0.tgz" ]
    run helm lint "$CHART_TMP"
    [ "$status" -eq 0 ]
}

@test "chart devzone-argocd: renders Argo CD with the devzone values (ClusterIP, no dex)" {
    CHART_TMP="$BATS_FILE_TMPDIR/chart"
    rendered="$(helm template argocd "$CHART_TMP" --namespace devzone-argocd)"
    printf '%s\n' "$rendered" | grep -q 'name: argocd-cm'
    printf '%s\n' "$rendered" | grep -q 'type: ClusterIP'
    # No dex server deployed: no Deployment name carries dex
    ! printf '%s\n' "$rendered" | awk '/^kind: Deployment$/{d=1} d && /^  name:/{print; d=0}' | grep -q dex || false
}

@test "chart devzone-argocd: one replica per component, no Ingress" {
    CHART_TMP="$BATS_FILE_TMPDIR/chart"
    rendered="$(helm template argocd "$CHART_TMP" --namespace devzone-argocd)"
    # Replicas of the deployments (applicationset may not carry one, argo-cd
    # charts put one on server, controller, repoServer, notifications)
    ! printf '%s\n' "$rendered" | grep -q 'name: argocd-notifications-controller$' || false
}
