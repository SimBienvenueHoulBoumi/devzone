#!/usr/bin/env bash
# GitLab held by Argo CD (#538): with the module argocd on and installed, the
# installation is the Application devzone-gitlab on the wrapper chart
# charts/devzone-gitlab at the revision, instead of a helm pass (chart.sh).
# The Rails secret is re-applied before it (installation.sh), the seed runs
# once GitLab answers (seed.sh); the runner token goes to the Secret
# gitlab-runner-secret written by the seed, out of Git.
# Sourced by installation.sh (through gitlab.sh). bash 3.2 (macOS).
#   gitlab_argocd_active              module argocd on, chart present, revision
#   gitlab_release_adopter            helm release of before Argo CD: its release
#                                     secrets removed, the objects are adopted
#   gitlab_application_apply          the Application devzone-gitlab
#   gitlab_application_retirer        the Application removed (namespace kept)

# The catalog side of Argo CD (module on, chart, revision, Application)

# The module argocd is on, the namespace devzone-argocd is installed, the chart
# is in the repository and the revision is known: a development clone (version
# 0.0.0) keeps the helm-direct path, like the catalog applications
gitlab_argocd_active() {
    "$ICI/../devzone" argocd catalog-active gitlab
}

# Argo CD takes over the objects of a helm release gitlab: the release secrets
# (sh.helm.release.v1.gitlab.*) go, so that helm no longer owns the objects
gitlab_release_adopter() {
    kubectl --context devzone -n "$GITLAB_NS" delete secret \
        -l owner=helm,name=gitlab --ignore-not-found >/dev/null 2>&1 || true
}

# The Application on charts/devzone-gitlab at the revision, in the namespace of
# the instance; the internal URL of the webservice follows that namespace
# (chart value not templated, passed as a helm parameter, as in chart.sh)
gitlab_application_apply() {
    "$ICI/../devzone" argocd chart-require gitlab || return $?
    echo "▶ Application devzone-gitlab (Argo CD, charts/devzone-gitlab at $("$ICI/../devzone" argocd revision))…"
    "$ICI/../devzone" argocd gitops-apply devzone-gitlab service "$GITLAB_NS" "$DEVZONE_REPO_URL" "$("$ICI/../devzone" argocd revision)" "charts/devzone-gitlab" "gitlab-runner.gitlabUrl=http://gitlab-webservice-default.$GITLAB_NS.svc:8181" || return 1
    # Argo CD reads Git every 3 min: an immediate refresh of the Application
    kubectl --context devzone -n devzone-argocd annotate application.argoproj.io \
        devzone-gitlab argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
}

# The Application removed when GitLab is uninstalled: its resources leave with
# it; nothing to do when the module argocd is off or the Application is absent
gitlab_application_retirer() {
    "$ICI/../devzone" argocd catalog-application-exists gitlab || return 0
    "$ICI/../devzone" argocd catalog-delete gitlab
}
