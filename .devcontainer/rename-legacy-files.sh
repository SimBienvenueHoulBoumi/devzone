#!/usr/bin/env bash
# shellcheck shell=bash
# Renames the files and folders that devzone wrote under their former French
# names to their English names (#733, lot 3), and the state key plateforme= to
# platform= (lot 4). Called by the pod startup, by the workspace init, and on the
# workstation by devzone update and workspace update.
# Idempotent: a name is renamed only when the old one exists and the new one
# does not, so a second run does nothing. An existing new name is never
# overwritten. One line per rename on stdout, exit 0. No alias of the old names
# is kept after this migration. bash 3.2 (macOS).
#   DEVZONE_ROOT   devzone folder (default: the parent of this .devcontainer)
#   DEVZONE_TMP_DIR temporary folder (default: /tmp), set by the tests

ROOT="${DEVZONE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP_DIR="${DEVZONE_TMP_DIR:-/tmp}"

# rename_legacy OLD NEW: moves OLD to NEW when OLD exists and NEW does not.
# A conflict is reported on stderr and both names are left as they are.
rename_legacy() {
    local old="$1" new="$2"
    if [ ! -e "$old" ] && [ ! -L "$old" ]; then
        return 0
    fi
    if [ -e "$new" ] || [ -L "$new" ]; then
        echo "devzone : $old kept, $new already exists" >&2
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
}

# Fingerprint of the devzone skill, next to its SKILL.md in each assistant folder
migrate_skills() {
    local d
    [ -n "${HOME:-}" ] || return 0
    for d in "$HOME/.claude/skills/devzone" "$HOME/.config/opencode/skills/devzone"; do
        rename_legacy "$d/.devzone-empreinte" "$d/.devzone-fingerprint"
    done
}

# Markers written in the temporary folder by the relay and the packages check
migrate_tmp() {
    rename_legacy "$TMP_DIR/devzone-relais-docker.echec" "$TMP_DIR/devzone-relay.failed"
    rename_legacy "$TMP_DIR/devzone-paquets.echec" "$TMP_DIR/devzone-packages.failed"
}

# Key of the state file (#733, lot 4): the line plateforme=<v> becomes
# platform=<v>. When a platform= line is already there, only the old line goes.
# The file is rewritten in a temporary file, then moved over it; the other
# lines are copied as they are. A file without the old key is left alone.
migrate_state_keys() {
    local f="$ROOT/.devzone.modules" tmp="$ROOT/.devzone.modules.tmp.$$"
    [ -f "$f" ] || return 0
    grep -q '^plateforme=' "$f" || return 0
    if grep -q '^platform=' "$f"; then
        sed '/^plateforme=/d' "$f" >"$tmp"
    else
        sed 's/^plateforme=/platform=/' "$f" >"$tmp"
    fi || {
        rm -f "$tmp"
        echo "devzone : plateforme= not renamed to platform=" >&2
        return 0
    }
    if mv -- "$tmp" "$f"; then
        echo "devzone : plateforme= renamed to platform="
    else
        rm -f "$tmp"
        echo "devzone : plateforme= not renamed to platform=" >&2
    fi
    return 0
}

migrate_root
migrate_skills
migrate_tmp
migrate_state_keys
exit 0
