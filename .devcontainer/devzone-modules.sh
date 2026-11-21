#!/usr/bin/env bash
# shellcheck shell=bash
# devzone, module state: read, write, enable, disable (changer).
# Sourced by .devcontainer/devzone (split of the 1 600 lines file, #722):
# functions only, shared variables are defined in devzone.

description() {
    case "$1" in
        ia) echo "assistants IA : Claude Code, opencode" ;;
        kubernetes) echo "connexion au cluster de l'hôte et metrics-server au démarrage" ;;
        gitlab) echo "GitLab de test dans le cluster des services" ;;
        postgres) echo "PostgreSQL partagé, une base par projet" ;;
        argocd) echo "Argo CD, interface de déploiement du cluster des services" ;;
        mysql) echo "MySQL partagé, une base par projet" ;;
    esac
}

connu() {
    local m
    for m in "${MODULES[@]}"; do [ "$m" = "$1" ] && return 0; done
    return 1
}

# Premier démarrage (aucun état) : l'état est créé par state.sh (#417) :
# ancien état global repris, copie de secours restaurée, état reconstruit
# depuis le cluster des services, sinon première installation
initialiser() {
    state_init "${MODULES[@]}"
}

valeur() {
    initialiser
    local v
    v="$(grep -E "^$1=" "$ETAT" | tail -1 | cut -d= -f2 || true)"
    # Option docker-hote (#432) : ligne absente = on (socket de l'hôte
    # partagé, comportement historique) ; les modules restent off par défaut
    if [ "$1" = docker-hote ] && [ -z "$v" ]; then
        echo on
        return 0
    fi
    [ "$v" = on ] && echo on || echo off
}

# Verrou tenu de l'initialisation à l'écriture (#417) : l'état n'est jamais
# recréé à vide entre les deux
ecrire() {
    state_lock_take || return 1
    if ! initialiser || ! state_write "$1" "$2"; then
        state_lock_release
        return 1
    fi
    state_lock_release
    return 0
}

# Retire une clé du fichier d'état : la configuration d'un service n'existe
# que pendant qu'il est choisi (#242)
retirer_cle() {
    state_lock_take || return 1
    if ! initialiser || ! state_remove "$1"; then
        state_lock_release
        return 1
    fi
    state_lock_release
    return 0
}

# Vrai si le fichier ne contient que la clé $schema (créé d'office par opencode)
contient_seulement_schema() {
    local autres
    autres="$(grep -vcE '^[[:space:]]*([{}]|"?[$]schema"?[[:space:]]*:.*)?[[:space:]]*$' "$1" || true)"
    [ "$autres" -eq 0 ] && grep -qF "\$schema" "$1"
}

# Message for the removed llm module (migration, #669).
llm_retire_msg() {
    echo "devzone : module llm retiré : devzone n'héberge plus de modèle ; les modèles de l'hôte (Ollama) sont détectés à la place (devzone ai). Pour libérer le disque : kubectl delete namespace devzone-llm"
}

# Drops the llm= state line when present and reports the removal once (#669).
migrer_llm() {
    [ -f "$ETAT" ] || return 0
    grep -qE '^llm=' "$ETAT" 2>/dev/null || return 0
    state_remove llm
    llm_retire_msg
}

changer() {
    local m="${2:-}"
    if [ -z "$m" ]; then
        echo "devzone : module inconnu : (aucun) ; modules : ${MODULES[*]}" >&2
        exit 1
    fi
    # llm removed (#669): migration message, never unknown module.
    if [ "$m" = llm ]; then
        initialiser 2>/dev/null || true
        if [ -f "$ETAT" ] && grep -qE '^llm=' "$ETAT" 2>/dev/null; then
            state_remove llm
        fi
        llm_retire_msg
        return 1
    fi
    migrer_llm
    # Option docker-hote (#432) : le socket de l'hôte, partagé par défaut.
    # Le choix ne s'applique qu'à la création du conteneur ; sans rebuild,
    # le conteneur courant garde son montage.
    if [ "$m" = docker-hote ]; then
        ecrire docker-hote "$1"
        if [ "$1" = on ]; then
            echo "devzone : socket Docker de l'hôte partagé après reconstruction"
        else
            echo "devzone : socket Docker de l'hôte non partagé après reconstruction"
        fi
        echo "devzone : reconstruction nécessaire : sur le poste, make rebuild"
        return 0
    fi
    if ! connu "$m"; then
        # Une application du catalogue : on écrit la ligne, on applique
        if [ -f "$ICI/catalog/$m/app.conf" ]; then
            ecrire "$m" "$1"
            bash "$ICI/catalog.sh" apply
            return
        fi
        echo "devzone : module inconnu : $m ; modules : ${MODULES[*]}" >&2
        exit 1
    fi
    # In the Kubernetes workspace pod the services are installed from the
    # workstation (#528): the pod has no administrator access to the cluster.
    # DEVZONE_SERVICES_ADMIN=1: run by services-admin.sh with a temporary one.
    if dans_pod && service_module "$m" && [ -z "${DEVZONE_SERVICES_ADMIN:-}" ]; then
        if [ "$1" = on ]; then
            echo "devzone: in the workspace pod, $m is installed from the workstation: devzone workspace services enable $m" >&2
        else
            echo "devzone: in the workspace pod, $m is removed from the workstation: devzone workspace services disable $m" >&2
        fi
        return 2
    fi
    if [ "$1" = off ] && { [ "$m" = postgres ] || [ "$m" = mysql ] || [ "$m" = gitlab ]; }; then
        confirmer_suppression "$m" "${@:3}" || return 0
    fi
    ecrire "$m" "$1"
    # Services held by Argo CD (#559): 0 done, 3 helm direct as before, else failed
    if DEVZONE_ETAT="$ETAT" bash "$ICI/argocd/services-hook.sh" "$m" "$1" "${@:3}"; then return 0; elif [ $? -ne 3 ]; then return 1; fi
    "appliquer_$m" "$1" "${@:3}"
}
