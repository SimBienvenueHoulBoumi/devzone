#!/usr/bin/env bash
# Leftovers of the gitlab instance after disable (test-gitlab.sh --complet, #517).
# Sourced by test-gitlab.sh. Docker workstation: containers labelled with the
# instance, from docker ps. Kubernetes workspace (DEVZONE_WORKSPACE=kubernetes):
# pods labelled with the instance, from kubectl get pods. Read-only commands.

# Prints the leftovers of instance $1, one per line (nothing when clean).
gitlab_restes_conteneurs() {
    local instance="$1"
    if [ "${DEVZONE_WORKSPACE:-}" = kubernetes ]; then
        kubectl --context devzone get pods --all-namespaces \
            -l "devzone.instance=$instance" -o name 2>/dev/null || true
    else
        docker ps -aq --filter "label=devzone.instance=$instance" 2>/dev/null || true
    fi
}
