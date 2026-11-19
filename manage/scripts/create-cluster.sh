#!/usr/bin/env bash
# Way out of "no cluster" at creation (#653), sourced by create-mode.sh.
# In a terminal, a menu: a remote cluster (a context of the kubeconfig, its name
# typed back to confirm, #326) or a local minikube cluster (profile devzone).
# Without a terminal nothing is asked: the caller prints the failure (no silent
# fallback). devzone never runs a cloud command and never installs minikube: it
# only displays the official command. DEVZONE_TERMINAL=1 forces the terminal
# mode, the answers then come from stdin (tests). Sourced only. Bash 3.2.

# True in a terminal (or forced for the tests).
create_cluster_terminal() {
    [ -n "${DEVZONE_TERMINAL:-}" ] || [ -t 0 ]
}

# True when the context is a local cluster: never offered as a remote one.
create_cluster_is_local() {
    local ctx="$1" server
    case "$ctx" in
        docker-desktop | desktop-* | minikube | devzone | rancher-desktop | orbstack | colima | kind-* | k3d-*) return 0 ;;
    esac
    server="$(kubectl config view --minify --context "$ctx" -o 'jsonpath={.clusters[0].cluster.server}' 2>/dev/null || true)"
    case "$server" in
        *//127.0.0.1* | *//localhost* | *//\[::1\]*) return 0 ;;
    esac
    return 1
}

# Remote contexts of the kubeconfig, one per line.
create_cluster_remote_contexts() {
    local ctx
    kubectl config get-contexts -o name 2>/dev/null | while IFS= read -r ctx; do
        [ -n "$ctx" ] || continue
        create_cluster_is_local "$ctx" || printf '%s\n' "$ctx"
    done
    return 0
}

# Remote cluster: pick a context, type its name back, make it the current one.
create_cluster_remote() {
    local list answer ctx i=0
    list="$(create_cluster_remote_contexts)"
    if [ -z "$list" ]; then
        echo "✖ no remote context in your kubeconfig: add one with the command of your provider (aws, gcloud, az), then run the same command again" >&2
        return 1
    fi
    echo "Remote contexts of your kubeconfig:"
    while IFS= read -r ctx; do
        i=$((i + 1))
        printf '  %s) %s (remote)\n' "$i" "$ctx"
    done <<<"$list"
    printf 'Number of the cluster (empty to cancel): '
    read -r answer || answer=""
    case "$answer" in
        '' | *[!0-9]*) echo "✖ cancelled" >&2; return 1 ;;
    esac
    ctx="$(printf '%s\n' "$list" | sed -n "${answer}p")"
    [ -n "$ctx" ] || { echo "✖ no such cluster: $answer" >&2; return 1; }
    echo "remote cluster: $ctx. devzone will install a pod, a volume and the namespace devzone-workspace in it: it needs enough rights and may cost."
    printf 'Type its name to confirm: '
    read -r answer || answer=""
    [ "$answer" = "$ctx" ] || { echo "✖ name not typed back: nothing done" >&2; return 1; }
    kubectl config use-context "$ctx" >/dev/null 2>&1 || { echo "✖ cannot select the context $ctx" >&2; return 1; }
    echo "✔ current kubectl context: $ctx"
}

# minikube: displays the official install command when it is missing (never
# runs it); otherwise creates the profile devzone after a confirmation.
create_cluster_minikube() {
    local answer
    if ! command -v minikube >/dev/null 2>&1; then
        echo "minikube is not installed. Official command (devzone does not run it):"
        case "$(uname -s)" in
            Darwin) echo "  brew install minikube" ;;
            Linux) echo "  curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64 && sudo install minikube-linux-amd64 /usr/local/bin/minikube" ;;
            *) echo "  winget install Kubernetes.minikube" ;;
        esac
        echo "Then run the same command again."
        return 1
    fi
    echo "minikube: devzone will run: minikube start -p devzone (profile devzone, driver chosen by minikube)."
    printf 'Create it now? [y/N] '
    read -r answer || answer=""
    case "$answer" in
        y | Y | yes | o | O | oui) ;;
        *) echo "✖ cancelled" >&2; return 1 ;;
    esac
    minikube start -p devzone || { echo "✖ minikube start failed: nothing else done" >&2; return 1; }
    kubectl config use-context devzone >/dev/null 2>&1 || true
    echo "✔ minikube cluster devzone started"
}

# Offers the choice in a terminal. Returns 0 when a cluster was selected or
# created (the caller checks that it answers), 1 otherwise or without a terminal.
create_cluster_offer() {
    local choice
    create_cluster_terminal || return 1
    echo "No Kubernetes cluster answers. Pick one:"
    echo "  1) a remote cluster (AWS, GCP, Azure, other: a context of your kubeconfig)"
    echo "  2) a local minikube cluster (profile devzone)"
    printf 'Your choice (empty to cancel): '
    read -r choice || choice=""
    case "$choice" in
        1) create_cluster_remote ;;
        2) create_cluster_minikube ;;
        *) echo "✖ cancelled" >&2; return 1 ;;
    esac
}
