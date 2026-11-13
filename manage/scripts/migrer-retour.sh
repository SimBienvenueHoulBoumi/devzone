#!/usr/bin/env bash
# Rollback from Kubernetes workspace to Docker workstation (#403): devzone workspace
# revert [--bring-back]. Sourced by manage/workspace.sh after migrer.sh (uses
# copy_from, record_workspace, fail and kc). With --bring-back, the workstation
# version of a project is moved to .devzone.sauvegarde/<date>/ before being replaced.

# Backup folder for this run (relative to devzone), same convention as
# devzone update: .devzone.sauvegarde/<YYYYMMDD-HHMMSS>, -n suffix if taken.
backup_folder() {
    local base folder n=1
    base=".devzone.sauvegarde/$(date +%Y%m%d-%H%M%S)"
    folder="$base"
    while [ -e "$folder" ]; do
        n=$((n + 1))
        folder="$base-$n"
    done
    printf '%s' "$folder"
}

# Brings project $1 back from the pod; its workstation version ($2: backup folder)
# is moved first. If the move fails, nothing is overwritten.
bring_back_project() {
    local p="$1" backup="$2"
    if [ -e "workspace/$p" ]; then
        if ! mkdir -p "$backup/workspace" || ! mv "workspace/$p" "$backup/workspace/$p"; then
            fail "backup of workspace/$p failed: nothing was overwritten"
            return 1
        fi
        echo "project $p: workstation version saved in $backup/"
    fi
    copy_from "$PWD/workspace/$p" || {
        fail "bring-back of $p failed (workstation version: $backup/workspace/$p)"
        return 1
    }
}

# devzone workspace revert [--bring-back]: workspace=docker; --bring-back copies projects from the pod first.
revert_workspace() {
    local bring_back p list backup
    bring_back="$(read_flag --bring-back "revert [--bring-back]" "$@")" || return 1
    if [ "$bring_back" = 1 ]; then
        echo "▶ bring-back: projects from pod to ./workspace (workstation version is saved first)"
        list="$(kc exec "$POD" -c workspace -- ls -1 "$PROJECTS_DIR")" || { fail "cannot read project list from pod"; return 1; }
        mkdir -p workspace
        backup="$(backup_folder)"
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            echo "  … $p"
            bring_back_project "$p" "$backup" || return 1
        done <<<"$list"
    fi
    record_workspace docker || { fail "cannot write .devzone.modules"; return 1; }
    echo "✔ workspace=docker: Docker workstation and its volumes are intact. Start it again: make shell"
}

# compatibility alias, removed with lot 4 (#509)
revenir() { revert_workspace "$@"; }
