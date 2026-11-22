#!/usr/bin/env bash
# Shared check of the Kubernetes cluster (#497, #565), sourced by create-mode.sh,
# create-mode.sh (creation) and workspace.sh (workspace start). Sourced only:
# no code at file level. Compatible with bash 3.2 (macOS) and Linux.

# Returns 0 when kubectl and helm are present and the cluster answers within 5 s
# (context devzone if declared, otherwise the current context). Otherwise
# prints one short line on stdout (kubectl missing, helm missing, or
# cluster <context> unreachable (<server>)) and returns 1. With --hint, prints
# the message for the user instead (#565, see kube_unreachable_hint).
kube_ready_reason() {
    local context server hint=no
    [ "${1:-}" = --hint ] && hint=yes
    command -v kubectl >/dev/null 2>&1 || {
        kube_say "kubectl missing" "$hint"
        return 1
    }
    command -v helm >/dev/null 2>&1 || {
        kube_say "helm missing" "$hint"
        return 1
    }
    if kubectl config get-contexts -o name 2>/dev/null | grep -qx 'devzone'; then
        kubectl cluster-info --request-timeout=5s --context devzone >/dev/null 2>&1 && return 0
        context=devzone
        server="$(kubectl config view --minify --context devzone -o 'jsonpath={.clusters[0].cluster.server}' 2>/dev/null || true)"
    else
        kubectl cluster-info --request-timeout=5s >/dev/null 2>&1 && return 0
        context="$(kubectl config current-context 2>/dev/null || true)"
        server="$(kubectl config view --minify -o 'jsonpath={.clusters[0].cluster.server}' 2>/dev/null || true)"
    fi
    if [ "$hint" = yes ]; then
        kube_unreachable_hint "${context:-none}" "${server:-unknown server}"
    else
        echo "cluster ${context:-none} unreachable (${server:-unknown server})"
    fi
    return 1
}

# One reason line: as is, or as a ✖ line for the user (--hint).
kube_say() {
    if [ "$2" = yes ]; then
        echo "✖ $1"
    else
        echo "$1"
    fi
}

# Cluster name of a context (empty when unknown).
kube_context_cluster() {
    kubectl config view --minify --context "$1" -o 'jsonpath={.clusters[0].name}' 2>/dev/null || true
}

# Message of an unreachable cluster <context> at <server> (#565). The cluster of
# Docker Desktop (context docker-desktop, or a local server 127.0.0.1 or
# localhost of a cluster named docker-desktop) runs inside Docker Desktop: when
# docker info fails, the cause is Docker Desktop stopped; when Docker answers,
# Kubernetes is disabled in it. Any other context gets the generic message.
kube_unreachable_hint() {
    local context="$1" server="$2" cluster host
    cluster="$(kube_context_cluster "$context")"
    host="${server#*://}"
    host="${host%%[:/]*}"
    if [ "$context" = docker-desktop ] ||
        { [ "$cluster" = docker-desktop ] && { [ "$host" = 127.0.0.1 ] || [ "$host" = localhost ]; }; }; then
        if ! docker info >/dev/null 2>&1; then
            echo "✖ Docker Desktop is stopped: the Kubernetes cluster of this machine runs inside it. Start Docker Desktop, then: devzone workspace start"
            echo "  Tip: Settings → General → Start Docker Desktop when you sign in"
        else
            echo "✖ Kubernetes cluster $context unreachable ($server): enable Kubernetes in Docker Desktop (Settings → Kubernetes) or check kubectl config get-contexts"
        fi
        return 0
    fi
    echo "✖ Kubernetes cluster $context unreachable ($server)"
    echo "  Check the contexts: kubectl config get-contexts"
}
