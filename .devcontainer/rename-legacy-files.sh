#!/usr/bin/env bash
# shellcheck shell=bash
# Renames the files and folders that devzone wrote under their former French
# names to their English names (#733, lot 3), and the state keys plateforme= to
# platform= (lot 4) and ia= to ai= (#774, lot 3). #774, lot 4 adds the folders of the
# port watcher, the state backup, the AI measures file and the packages marker.
# #774, lot 5 adds the ports folder cap, the key ports_exclus=, the state files of
# the port automation, the locks of the agent, of the catalog watcher and of the
# state (rename-legacy-ports.sh).
# Called by the pod startup, by the workspace init, and on the
# workstation by devzone update and workspace update.
# Idempotent: a name is renamed only when the old one exists and the new one
# does not, so a second run does nothing. Two folders with both names are
# merged, the old one emptied and removed. An existing file is never
# overwritten. One line per rename or merge on stdout, exit 0. No alias of the
# old names is kept after this migration. bash 3.2 (macOS).
#   DEVZONE_ROOT   devzone folder (default: the parent of this .devcontainer)
#   DEVZONE_TMP_DIR temporary folder (default: /tmp), set by the tests
#   DEVZONE_PORTS_AUTO_DIR, DEVZONE_AGENT_STATE  state folders of the port automation
#   and of the agent (defaults: devzone-ports-auto of the temporary folder, ~/.local/state/oc-lancer)

ROOT="${DEVZONE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP_DIR="${DEVZONE_TMP_DIR:-/tmp}"

# is_real_dir PATH: true for a folder that is not a symbolic link
is_real_dir() {
    [ -d "$1" ] && [ ! -L "$1" ]
}

# merge_legacy OLD NEW: both are folders. Each entry of OLD that NEW does not
# have is moved into NEW; an entry present on both sides is never overwritten,
# it stays in OLD and a message on stderr names it. OLD is removed (rmdir) only
# when it is left empty, and then the merge is announced on stdout. Hidden
# entries are merged too. The shell options live in a subshell, so they do not
# reach the other migrations.
merge_legacy() {
    local old="$1" new="$2"
    (
        shopt -s dotglob nullglob
        local entry target
        for entry in "$old"/*; do
            target="$new/${entry##*/}"
            if [ -e "$target" ] || [ -L "$target" ]; then
                echo "devzone : $entry kept: $target already exists" >&2
            elif ! mv -- "$entry" "$target"; then
                echo "devzone : $entry not merged into $target" >&2
            fi
        done
        if rmdir -- "$old" 2>/dev/null; then
            echo "devzone : $old merged into $new"
        fi
    )
    return 0
}

# rename_legacy OLD NEW: moves OLD to NEW when OLD exists and NEW does not.
# When both are folders, they are merged (see merge_legacy). Any other conflict
# is reported on stderr and both names are left as they are.
rename_legacy() {
    local old="$1" new="$2"
    if [ ! -e "$old" ] && [ ! -L "$old" ]; then
        return 0
    fi
    if [ -e "$new" ] || [ -L "$new" ]; then
        if is_real_dir "$old" && is_real_dir "$new"; then
            merge_legacy "$old" "$new"
        else
            echo "devzone : $old kept, $new already exists" >&2
        fi
        return 0
    fi
    if mv -- "$old" "$new"; then
        echo "devzone : $old renamed to $new"
    else
        echo "devzone : $old not renamed to $new" >&2
    fi
    return 0
}

# Failure markers of the modules: .devzone.modules-echec-<module> becomes
# .devzone.modules-failed-<module>, one rename per marker found
migrate_markers() {
    local f base
    for f in "$ROOT"/.devzone.modules-echec-*; do
        if [ ! -e "$f" ] && [ ! -L "$f" ]; then
            continue
        fi
        base="${f##*/}"
        rename_legacy "$f" "$ROOT/.devzone.modules-failed-${base#.devzone.modules-echec-}"
    done
}

# Folders and files of the devzone folder
migrate_root() {
    rename_legacy "$ROOT/.devzone.paquets" "$ROOT/.devzone.packages"
    rename_legacy "$ROOT/.devzone.sauvegarde" "$ROOT/.devzone.backup"
    rename_legacy "$ROOT/.devzone.ports-workspace" "$ROOT/.devzone.workspace-ports"
    rename_legacy "$ROOT/.devzone.etat" "$ROOT/.devzone.state"
    rename_legacy "$ROOT/.devzone.catalogue-veilleur" "$ROOT/.devzone.catalog-watcher"
    migrate_markers
    # Failure marker of the AI module, renamed with it (#774)
    rename_legacy "$ROOT/.devzone.modules-failed-ia" "$ROOT/.devzone.modules-failed-ai"
    # Backup of the previous state (#774, lot 4)
    rename_legacy "$ROOT/.devzone.modules.prec" "$ROOT/.devzone.modules.prev"
    migrate_ports
}

# Port watcher, locks and state files of the port automation (#774, lot 5)
# shellcheck source=SCRIPTDIR/rename-legacy-ports.sh
# shellcheck disable=SC1091
. "$(dirname "$0")/rename-legacy-ports.sh"

# Fingerprint of the devzone skill, next to its SKILL.md in each assistant folder
migrate_skills() {
    local d
    [ -n "${HOME:-}" ] || return 0
    for d in "$HOME/.claude/skills/devzone" "$HOME/.config/opencode/skills/devzone"; do
        rename_legacy "$d/.devzone-empreinte" "$d/.devzone-fingerprint"
    done
    # Measures of the host models (#774, lot 4); DEVZONE_AI_MEASURES points to
    # a file of the user, never renamed
    rename_legacy "$HOME/.config/devzone/ia-mesures.json" "$HOME/.config/devzone/ai-measures.json"
}

# Markers written in the temporary folder by the packages check
migrate_tmp() {
    rename_legacy "$TMP_DIR/devzone-paquets.echec" "$TMP_DIR/devzone-packages.failed"
    rename_legacy "$TMP_DIR/devzone-paquets.maj" "$TMP_DIR/devzone-packages.updated"
}

# Key of the state file: the line <old>=<v> becomes <new>=<v>. When a <new>=
# line is already there, only the old line goes. The file is rewritten in a
# temporary file, then moved over it; the other lines are copied as they are.
# A file without the old key is left alone.
migrate_state_key() {
    local old="$1" new="$2"
    local f="$ROOT/.devzone.modules" tmp="$ROOT/.devzone.modules.tmp.$$"
    [ -f "$f" ] || return 0
    grep -q "^$old=" "$f" || return 0
    if grep -q "^$new=" "$f"; then
        sed "/^$old=/d" "$f" >"$tmp"
    else
        sed "s/^$old=/$new=/" "$f" >"$tmp"
    fi || {
        rm -f "$tmp"
        echo "devzone : $old= not renamed to $new=" >&2
        return 0
    }
    if mv -- "$tmp" "$f"; then
        echo "devzone : $old= renamed to $new="
    else
        rm -f "$tmp"
        echo "devzone : $old= not renamed to $new=" >&2
    fi
    return 0
}

# Keys of the state file: plateforme= (#733, lot 4), ia= (#774, lot 3), ports_exclus= (#774, lot 5)
migrate_state_keys() {
    migrate_state_key plateforme platform
    migrate_state_key ia ai
    migrate_state_key ports_exclus excluded_ports
}

migrate_root
migrate_skills
migrate_tmp
migrate_ports_auto
migrate_agent_locks
migrate_state_lock
migrate_state_keys
exit 0
