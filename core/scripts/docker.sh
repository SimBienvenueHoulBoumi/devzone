#!/usr/bin/env bash
# Vérification de Docker sur l'hôte, avant tout appel (sourcé par lancer.sh,
# desinstaller.sh et la commande npm core/devzone) : sans elle, l'utilisateur
# ne voit que l'erreur brute du CLI devcontainers ou de docker.
# DEVZONE_DOCKER : nom de la commande docker (tests : simuler son absence).
# Compatible bash 3.2 (macOS).

# Code 0 si Docker répond ; sinon, sur stderr, la cause (absent, sans droits,
# arrêté) et quoi faire, puis relancer $1 ; code 1. Rien de brut à l'écran.
docker_pret() {
    local commande="$1" docker="${DEVZONE_DOCKER:-docker}" erreur
    if ! command -v "$docker" >/dev/null 2>&1; then
        {
            echo "✖ Docker introuvable : devzone en a besoin pour faire tourner son conteneur."
            echo "  Installe Docker Desktop (macOS, Windows, Linux) : https://docs.docker.com/desktop/"
            echo "  ou, sous Linux, Docker Engine : https://docs.docker.com/engine/install/"
            echo "  puis relance $commande"
        } >&2
        return 1
    fi
    erreur="$("$docker" info 2>&1 >/dev/null)" && return 0
    case "$erreur" in
        *"permission denied"* | *"Permission denied"*)
            {
                echo "✖ Docker refuse l'accès : ton compte n'est pas dans le groupe docker."
                echo "  sudo usermod -aG docker \$USER, puis ouvre une nouvelle session (ou newgrp docker),"
                echo "  puis relance $commande"
            } >&2
            ;;
        *)
            {
                echo "✖ Docker est installé mais ne répond pas (arrêté ?)."
                echo "  Démarre Docker Desktop (sous Linux sans Docker Desktop : sudo systemctl start docker),"
                echo "  puis relance $commande"
            } >&2
            ;;
    esac
    return 1
}
