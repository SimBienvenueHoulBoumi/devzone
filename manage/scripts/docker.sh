#!/usr/bin/env bash
# Checks Docker on the host before any call (sourced by lancer.sh,
# desinstaller.sh and the npm command manage/devzone): without it the user
# would only see the raw devcontainers CLI or docker error.
# DEVZONE_DOCKER: docker command name (tests: simulate its absence).
# Compatible with bash 3.2 (macOS).

# Returns 0 if Docker responds; otherwise prints the cause (missing, no
# permission, stopped) and what to do on stderr, then asks to run $1 again;
# returns 1. Nothing raw on screen.
docker_ready() {
    local command_name="$1" docker_cmd="${DEVZONE_DOCKER:-docker}" err
    if ! command -v "$docker_cmd" >/dev/null 2>&1; then
        {
            echo "✖ Docker not found: devzone needs it to run its container."
            echo "  Install Docker Desktop (macOS, Windows, Linux): https://docs.docker.com/desktop/"
            echo "  or, on Linux, Docker Engine: https://docs.docker.com/engine/install/"
            echo "  then run $command_name again"
        } >&2
        return 1
    fi
    err="$("$docker_cmd" info 2>&1 >/dev/null)" && return 0
    case "$err" in
        *"permission denied"* | *"Permission denied"*)
            {
                echo "✖ Docker denied access: your account is not in the docker group."
                echo "  sudo usermod -aG docker \$USER, then open a new session (or newgrp docker),"
                echo "  then run $command_name again"
            } >&2
            ;;
        *)
            {
                echo "✖ Docker is installed but does not respond (stopped?)."
                echo "  Start Docker Desktop (on Linux without Docker Desktop: sudo systemctl start docker),"
                echo "  then run $command_name again"
            } >&2
            ;;
    esac
    return 1
}

# compatibility alias, removed with lot 4 (#509)
docker_pret() { docker_ready "$@"; }
