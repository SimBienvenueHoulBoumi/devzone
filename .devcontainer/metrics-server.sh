#!/usr/bin/env bash
# Installs metrics-server (CPU/RAM in k9s, kubectl top) on the clusters that
# have no Metrics API. Docker Desktop and kind do not have it by default.
# Usage: metrics-server.sh [context...] | metrics-server.sh retirer [context...]
#        (default: reachable local clusters; retirer, the public subcommand
#        name kept as is: removal from the clusters where devzone installed it)
# --kubelet-insecure-tls: the kubelet of Docker Desktop and kind has a
# self-signed certificate, without this option the pod never becomes Ready.
# Exits in error if a requested context is unknown or unreachable, or if an
# installation fails.
set -euo pipefail

# shellcheck source=SCRIPTDIR/cluster.sh
. "$(dirname "$0")/cluster.sh"
# shellcheck source=SCRIPTDIR/versions.env
. "$(dirname "$0")/versions.env"

VERSION="$METRICS_SERVER_VERSION"
MANIFEST="https://github.com/kubernetes-sigs/metrics-server/releases/download/${VERSION}/components.yaml"

mapfile -t known < <(kubectl config get-contexts -o name 2>/dev/null || true)

if [ "${1:-}" = retirer ]; then
    shift
    # Removal (kubernetes module disabled): only the contexts where devzone
    # installed metrics-server (devzone=installe mark) are removed
    requested=$#
    if [ "$requested" -eq 0 ]; then
        # Local clusters only: removal on a remote cluster has nothing to remove
        # (devzone never installs there)
        mapfile -t contexts < <(printf '%s\n' ${known[@]+"${known[@]}"} |
            while IFS= read -r c; do cluster_is_local "$c" && echo "$c"; done || true)
        set -- ${contexts[@]+"${contexts[@]}"}
    fi
    code=0
    for context in "$@"; do
        # Mark read on the deployment by its name: kubectl refuses a name with
        # a selector (-l), the test would always be false (#255)
        mark="$(kubectl --context "$context" -n kube-system get deployment metrics-server \
            -o jsonpath='{.metadata.labels.devzone}' 2>/dev/null || true)"
        if [ "$mark" = installe ]; then
            if kubectl --context "$context" delete -f "$MANIFEST" --ignore-not-found >/dev/null 2>&1; then
                echo "metrics-server removed ($VERSION) : $context"
            else
                echo "metrics-server : removal failed: $context" >&2
                code=1
            fi
        elif kubectl --context "$context" -n kube-system get deployment metrics-server >/dev/null 2>&1; then
            # Installed by someone else: not up to devzone to remove it
            echo "metrics-server present without a devzone mark, left: $context" >&2
        fi
    done
    exit "$code"
fi

requested=$#
if [ "$requested" -eq 0 ]; then
    # Local clusters only: never an automatic installation on a remote cluster
    # of the host (prod, staging…); for another one, name it as an argument
    mapfile -t contexts < <(printf '%s\n' ${known[@]+"${known[@]}"} |
        while IFS= read -r c; do cluster_is_local "$c" && echo "$c"; done || true)
    set -- ${contexts[@]+"${contexts[@]}"}
fi

code=0
reachable=0
for context in "$@"; do
    if [ "$requested" -gt 0 ] && ! printf '%s\n' ${known[@]+"${known[@]}"} | grep -qxF -- "$context"; then
        echo "metrics-server : unknown context: $context (see kubectl config get-contexts)" >&2
        code=1
        continue
    fi
    k=(kubectl --context "$context" --request-timeout=5s)
    if ! "${k[@]}" get --raw /readyz >/dev/null 2>&1; then
        # Without argument: kind may still be starting, ignored
        if [ "$requested" -gt 0 ]; then
            echo "metrics-server : cluster unreachable: $context" >&2
            code=1
        fi
        continue
    fi
    reachable=$((reachable + 1))
    if "${k[@]}" get apiservice v1beta1.metrics.k8s.io >/dev/null 2>&1; then
        echo "metrics-server : already present: $context"
        continue
    fi
    if "${k[@]}" apply -f "$MANIFEST" >/dev/null &&
        "${k[@]}" -n kube-system patch deployment metrics-server --type=json \
            -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' >/dev/null &&
        # Mark: make desinstaller only removes what devzone installed
        "${k[@]}" -n kube-system label deployment metrics-server devzone=installe app.kubernetes.io/managed-by=devzone --overwrite >/dev/null; then
        echo "metrics-server : installed ($VERSION): $context (metrics within ~1 min)"
    else
        echo "metrics-server : installation failed: $context" >&2
        code=1
    fi
done

if [ "$requested" -eq 0 ] && [ "$reachable" -eq 0 ]; then
    echo "metrics-server : no reachable local cluster; after kind create cluster: bash .devcontainer/metrics-server.sh"
fi
exit "$code"
