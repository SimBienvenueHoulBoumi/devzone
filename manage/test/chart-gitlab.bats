#!/usr/bin/env bats
# Chart charts/devzone-gitlab (#538): wrapper of the official GitLab charts.
# The dependencies (versions pinned in Chart.yaml) are built with
# `helm dependency build` before the render; lint and template check that the
# devzone values land on the official charts. Skipped without helm.

setup() {
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    command -v helm >/dev/null 2>&1 || skip "helm missing"
    # Helm config specific to the test: the repository of the dependency is declared here
    # (as in check-charts), the runner does not need to have it locally
    export HELM_REPOSITORY_CONFIG="$BATS_TEST_TMPDIR/helm/repositories.yaml" \
        HELM_REPOSITORY_CACHE="$BATS_TEST_TMPDIR/helm/cache"
    source "$RACINE/manage/scripts/check-charts.sh"
    charts_helm_repos "$RACINE/charts/devzone-gitlab/Chart.yaml" "$BATS_TEST_TMPDIR/helm" || return 1
    CHART="$BATS_TEST_TMPDIR/devzone-gitlab"
    cp -R "$RACINE/charts/devzone-gitlab" "$CHART"
}

@test "chart devzone-gitlab: dependencies pinned in Chart.yaml" {
    grep -q 'name: gitlab' "$CHART/Chart.yaml"
    grep -q 'version: 9.11.16' "$CHART/Chart.yaml"
    grep -q 'name: gitlab-runner' "$CHART/Chart.yaml"
    grep -q 'version: 0.88.2' "$CHART/Chart.yaml"
    grep -q 'repository: https://charts.gitlab.io' "$CHART/Chart.yaml"
}

@test "chart devzone-gitlab: dependency build before the render, lint" {
    run helm dependency build "$CHART"
    [ "$status" -eq 0 ]
    [ -f "$CHART/charts/gitlab-9.11.16.tgz" ]
    [ -f "$CHART/charts/gitlab-runner-0.88.2.tgz" ]
    [ -f "$CHART/Chart.lock" ]
    run helm lint "$CHART"
    [ "$status" -eq 0 ]
}

@test "chart devzone-gitlab: renders GitLab with the devzone values (ClusterIP, port 8929, no ingress)" {
    run helm dependency build "$CHART"
    [ "$status" -eq 0 ]
    rendered="$(helm template gitlab "$CHART" --namespace devzone-gitlab)"
    printf '%s\n' "$rendered" | grep -q 'gitlab-webservice-default'
    printf '%s\n' "$rendered" | grep -q 'ClusterIP'
    printf '%s\n' "$rendered" | grep -q '8929'
    ! printf '%s\n' "$rendered" | grep -q 'kind: Ingress$' || false
}

@test "chart devzone-gitlab: runner uses the secret and the internal service URL" {
    run helm dependency build "$CHART"
    [ "$status" -eq 0 ]
    rendered="$(helm template gitlab "$CHART" --namespace devzone-gitlab)"
    printf '%s\n' "$rendered" | grep -q 'gitlab-runner-secret'
    printf '%s\n' "$rendered" | grep -q 'http://gitlab-webservice-default.devzone-gitlab.svc:8181'
}
