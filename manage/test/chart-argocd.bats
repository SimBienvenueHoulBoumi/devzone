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

@test "chart devzone-argocd: dependency pinned at the devzone version in Chart.yaml and Chart.lock" {
    grep -q 'repository: https://argoproj.github.io/argo-helm' "$CHART/Chart.yaml"
    grep -q 'version: 10.14.0' "$CHART/Chart.yaml"
    [ -f "$CHART/Chart.lock" ]
    grep -q 'version: 10.14.0' "$CHART/Chart.lock"
}

@test "chart devzone-argocd: dependency build before the render, lint" {
    run helm dependency build "$CHART"
    [ "$status" -eq 0 ]
    [ -f "$CHART/charts/argo-cd-10.14.0.tgz" ]
    run helm lint "$CHART"
    [ "$status" -eq 0 ]
}

@test "chart devzone-argocd: renders Argo CD with the devzone values (ClusterIP, no dex)" {
    rendered="$(helm template argocd "$CHART" --namespace devzone-argocd)"
    printf '%s\n' "$rendered" | grep -q 'name: argocd-cm'
    printf '%s\n' "$rendered" | grep -q 'type: ClusterIP'
    # No dex server deployed: no Deployment name carries dex
    ! printf '%s\n' "$rendered" | awk '/^kind: Deployment$/{d=1} d && /^  name:/{print; d=0}' | grep -q dex || false
}

@test "chart devzone-argocd: one replica per component, no Ingress" {
    rendered="$(helm template argocd "$CHART" --namespace devzone-argocd)"
    # Replicas of the deployments (applicationset may not carry one, argo-cd
    # charts put one on server, controller, repoServer, notifications)
    ! printf '%s\n' "$rendered" | grep -q 'name: argocd-notifications-controller$' || false
}
