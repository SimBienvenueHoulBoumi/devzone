#!/usr/bin/env bash
# Docker workstation put to sleep when the Kubernetes workspace takes over (#517).
# Sourced by migrer.sh (stop) and migrer-retour.sh (start). Containers of the
# workstation folder (label devcontainer.local_folder) and automatic port
# relays (label devzone.auto=true) are stopped, never removed. Without Docker,
# only a warning: the migration does not fail for that.

# Docker answers on the workstation (command present and daemon running).
docker_workstation_ready() {
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

# Ids, one per line, of the containers of folder $1 and of the automatic relays.
# $2 is "running" (docker ps) or "exited" (stopped containers, docker ps -a).
docker_workstation_ids() {
    local folder="$1" etat="$2"
    if [ "$etat" = exited ]; then
        {
            docker ps -aq --filter "label=devcontainer.local_folder=$folder" --filter status=exited
            docker ps -aq --filter "label=devzone.auto=true" --filter status=exited
        } 2>/dev/null | sort -u || true
    else
        {
            docker ps -q --filter "label=devcontainer.local_folder=$folder"
            docker ps -q --filter "label=devzone.auto=true"
        } 2>/dev/null | sort -u || true
    fi
}

# Stops the running containers of folder $1 and the automatic relays (docker stop).
docker_workstation_stop() {
    local ids
    if ! docker_workstation_ready; then
        echo "  ⚠ Docker workstation: Docker does not respond, nothing stopped" >&2
        return 0
    fi
    ids="$(docker_workstation_ids "$1" running)"
    if [ -z "$ids" ]; then
        echo "  – Docker workstation: no running container"
        return 0
    fi
    # shellcheck disable=SC2086
    if docker stop $ids >/dev/null 2>&1; then
        echo "  ✔ Docker workstation stopped (kept: devzone workspace revert restarts it)"
    else
        echo "  ⚠ Docker workstation: some containers could not be stopped" >&2
    fi
    return 0
}

# Starts again the stopped containers of folder $1 and the automatic relays (docker start).
docker_workstation_start() {
    local ids
    if ! docker_workstation_ready; then
        echo "  ⚠ Docker workstation: Docker does not respond, nothing started" >&2
        return 0
    fi
    ids="$(docker_workstation_ids "$1" exited)"
    if [ -z "$ids" ]; then
        echo "  – Docker workstation: no stopped container to start"
        return 0
    fi
    # shellcheck disable=SC2086
    if docker start $ids >/dev/null 2>&1; then
        echo "  ✔ Docker workstation started again"
    else
        echo "  ⚠ Docker workstation: some containers could not be started" >&2
    fi
    return 0
}
