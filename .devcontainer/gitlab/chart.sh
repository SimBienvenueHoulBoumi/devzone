#!/usr/bin/env bash
# GitLab installed from the wrapper chart charts/devzone-gitlab (#538): the
# official gitlab 9.11.16 and gitlab-runner 0.88.2 are dependencies pinned in
# the chart, its values.yaml holds the values of the GitLab of devzone
# (under the gitlab and gitlab-runner keys). This file is the helm-direct
# path, the Application of Argo CD is argocd.sh. Sourced by installation.sh.
#   gitlab_chart_depend          repository HTTP gitlab added, dependency build
#   gitlab_helm_pass <replicas>  upgrade --install of the chart, runner replicas
#   gitlab_runner_ancien_retirer release gitlab-runner of before #538 removed
# The runner is held back (replicas 0) on the first pass: its Secret
# gitlab-runner-secret is written by the seed, and a runner pod waiting for it
# would hold --wait until the timeout.

# The dependencies come from https://charts.gitlab.io (no OCI repository is
# published): the repository is added before the build, idempotent
gitlab_chart_depend() {
    helm repo add gitlab https://charts.gitlab.io --force-update >/dev/null 2>&1 || true
    helm dependency build "$RACINE/charts/devzone-gitlab" >/dev/null
}

# One helm pass of the wrapper chart. The webservice URL of the runner follows
# the namespace of the instance: the chart value is not templated, its default
# is the main instance, so it is passed here
gitlab_helm_pass() {
    local replicas="$1"
    compte_helm "$(compte_ctx)" upgrade --install gitlab "$RACINE/charts/devzone-gitlab" \
        --namespace "$GITLAB_NS" \
        --create-namespace \
        --timeout "${GITLAB_ATTENTE}s" \
        --wait \
        --set "gitlab-runner.gitlabUrl=http://gitlab-webservice-default.$GITLAB_NS.svc:8181" \
        --set "gitlab-runner.replicas=$replicas"
}

# Release gitlab-runner of the installations before the wrapper chart (#396):
# its runner now comes with the chart, the release leaves without touching data
gitlab_runner_ancien_retirer() {
    compte_helm "$(compte_ctx)" uninstall gitlab-runner --namespace "$GITLAB_NS" >/dev/null 2>&1 || true
}
