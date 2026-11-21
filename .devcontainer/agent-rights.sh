#!/usr/bin/env bash
# Protects the rights files of the agents during a devzone agent session (#361).
# Library sourced by agent.sh: no command is launched here.

# Rights files, paths relative to the root of the working folder. Fixed list: no
# environment variable changes it, and an agent cannot add to it.
# agent-rights.sh is in it, otherwise an agent could empty the list.
RIGHTS_FILES=(
    .devcontainer/opencode/agent.json
    .devcontainer/opencode.jsonc
    .repowarden.conf
    .devcontainer/agent-rights.sh
)

# Snapshot directory of a project's rights files, in the agent state.
rights_dir() {
    echo "$AGENT_STATE/droits-$(basename "$1")"
}

# At launch: copies each rights file (or notes its absence) and the starting HEAD,
# then clears the alert of the previous session on this project.
rights_snapshot() {
    local d f
    d="$(rights_dir "$1")"
    rm -rf "$d" "$d.alerte"
    mkdir -p "$d/fichiers"
    : >"$d/absents"
    for f in "${RIGHTS_FILES[@]}"; do
        if [ -f "$1/$f" ]; then
            mkdir -p "$d/fichiers/$(dirname "$f")"
            cp -p "$1/$f" "$d/fichiers/$f"
        else
            echo "$f" >>"$d/absents"
        fi
    done
    git -C "$1" rev-parse HEAD >"$d/head" 2>/dev/null || : >"$d/head"
}

# Restores a rights file to its snapshot (removed when it did not exist).
rights_restore() {
    local d f
    d="$(rights_dir "$1")"
    f="$2"
    if grep -qxF "$f" "$d/absents"; then
        rm -f "$1/$f"
    else
        mkdir -p "$(dirname "$1/$f")"
        cp -p "$d/fichiers/$f" "$1/$f"
    fi
}

# After each opencode session: restores the modified files in the tree, reports in
# the journal any commit that touches them (history is never rewritten), raises the alert.
rights_verify() {
    local d f depart sha message
    d="$(rights_dir "$1")"
    [ -d "$d" ] || return 0
    depart="$(cat "$d/head" 2>/dev/null || true)"
    for f in "${RIGHTS_FILES[@]}"; do
        message=""
        if grep -qxF "$f" "$d/absents"; then
            if [ -e "$1/$f" ]; then message="change reverted"; fi
        elif ! cmp -s "$d/fichiers/$f" "$1/$f"; then
            message="change reverted"
        fi
        sha=""
        if [ -n "$depart" ]; then
            if [ -n "$(git -C "$1" diff --name-only "$depart" HEAD -- "$f" 2>/dev/null)" ]; then
                sha="$(git -C "$1" log -1 --format=%h "$depart..HEAD" -- "$f" 2>/dev/null || true)"
                message="change reverted in the tree, committed in ${sha:-HEAD}: remove this commit before any push"
            fi
        fi
        [ -n "$message" ] || continue
        rights_restore "$1" "$f"
        echo "=== ⚠ rights changed: $f : $message" >>"$AGENT_JOURNAL"
        echo "$f" >>"$d.alerte"
    done
    return 0
}

# For devzone agent state: one line per project whose rights were changed.
rights_alerts() {
    local f
    for f in "$AGENT_STATE"/droits-*.alerte; do
        [ -e "$f" ] || continue
        f="${f##*/droits-}"
        echo "  ⚠ rights changed (${f%.alerte}): see the journal"
    done
}
