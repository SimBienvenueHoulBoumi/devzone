#!/usr/bin/env bash
# Installs or removes a devzone service (gitlab, postgres, argocd) from inside
# the Kubernetes workspace pod, with a temporary administrator token (#528).
#   services-admin.sh enable|disable <service> [options of devzone enable]
# Run by the workstation (manage/scripts/services-workspace.sh) through
# kubectl exec -i: the token comes on stdin, is never printed and lives only
# in a temporary kubeconfig removed at the end.
# Why: the pod has no kubeconfig and its service account is limited (#430),
# while the installers need an administrator. The temporary kubeconfig holds
# two contexts on the cluster of the pod (API server kubernetes.default.svc,
# CA of the pod): devzone-admin, the administrator the installers use through
# the line cluster=devzone-admin of the state, and devzone, the context the
# module scripts use (compte_jeton may replace it by the limited account).
# The cluster line of the state is put back afterwards, and the relays
# started by the installer are stopped: in the pod the services are reached
# by the cluster DNS, and a relay would keep the token in use.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RACINE="${DEVZONE_RACINE:-$(dirname "$HERE")}"
ETAT="${DEVZONE_ETAT:-$RACINE/.devzone.modules}"
SA_DIR="${DEVZONE_SA_DIR:-/var/run/secrets/kubernetes.io/serviceaccount}"
API_SERVER="${DEVZONE_API_SERVER:-https://kubernetes.default.svc}"
ADMIN_CONTEXT=devzone-admin
ADMIN_USER=devzone-services-admin
ADMIN_CLUSTER=devzone-pod

refuse() {
    echo "devzone services: $*" >&2
    exit 2
}

# shellcheck source=SCRIPTDIR/etat.sh
# shellcheck disable=SC1091
. "$HERE/etat.sh"

action="${1:-}"
service="${2:-}"
case "$action" in
    enable | activer) action=enable ;;
    disable | desactiver) action=disable ;;
    *) refuse "usage: services-admin.sh enable|disable gitlab|postgres|argocd [options]" ;;
esac
case "$service" in
    gitlab | postgres | argocd) ;;
    *) refuse "unknown service: ${service:-(none)} (gitlab, postgres, argocd)" ;;
esac
[ "${DEVZONE_WORKSPACE:-}" = kubernetes ] || refuse "only in the Kubernetes workspace pod"
[ -f "$SA_DIR/ca.crt" ] || refuse "cluster CA not found: $SA_DIR/ca.crt"
if [ -t 0 ]; then
    refuse "the token is read on stdin (run by devzone workspace services)"
fi
token="$(cat)"
token="${token//[$'\r\n']/}"
[ -n "$token" ] || refuse "empty token on stdin"

kubeconfig="$(mktemp "${TMPDIR:-/tmp}/devzone-services-admin.XXXXXX")"
chmod 600 "$kubeconfig"
cluster_before="$(grep -E '^cluster=' "$ETAT" 2>/dev/null | tail -1 | cut -d= -f2- || true)"

# Always at the end, even on failure: kubeconfig removed, relays stopped,
# cluster line of the state as before
cleanup() {
    rm -f "$kubeconfig"
    devzone "$service" relais-arreter >/dev/null 2>&1 || true
    if [ -n "$cluster_before" ]; then
        etat_ecrire cluster "$cluster_before" || true
    else
        etat_retirer cluster || true
    fi
}
trap cleanup EXIT

ca_data="$(base64 <"$SA_DIR/ca.crt" | tr -d '\n')"
cat >"$kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: $ADMIN_CLUSTER
    cluster:
      server: $API_SERVER
      certificate-authority-data: $ca_data
users:
  - name: $ADMIN_USER
    user:
      token: $token
contexts:
  - name: $ADMIN_CONTEXT
    context:
      cluster: $ADMIN_CLUSTER
      user: $ADMIN_USER
  - name: devzone
    context:
      cluster: $ADMIN_CLUSTER
      user: $ADMIN_USER
current-context: $ADMIN_CONTEXT
EOF
unset token ca_data

export KUBECONFIG="$kubeconfig"
export DEVZONE_KUBE_CONFIG="$kubeconfig"
export DEVZONE_SERVICES_ADMIN=1
etat_ecrire cluster "$ADMIN_CONTEXT" || refuse "cannot write the state: $ETAT"
echo "devzone services: $action $service in the cluster of the pod (temporary administrator)"
devzone "$action" "$service" "${@:3}"
