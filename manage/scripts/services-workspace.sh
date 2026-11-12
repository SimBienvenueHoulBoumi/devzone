#!/usr/bin/env bash
# devzone workspace services (#528): installs or removes the devzone services
# (gitlab, postgres, argocd) of a Kubernetes workspace from the workstation.
# Sourced by manage/workspace.sh (drapeau_kubectl, POD, NAMESPACE).
#   devzone workspace services enable <service> [options]
#   devzone workspace services disable <service> [--oui]
#   devzone workspace services status
# Why: the pod has no administrator access to the cluster (#430), while the
# installers need one. The workstation creates a ServiceAccount bound to
# cluster-admin for the time of the operation, asks a one-hour token for it
# and runs the installer inside the pod (kubectl exec, token on stdin, see
# .devcontainer/services-admin.sh). The account and its binding are removed
# at the end, even on failure; the token is never printed.

SERVICES_ADMIN_SA="devzone-services-admin"
# Script run in the pod; DEVZONE_SERVICES_ADMIN_SCRIPT: another copy (trial of
# a version the image of the pod does not hold yet)
SERVICES_ADMIN_SCRIPT="${DEVZONE_SERVICES_ADMIN_SCRIPT:-/usr/local/share/devzone/.devcontainer/services-admin.sh}"
SERVICES_TOKEN_DURATION="${DEVZONE_SERVICES_TOKEN_DURATION:-1h}"

services_usage() {
    echo "devzone workspace services enable|disable <gitlab|postgres|argocd> [options] | status"
}

services_known() {
    case "${1:-}" in
        gitlab | postgres | argocd) return 0 ;;
    esac
    return 1
}

# Namespace of a service in the cluster (gitlab: default instance)
services_namespace() {
    case "$1" in
        gitlab) echo devzone-gitlab ;;
        postgres) echo devzone-postgres ;;
        argocd) echo devzone-argocd ;;
    esac
}

# The workspace pod must be running: the installer runs inside it
services_pod_running() {
    local phase
    # shellcheck disable=SC2046
    phase="$(kubectl $(drapeau_kubectl) get pod "$POD" --namespace "$NAMESPACE" \
        -o jsonpath='{.status.phase}' 2>/dev/null)" || phase=""
    [ "$phase" = Running ]
}

# Temporary administrator: ServiceAccount of the workspace namespace bound to
# cluster-admin (idempotent apply)
services_admin_create() {
    # shellcheck disable=SC2046
    kubectl $(drapeau_kubectl) apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $SERVICES_ADMIN_SA
  namespace: $NAMESPACE
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: $SERVICES_ADMIN_SA
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: $SERVICES_ADMIN_SA
    namespace: $NAMESPACE
EOF
}

services_admin_delete() {
    # shellcheck disable=SC2046
    kubectl $(drapeau_kubectl) delete clusterrolebinding "$SERVICES_ADMIN_SA" \
        --ignore-not-found >/dev/null 2>&1 || true
    # shellcheck disable=SC2046
    kubectl $(drapeau_kubectl) delete serviceaccount "$SERVICES_ADMIN_SA" \
        --namespace "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
}

# Runs the installer in the pod: temporary administrator created, token on
# stdin of kubectl exec, administrator removed whatever the outcome
services_run() {
    local action="$1" service="$2" token code=0
    shift 2
    if ! services_known "$service"; then
        echo "✖ unknown service: ${service:-(none)} ($(services_usage))" >&2
        return 1
    fi
    if ! services_pod_running; then
        echo "✖ workspace pod $POD not running: devzone workspace start" >&2
        return 1
    fi
    echo "▶ temporary administrator $SERVICES_ADMIN_SA (removed at the end)…"
    if ! services_admin_create; then
        echo "✖ cannot create the temporary administrator: cluster-admin rights needed on the workstation" >&2
        return 1
    fi
    trap services_admin_delete EXIT
    # shellcheck disable=SC2046
    if ! token="$(kubectl $(drapeau_kubectl) create token "$SERVICES_ADMIN_SA" \
        --namespace "$NAMESPACE" --duration "$SERVICES_TOKEN_DURATION")" || [ -z "$token" ]; then
        echo "✖ cannot get a token of the temporary administrator (kubectl 1.24 or more)" >&2
        services_admin_delete
        trap - EXIT
        return 1
    fi
    echo "▶ $action $service in the pod $POD…"
    # shellcheck disable=SC2046
    printf '%s\n' "$token" | kubectl $(drapeau_kubectl) exec -i "$POD" --namespace "$NAMESPACE" \
        -c workspace -- bash "$SERVICES_ADMIN_SCRIPT" "$action" "$service" "$@" || code=$?
    services_admin_delete
    trap - EXIT
    if [ "$code" -ne 0 ]; then
        echo "✖ $action $service failed (code $code); in the pod: devzone status" >&2
        return "$code"
    fi
    echo "✔ $action $service done; in the pod: devzone status; local access: devzone workspace ports"
}

# One line per service: installed (namespace present) or not
services_status() {
    local s ns
    for s in gitlab postgres argocd; do
        ns="$(services_namespace "$s")"
        # shellcheck disable=SC2046
        if kubectl $(drapeau_kubectl) get namespace "$ns" >/dev/null 2>&1; then
            echo "  ✔ $s installed (namespace $ns): devzone workspace services disable $s"
        else
            echo "  ○ $s not installed: devzone workspace services enable $s"
        fi
    done
}

services() {
    local sub="${1:-}"
    case "$sub" in
        enable | activer) services_run enable "${2:-}" "${@:3}" ;;
        disable | desactiver) services_run disable "${2:-}" "${@:3}" ;;
        status | etat | '') services_status ;;
        *)
            echo "✖ unknown subcommand: $sub ($(services_usage))" >&2
            return 1
            ;;
    esac
}
