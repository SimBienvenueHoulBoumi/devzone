#!/usr/bin/env bash
# shellcheck shell=bash
# devzone, repair of the workstation.
# Sourced by .devcontainer/devzone (split of the 1 600 lines file, #722):
# functions only, shared variables are defined in devzone.

# Lines "package pinned installed" of the outdated tools; fails if the versions.sh
# script is missing or cannot answer (the state then omits the line)
outdated_tools() {
    [ -f "$VERSIONS" ] || return 1
    bash "$VERSIONS" --installees 2>/dev/null
}

# Sets repowarden back to the pinned version if it differs, like post-create.sh
# (it installs the global git hooks)
apply_repowarden() {
    local line pinned installed package=repowarden
    [ -f "$VERSIONS" ] || return 0
    line="$(bash "$VERSIONS" --installees 2>/dev/null | awk '$1 == "repowarden"' || true)"
    [ -n "$line" ] || return 0
    read -r _ pinned installed <<<"$line"
    echo "devzone : installing repowarden ${pinned}…"
    npm install -g "$package@$pinned" >/dev/null
    repowarden install --global --lang fr
    echo "devzone : repowarden $installed → $pinned"
}

# Paths of the worktrees of the devzone repository and of the workspace
# repositories absent here: created on the other side (host), a git worktree
# prune would break them. Read-only: nothing is deleted or repaired.
missing_worktrees() {
    local repo line path
    {
        [ -e "$RACINE/.git" ] && echo "$RACINE"
        find "$RACINE/workspace" -mindepth 2 -maxdepth 3 -name .git -type d 2>/dev/null | sed 's|/\.git$||'
    } | while IFS= read -r repo; do
        { git -C "$repo" worktree list --porcelain 2>/dev/null || true; } | while IFS= read -r line; do
            case "$line" in
                "worktree "*)
                    path="${line#worktree }"
                    [ -d "$path" ] || echo "$path"
                    ;;
            esac
        done
    done || true
}

# Repair (#341): resumes the startup.sh sequence without the git identity nor
# the clusters. Each item is really repaired; ✔ or ✖ with the reason.
repair_item() {
    local name="$1" output code reason
    shift
    if output="$("$@" 2>&1)"; then
        echo "✔ $name"
    else
        code=$?
        reason="$(printf '%s\n' "$output" | sed '/^[[:space:]]*$/d' | tail -1)"
        [ -n "$reason" ] || reason="failed (code $code)"
        echo "✖ $name : $reason"
        repair_failed=1
    fi
}

# Application repairs (#341): active services, ports and credentials; a failure
# does not stop the following ones.
repair_workstation() {
    repair_failed=0
    # Limited Kubernetes account token (#430): 24 h, renewed here; without the
    # kubernetes module and without a services cluster, nothing to do
    if [ "$(value_of kubernetes)" = on ] || [ -n "$(cluster_saved)" ]; then
        repair_item "kubernetes account" devzone account token
    fi
    if [ "$(value_of gitlab)" = on ]; then
        repair_item "gitlab name" bash "$ICI/gitlab/gitlab.sh" hote-poser
        repair_item "gitlab relay" bash "$ICI/gitlab/gitlab.sh" relay-start
    fi
    if [ "$(value_of postgres)" = on ]; then
        repair_item "postgres relay" devzone postgres relay-start
    fi
    if [ "$(value_of argocd)" = on ]; then
        repair_item "argocd relay" bash "$ICI/argocd/argocd.sh" relay-start
    fi
    if [ "$(value_of mysql)" = on ]; then
        repair_item "mysql relay" devzone mysql relay-start
    fi
    repair_item "ports relay" bash "$ICI/ports.sh" restart
    # Kubernetes workspace (#517): no automatic port watcher
    if ! in_pod; then
        repair_item "ports auto watcher" env DEVZONE_PORTS_AUTO_REAL=yes bash "$ICI/ports-auto.sh" demarrer
    fi
    repair_item "catalog watcher" env DEVZONE_CATALOG_REAL=yes bash "$ICI/catalog/catalog-watcher.sh" demarrer
    repair_item "credentials" bash "$ICI/password.sh" regenerer
    devzone cluster clean || true
    return "$repair_failed"
}
