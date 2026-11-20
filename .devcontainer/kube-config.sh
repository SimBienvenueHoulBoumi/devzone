#!/usr/bin/env bash
# Kubernetes clusters of the container, at each startup (the port of the host
# cluster can change):
# - ~/.kube/hote.config: copy of the host's ~/.kube (mounted read-only) where
#   127.0.0.1/localhost become host.docker.internal, the host seen from the container;
#   tls-server-name keeps the name expected by the certificate
# - ~/.kube/config: kind clusters of the container, never touched here
# KUBECONFIG (devcontainer.json) combines the two.
# kubernetes module (devzone enable kubernetes): connection to the host cluster
# and metrics-server only if it is enabled; the kind contexts are always restored
# (a cluster created by hand stays usable).
set -euo pipefail

ICI="$(dirname "$0")"
# shellcheck source=SCRIPTDIR/cluster.sh
. "$ICI/cluster.sh"
module=off
bash "$ICI/devzone" is-enabled kubernetes && module=on

# DEVZONE_KUBE_SOURCE: functional tests (never the host cluster)
SOURCE="${DEVZONE_KUBE_SOURCE:-$HOME/.kube-host/config}"
HOST_CONFIG="$HOME/.kube/hote.config"

mkdir -p "$HOME/.kube"
rm -f "$HOST_CONFIG"
# Must exist: otherwise kind writes into hote.config, erased at the next startup
[ -f "$HOME/.kube/config" ] || install -m 600 /dev/null "$HOME/.kube/config"

if [ "$module" = on ] && [ -f "$SOURCE" ]; then
    install -m 600 "$SOURCE" "$HOST_CONFIG"
    kube_reachable_from_container "$HOST_CONFIG"
    devzone_context_set
fi

# Rewrite 127.0.0.1/localhost → host.docker.internal for the kind clusters, whose
# API server is at 127.0.0.1:<port> but unreachable from the container. Idempotent.
kube_reachable_from_container "$HOME/.kube/config"

# kind clusters that survived the restart: context restored in ~/.kube/config
# (the internal Docker may take a few seconds to start)
for _ in 1 2 3 4 5 6 7 8 9 10; do docker info >/dev/null 2>&1 && break; sleep 1; done
choice="$(KUBECONFIG="$HOME/.kube/config" kubectl config current-context 2>/dev/null || true)"
for cluster in $(kind get clusters 2>/dev/null); do
    kind export kubeconfig --name "$cluster" --kubeconfig "$HOME/.kube/config" >/dev/null 2>&1 || true
done
# The kubeconfigs exported by kind carry server: https://127.0.0.1:<port>;
# make them reachable from the container.
kube_reachable_from_container "$HOME/.kube/config"

# Active cluster: the one chosen before (kubectl config use-context), otherwise
# the host's if it has one (current-context of hote.config), otherwise kind
export KUBECONFIG="$HOME/.kube/config:$HOST_CONFIG"
if [ -n "$choice" ] && kubectl config use-context "$choice" >/dev/null 2>&1; then
    :
elif [ -f "$HOST_CONFIG" ] && [ -n "$(KUBECONFIG="$HOST_CONFIG" kubectl config current-context 2>/dev/null)" ]; then
    KUBECONFIG="$HOME/.kube/config" kubectl config unset current-context >/dev/null
fi

# Reachable clusters, among those of the host and those of kind
reachable=0
for context in $(kubectl config get-contexts -o name 2>/dev/null); do
    if kubectl --context "$context" --request-timeout=3s get --raw /readyz >/dev/null 2>&1; then
        echo "kube-config : cluster reachable : $context"
        reachable=$((reachable + 1))
    elif [[ "$context" == kind-* ]]; then
        echo "kube-config : kind cluster starting: $context"
        reachable=$((reachable + 1))
    fi
done
# Module disabled: the devzone summary reports it
[ "$module" = on ] || exit 0
echo "kube-config : active cluster: $(kubectl config current-context 2>/dev/null || echo none)"
if [ "$reachable" -eq 0 ]; then
    echo "kube-config : no reachable cluster; create one in the container: kind create cluster"
fi

# CPU/RAM in k9s: metrics-server on the reachable clusters that do not have it
bash "$ICI/metrics-server.sh" || true
