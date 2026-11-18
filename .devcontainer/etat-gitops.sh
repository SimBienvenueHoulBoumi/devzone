#!/usr/bin/env bash
# GitOps repository line of the state in the Kubernetes workspace pod (#639).
# The pod has no kubeconfig and its service account cannot read Applications
# today: one short read of the root Application tells whether Argo CD manages
# the cluster from Git; a refusal or an absence falls back to the workstation
# state. Sourced by devzone, called only when dans_pod is true.

# Namespace of the Argo CD of devzone: GITOPS_NS when the includer knows it
# (argocd/gitops.sh), otherwise the namespace of the module.
: "${GITOPS_NS:=devzone-argocd}"

# State line of the GitOps repository: the URL of the root Application when
# the pod can read it, otherwise the workstation command that shows the state
gitops_state_line() {
    local url
    url="$(kubectl get application devzone -n "$GITOPS_NS" \
        -o jsonpath='{.spec.source.repoURL}' --request-timeout=5s 2>/dev/null || true)"
    if [ -n "$url" ]; then
        printf '  ○ argocd          GitOps repository: %s\n' "$url"
    else
        printf '  ○ argocd          managed from the workstation: devzone workspace argocd status\n'
    fi
}
