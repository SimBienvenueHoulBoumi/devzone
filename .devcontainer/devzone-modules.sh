#!/usr/bin/env bash
# shellcheck shell=bash
# devzone, module state: read, write, enable, disable (change_module).
# Sourced by .devcontainer/devzone (split of the 1 600 lines file, #722):
# functions only, shared variables are defined in devzone.

description() {
    case "$1" in
        ia) echo "AI assistants: Claude Code, opencode" ;;
        kubernetes) echo "connection to the host cluster and metrics-server at startup" ;;
        gitlab) echo "test GitLab in the services cluster" ;;
        postgres) echo "shared PostgreSQL, one database per project" ;;
        argocd) echo "Argo CD, deployment interface of the services cluster" ;;
        mysql) echo "shared MySQL, one database per project" ;;
    esac
}

is_known() {
    local m
    for m in "${MODULES[@]}"; do [ "$m" = "$1" ] && return 0; done
    return 1
}

# First start (no state): the state is created by state.sh (#417): old global
# state taken over, backup copy restored, state rebuilt from the services
# cluster, otherwise first installation
init_state() {
    state_init "${MODULES[@]}"
}

value_of() {
    init_state
    local v
    v="$(grep -E "^$1=" "$ETAT" | tail -1 | cut -d= -f2 || true)"
    # docker-hote option (#432): missing line = on (host socket shared, the
    # historical behaviour); the modules stay off by default
    if [ "$1" = docker-hote ] && [ -z "$v" ]; then
        echo on
        return 0
    fi
    [ "$v" = on ] && echo on || echo off
}

# State-file lock held from initialisation to write (#417): the state is never
# recreated empty between the two
write_value() {
    state_lock_take || return 1
    if ! init_state || ! state_write "$1" "$2"; then
        state_lock_release
        return 1
    fi
    state_lock_release
    return 0
}

# Removes a key from the state file: the configuration of a service only exists
# while it is chosen (#242)
remove_key() {
    state_lock_take || return 1
    if ! init_state || ! state_remove "$1"; then
        state_lock_release
        return 1
    fi
    state_lock_release
    return 0
}

# True if the file only holds the $schema key (created by opencode by default)
only_schema_key() {
    local others
    others="$(grep -vcE '^[[:space:]]*([{}]|"?[$]schema"?[[:space:]]*:.*)?[[:space:]]*$' "$1" || true)"
    [ "$others" -eq 0 ] && grep -qF "\$schema" "$1"
}

# Message for the removed llm module (migration, #669).
llm_removed_msg() {
    echo "devzone : llm module removed: devzone no longer hosts a model; the host (Ollama) models are detected instead (devzone ai). To free the disk: kubectl delete namespace devzone-llm"
}

# Drops the llm= state line when present and reports the removal once (#669).
migrate_llm() {
    [ -f "$ETAT" ] || return 0
    grep -qE '^llm=' "$ETAT" 2>/dev/null || return 0
    state_remove llm
    llm_removed_msg
}

change_module() {
    local m="${2:-}"
    if [ -z "$m" ]; then
        echo "devzone : unknown module : (none) ; modules : ${MODULES[*]}" >&2
        exit 1
    fi
    # llm removed (#669): migration message, never unknown module.
    if [ "$m" = llm ]; then
        init_state 2>/dev/null || true
        if [ -f "$ETAT" ] && grep -qE '^llm=' "$ETAT" 2>/dev/null; then
            state_remove llm
        fi
        llm_removed_msg
        return 1
    fi
    migrate_llm
    # docker-hote option (#432): the host socket, shared by default.
    # The choice only applies when the container is created; without a
    # rebuild, the current container keeps its mount.
    if [ "$m" = docker-hote ]; then
        write_value docker-hote "$1"
        if [ "$1" = on ]; then
            echo "devzone : host Docker socket shared after rebuild"
        else
            echo "devzone : host Docker socket not shared after rebuild"
        fi
        echo "devzone : rebuild needed: on the workstation, make rebuild"
        return 0
    fi
    if ! is_known "$m"; then
        # An application of the catalog: the line is written, then applied
        if [ -f "$ICI/catalog/$m/app.conf" ]; then
            write_value "$m" "$1"
            bash "$ICI/catalog.sh" apply
            return
        fi
        echo "devzone : unknown module : $m ; modules : ${MODULES[*]}" >&2
        exit 1
    fi
    # In the Kubernetes workspace pod the services are installed from the
    # workstation (#528): the pod has no administrator access to the cluster.
    # DEVZONE_SERVICES_ADMIN=1: run by services-admin.sh with a temporary one.
    if in_pod && service_module "$m" && [ -z "${DEVZONE_SERVICES_ADMIN:-}" ]; then
        if [ "$1" = on ]; then
            echo "devzone: in the workspace pod, $m is installed from the workstation: devzone workspace services enable $m" >&2
        else
            echo "devzone: in the workspace pod, $m is removed from the workstation: devzone workspace services disable $m" >&2
        fi
        return 2
    fi
    if [ "$1" = off ] && { [ "$m" = postgres ] || [ "$m" = mysql ] || [ "$m" = gitlab ]; }; then
        confirm_removal "$m" "${@:3}" || return 0
    fi
    write_value "$m" "$1"
    # Services held by Argo CD (#559): 0 done, 3 helm direct as before, else failed
    if DEVZONE_STATE="$ETAT" bash "$ICI/argocd/services-hook.sh" "$m" "$1" "${@:3}"; then return 0; elif [ $? -ne 3 ]; then return 1; fi
    "apply_$m" "$1" "${@:3}"
}
