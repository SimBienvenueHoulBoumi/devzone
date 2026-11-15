#!/usr/bin/env bash
# Shared check of the Kubernetes cluster (#497), sourced by poste.sh (and by
# create-mode.sh at creation). Sourced only: no code at file level.
# Compatible with bash 3.2 (macOS) and Linux.

# Returns 0 when kubectl and helm are present and the cluster answers within 5 s
# (context devzone if declared, otherwise the current context). Otherwise
# prints one short line on stdout (kubectl missing, helm missing, or
# cluster <context> unreachable (<server>)) and returns 1.
kube_ready_reason() {
    local context server
    command -v kubectl >/dev/null 2>&1 || {
        echo "kubectl missing"
        return 1
    }
    command -v helm >/dev/null 2>&1 || {
        echo "helm missing"
        return 1
    }
    if kubectl config get-contexts -o name 2>/dev/null | grep -qx 'devzone'; then
        kubectl cluster-info --request-timeout=5s --context devzone >/dev/null 2>&1 && return 0
        context=devzone
        server="$(kubectl config view --minify --context devzone -o 'jsonpath={.clusters[0].server}' 2>/dev/null || true)"
    else
        kubectl cluster-info --request-timeout=5s >/dev/null 2>&1 && return 0
        context="$(kubectl config current-context 2>/dev/null || true)"
        server="$(kubectl config view --minify -o 'jsonpath={.clusters[0].server}' 2>/dev/null || true)"
    fi
    echo "cluster ${context:-none} unreachable (${server:-unknown server})"
    return 1
}
