#!/usr/bin/env bash
# Safe write of the module state (#417): the only place that sets, replaces
# or removes a line of $ETAT. A mkdir lock prevents two simultaneous writes,
# the temporary file is created in the state folder (the mv stays atomic: the
# file is never missing or incomplete for a reader) and a backup copy
# $ETAT.prec precedes each replacement. The same file creates the state when
# it is missing: former global state taken over once, backup copy restored,
# state rebuilt from the services cluster, otherwise first installation.
# Sourced library: the caller defines ETAT (file name kept: shared by callers).
#   state_write <key> <value>     sets or replaces the line <key>=<value>
#   state_remove <key>            removes the line <key>=
#   state_replace <file>          replaces the whole state with this file
#   state_lock_take / state_lock_release    write lock
#   state_recovery_*              state restored or rebuilt (step 4)
#   state_init [modules…]         creates the state if it is missing

# Write lock (#476): state_lock_take, state_lock_release
# shellcheck source=SCRIPTDIR/state-lock.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/state-lock.sh"

# Abort under lock: the temporary file goes, the lock is released
state_abort() {
    rm -f "${1:-}"
    state_lock_release
    return 1
}

# Backup copy of the current state, before replacement
state_backup() {
    [ -f "$ETAT" ] || return 0
    cp "$ETAT" "${ETAT}.prec"
}

# The state without the line $1, written to the temporary file $2
state_filter() {
    local key="$1" dst="$2" code=0
    [ -f "$ETAT" ] || return 0
    grep -vE "^${key}=" "$ETAT" >"$dst" || code=$?
    [ "$code" -le 1 ] || return 1
    return 0
}

# Under lock: replaces the whole state with a file, $ETAT.prec backed up
state_replace() {
    local src="$1" tmp
    [ -f "$src" ] || return 1
    state_lock_take || return 1
    state_backup || { state_lock_release; return 1; }
    tmp="$(mktemp "${ETAT}.XXXXXX")" || { state_lock_release; return 1; }
    cat "$src" >"$tmp" || { state_abort "$tmp"; return 1; }
    mv "$tmp" "$ETAT" || { state_abort "$tmp"; return 1; }
    state_lock_release
    return 0
}

# Under lock: new value of a key, without losing the other lines
state_write() {
    local key="$1" value="$2" tmp
    state_lock_take || return 1
    state_backup || { state_lock_release; return 1; }
    tmp="$(mktemp "${ETAT}.XXXXXX")" || { state_lock_release; return 1; }
    state_filter "$key" "$tmp" || { state_abort "$tmp"; return 1; }
    printf '%s=%s\n' "$key" "$value" >>"$tmp" || { state_abort "$tmp"; return 1; }
    mv "$tmp" "$ETAT" || { state_abort "$tmp"; return 1; }
    state_lock_release
    return 0
}

# Under lock: removes a key (#417); without state, nothing to remove
state_remove() {
    local key="$1" tmp
    state_lock_take || return 1
    [ -f "$ETAT" ] || { state_lock_release; return 0; }
    state_backup || { state_lock_release; return 1; }
    tmp="$(mktemp "${ETAT}.XXXXXX")" || { state_lock_release; return 1; }
    state_filter "$key" "$tmp" || { state_abort "$tmp"; return 1; }
    mv "$tmp" "$ETAT" || { state_abort "$tmp"; return 1; }
    state_lock_release
    return 0
}

# Marks a restored or rebuilt state: the watchers wait (#417)
state_recovery_mark() {
    date +%s >"${ETAT}.recouvre" 2>/dev/null || true
}

# 0 (to wait) less than 60 s after a restore or a rebuild
state_recovery_wait() {
    local mark
    [ -f "${ETAT}.recouvre" ] || return 1
    mark="$(cat "${ETAT}.recouvre" 2>/dev/null || true)"
    case "$mark" in
        '' | *[!0-9]*) return 1 ;;
    esac
    [ "$(( $(date +%s) - mark ))" -lt 60 ]
}

# 0 if the restored or rebuilt state is not yet confirmed (#417)
state_recovery_pending() {
    [ -f "${ETAT}.recouvre" ]
}

# The user confirmed the state (devzone apply): no more guard
state_recovery_confirm() {
    rm -f "${ETAT}.recouvre" 2>/dev/null || true
    return 0
}

# First installation (#417): the default state, written in one go
state_default() {
    local stage code=0
    stage="$(mktemp)" || return 1
    printf 'ai=off\nkubernetes=off\ngitlab=off\n' >"$stage"
    state_replace "$stage" || code=$?
    rm -f "$stage"
    return "$code"
}

# Host context (host KUBECONFIG) that points to the given cluster: the
# cluster= line of the state expects this context, not "devzone" (services cluster)
host_context_of_cluster() {
    local cluster="$1" host ctx
    host="${DEVZONE_KUBE_HOST:-$HOME/.kube/hote.config}"
    while IFS= read -r ctx; do
        [ -n "$ctx" ] || continue
        # The "devzone" context is set on the services cluster: we look for the
        # host context that points to it
        [ "$ctx" = devzone ] && continue
        if [ "$(KUBECONFIG="$host" kubectl config view -o jsonpath="{.contexts[?(@.name==\"$ctx\")].context.cluster}" 2>/dev/null || true)" = "$cluster" ]; then
            echo "$ctx"
            return 0
        fi
    done < <(KUBECONFIG="$host" kubectl config get-contexts -o name 2>/dev/null)
    return 1
}

# State missing without backup copy (#417, step 3): rebuilt from the namespaces
# labelled devzone of the services cluster (module on if its namespace exists,
# cluster= of the devzone context); returns 1 otherwise.
state_rebuild() {
    local namespaces m v stage seen=0 code=0 cluster_ctx cluster_host label
    label="${CLUSTER_LABEL:-app.kubernetes.io/managed-by=devzone}"
    command -v kubectl >/dev/null 2>&1 || return 1
    namespaces="$(kubectl get namespaces -l "$label" -o name 2>/dev/null || true)"
    [ -n "$namespaces" ] || return 1
    stage="$(mktemp)" || return 1
    for m in "$@"; do
        v=off
        printf '%s\n' "$namespaces" | grep -qx "namespace/devzone-$m" && { v=on; seen=1; }
        printf '%s=%s\n' "$m" "$v" >>"$stage" || code=1
    done
    # devzone context -> services cluster; the cluster= expects the real host
    # context that points to it (e.g. docker-desktop). Without host: no line.
    cluster_ctx="$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"devzone\")].context.cluster}" 2>/dev/null || true)"
    cluster_host=""
    if [ -n "$cluster_ctx" ]; then
        cluster_host="$(host_context_of_cluster "$cluster_ctx")"
        if [ -n "$cluster_host" ]; then
            printf 'cluster=%s\n' "$cluster_host" >>"$stage" || code=1
        fi
    fi
    if [ "$code" -eq 0 ] && [ "$seen" -eq 1 ] && state_replace "$stage"; then
        echo "devzone : state rebuilt from the namespaces of the services cluster: $ETAT (confirm with devzone apply)" >&2
        [ -n "$cluster_host" ] || echo "devzone : no host context points to the services cluster: no cluster= line in $ETAT" >&2
        rm -f "$stage"
        return 0
    fi
    rm -f "$stage"
    return 1
}

# First start (no state): former global state taken over once, otherwise backup
# copy restored, otherwise state rebuilt, otherwise everything disabled
state_init() {
    [ -f "$ETAT" ] && return 0

    # Migration: former global state (~/.config/devzone/modules) to the state of
    # the instance; moved, not copied: the first devzone started after the update
    # keeps its choices
    if [ -f "$HOME/.config/devzone/modules" ]; then
        if state_replace "$HOME/.config/devzone/modules"; then
            rm -f "$HOME/.config/devzone/modules"
            return 0
        fi
    fi

    state_lock_take || return 1
    if [ -f "$ETAT" ]; then
        state_lock_release
        return 0
    fi
    # 1. Backup copy left by the last write (#417)
    if [ -f "${ETAT}.prec" ] && state_replace "${ETAT}.prec"; then
        echo "devzone : state restored from the backup copy: $ETAT (confirm with devzone apply)" >&2
        state_recovery_mark
        state_lock_release
        return 0
    fi
    # 2. Rebuild from the services cluster (#417)
    if state_rebuild "$@"; then
        state_recovery_mark
        state_lock_release
        return 0
    fi
    # 3. First installation: everything disabled (#417)
    if ! state_default; then
        state_lock_release
        return 1
    fi
    state_lock_release
    # Connection already set up by another devzone (shared volumes): reported
    # once, when the state of this instance is created; stderr: init is also
    # called inside $(value …)
    if [ -f "$HOME/.claude/.credentials.json" ] || [ -f "$HOME/.local/share/opencode/auth.json" ]; then
        echo "devzone : shared Claude Code/opencode connection found: devzone enable ai to use it here" >&2
    fi
    return 0
}
