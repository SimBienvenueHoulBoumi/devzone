#!/usr/bin/env bash
# Clusters reachable from the container (#291). With the host's Docker, the API
# of a kind cluster listens on 127.0.0.1 OF THE WORKSTATION: inside the
# container, 127.0.0.1 is the container itself.
# 1. kind node found (container publishing this port): the devzone container
#    joins the Docker network of the node and targets https://<node>:6443, the
#    address kind provides for containers (kind get kubeconfig --internal);
#    the node name is in the API certificate. Works under Linux as with Docker
#    Desktop, without exposing anything on the workstation's network.
# 2. Otherwise: https://host.docker.internal:<port>, with the original name for
#    the TLS check (--tls-server-name); enough with Docker Desktop, where
#    host.docker.internal leads to the workstation's 127.0.0.1.
# Sourced library (cluster.sh, kind wrapper); run directly:
#   kube-reachable.sh FILE
#   kube_reachable_from_container FILE   rewrites 127.0.0.1/localhost, idempotent

# kind control-plane node that publishes this port on the workstation (empty otherwise)
kube_kind_node() {
    docker ps --filter "label=io.x-k8s.kind.role=control-plane" --filter "publish=$1" \
        --format '{{.Names}}' 2>/dev/null | head -1
}

# The devzone container joins the node's network (idempotent: already a member = nothing)
kube_join_network() {
    local node="$1" me network
    me="$(hostname)"
    for network in $(docker inspect "$node" \
        --format '{{range $name, $v := .NetworkSettings.Networks}}{{$name}} {{end}}' 2>/dev/null); do
        docker network connect "$network" "$me" >/dev/null 2>&1 || true
    done
}

kube_reachable_from_container() {
    local file="${1:-}" name server host port node
    [ -n "$file" ] || return 0
    # Kubernetes workspace (#517): the pod reaches the API through the cluster service, no docker call
    if [ "${DEVZONE_WORKSPACE:-}" = kubernetes ]; then return 0; fi
    KUBECONFIG="$file" kubectl config view \
        -o jsonpath='{range .clusters[*]}{.name}{"\t"}{.cluster.server}{"\n"}{end}' 2>/dev/null |
        while IFS=$'\t' read -r name server; do
            case "$server" in
                https://127.0.0.1:* | https://localhost:*) ;;
                *) continue ;;
            esac
            host="${server#https://}"
            host="${host%%:*}"
            port="${server##*:}"
            node="$(kube_kind_node "$port")"
            if [ -n "$node" ]; then
                kube_join_network "$node"
                KUBECONFIG="$file" kubectl config set-cluster "$name" \
                    --server="https://${node}:6443" >/dev/null 2>&1 || true
            else
                KUBECONFIG="$file" kubectl config set-cluster "$name" \
                    --server="https://host.docker.internal:${port}" \
                    --tls-server-name="$host" >/dev/null 2>&1 || true
            fi
        done
    return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    kube_reachable_from_container "${1:-}"
fi
