#!/usr/bin/env bash
# Argo CD Application manifest of devzone (#516), printed on stdout:
#   application.sh <name> <kind> <destination namespace> <repo url> <revision> <path> [key=value ...]
# kind: workspace | service | project (label devzone.io/kind). Each key=value
# is a Helm parameter of the source. Automated sync with prune and selfHeal,
# the destination namespace created, the resources deleted with the
# Application (finalizer). The Application lives in devzone-argocd.
# bash 3.2 (macOS): used by the workstation and by the container.
set -euo pipefail

usage() {
    echo "usage: application.sh <name> <kind> <destination namespace> <repo url> <revision> <path> [key=value ...]" >&2
    exit 2
}

[ "$#" -ge 6 ] || usage
name="$1" kind="$2" namespace="$3" repo="$4" revision="$5" path="$6"
shift 6
case "$kind" in
    workspace | service | project) ;;
    *) echo "application.sh: unknown kind: $kind (workspace, service, project)" >&2; exit 2 ;;
esac
case "$name" in
    '' | *[!a-z0-9-]* | -*) echo "application.sh: invalid name: ${name:-(none)} (lowercase letters, digits, dashes)" >&2; exit 2 ;;
esac
if [ -z "$namespace" ] || [ -z "$repo" ] || [ -z "$revision" ] || [ -z "$path" ]; then
    usage
fi

cat <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $name
  namespace: devzone-argocd
  labels:
    app.kubernetes.io/managed-by: devzone
    devzone.io/kind: $kind
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: $repo
    targetRevision: $revision
    path: $path
EOF
if [ "$#" -gt 0 ]; then
    echo "    helm:"
    echo "      parameters:"
    for kv in "$@"; do
        case "$kv" in
            *=*) ;;
            *) echo "application.sh: Helm parameter without value: $kv" >&2; exit 2 ;;
        esac
        printf '        - name: %s\n          value: "%s"\n' "${kv%%=*}" "${kv#*=}"
    done
fi
cat <<EOF
  destination:
    server: https://kubernetes.default.svc
    namespace: $namespace
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
