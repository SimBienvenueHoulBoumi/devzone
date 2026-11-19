#!/usr/bin/env bash
# Manifest of a devzone (.devzone.version) and the paths read back from it:
# checksum of each copied file, safe relative paths, the .gitignore lines of a
# devzone. Sourced by manage/devzone (update and create), which defines PAQUET
# (package folder), PACKAGE_ITEMS, GITIGNORE_LINES and version().
# shellcheck disable=SC2154 # PAQUET, PACKAGE_ITEMS, GITIGNORE_LINES: set by manage/devzone

# SHA-256 checksum of a file, computed by node (portable: macOS, Linux, Windows
# Git Bash); the path is passed as an argument, as for version()
checksum() {
    node -e 'const fs = require("fs"), crypto = require("crypto"); const h = crypto.createHash("sha256"); h.update(fs.readFileSync(process.argv[1])); process.stdout.write(h.digest("hex"))' "$1"
}

# Files of the package copied into a devzone, absolute paths
package_files() {
    local base
    for base in "${PACKAGE_ITEMS[@]}"; do
        if [ -d "$PAQUET/$base" ]; then
            find "$PAQUET/$base" -type f -print
        elif [ -f "$PAQUET/$base" ]; then
            printf '%s\n' "$PAQUET/$base"
        fi
    done
    if [ -d "$PAQUET/manage/scripts" ]; then
        find "$PAQUET/manage/scripts" -type f -print
    fi
}

# The same files, relative to the package, sorted
relative_package_files() {
    local f
    package_files | while IFS= read -r f; do
        printf '%s\n' "${f#"$PAQUET"/}"
    done | LC_ALL=C sort
}

# .devzone.version: version of the folder, then one checksum per copied file
write_manifest() {
    local folder="$1" rel
    {
        printf 'version %s\n' "$(version)"
        relative_package_files | while IFS= read -r rel; do
            printf '%s  %s\n' "$(checksum "$folder/$rel")" "$rel"
        done
    } >"$folder/.devzone.version"
}

# Version written in the manifest of a folder, 'inconnue' when there is none
folder_version() {
    local folder="${1:-.}" v
    if [ -f "$folder/.devzone.version" ]; then
        v="$(sed -n '1s/^version //p' "$folder/.devzone.version" 2>/dev/null | head -1 || true)"
        if [ -n "$v" ]; then
            printf '%s\n' "$v"
            return 0
        fi
    fi
    printf 'inconnue\n'
}

# Checksum recorded in the manifest of a folder for one path; fails if absent
manifest_checksum() {
    local folder="$1" target="$2" line h p
    [ -f "$folder/.devzone.version" ] || return 1
    while IFS= read -r line; do
        case "$line" in
            version\ * | '') continue ;;
        esac
        h="${line%%  *}"
        p="${line#*  }"
        if [ "$p" = "$target" ]; then
            printf '%s\n' "$h"
            return 0
        fi
    done <"$folder/.devzone.version"
    return 1
}

# Paths listed in the manifest of a folder
manifest_files() {
    local folder="$1" line
    [ -f "$folder/.devzone.version" ] || return 0
    while IFS= read -r line; do
        case "$line" in
            version\ * | '') continue ;;
        esac
        printf '%s\n' "${line#*  }"
    done <"$folder/.devzone.version"
}

# A path read from the manifest is accepted only if it is relative and simple
# (no '..', '.', '//', newline or tab), under a folder managed by the package
# or a file at its root. Otherwise it is refused.
path_allowed() {
    local rel="$1"
    case "$rel" in
        '' | /* | *//* | *$'\n'* | *$'\t'*) return 1 ;;
    esac
    case "/$rel/" in
        */../* | */./*) return 1 ;;
    esac
    case "$rel" in
        .devcontainer/* | manage/* | core/* | scripts/* | \
            Makefile | README.md | LICENSE | .gitattributes) return 0 ;;
    esac
    return 1
}

# Defense in depth: the real parent folder must stay under the real devzone
# folder (pwd -P), so a symbolic link leading out of it is refused.
inside_folder() {
    local folder="$1" rel="$2" root parent
    root="$(cd "$folder" && pwd -P)" || return 1
    parent="$(cd "$folder/$(dirname "$rel")" 2>/dev/null && pwd -P)" || return 1
    case "$parent" in
        "$root" | "$root"/*) return 0 ;;
    esac
    return 1
}

# Never touched by update, even when an old manifest lists them
is_protected() {
    case "$1" in
        workspace | workspace/* | .devzone.version | .devzone.modules | .devzone.modules-* | \
            .devzone.paquets | .password | .app | .devzone.log | .git | .git/*) return 0 ;;
    esac
    return 1
}

# True when the whole line $2 is in the file $1
in_list() {
    grep -Fqx -- "$2" "$1"
}

# Old devzone layout (before manage/): core/ is recognized only by its marker
# files, scripts/ only by its two own files. Otherwise it is a folder of the
# user: never touched.
old_tree() {
    local folder="$1" tree="$2"
    case "$tree" in
        core)
            [ -f "$folder/core/devzone" ] || [ -f "$folder/core/scripts/desinstaller.sh" ]
            ;;
        scripts)
            [ -f "$folder/scripts/desinstaller.sh" ] && [ -f "$folder/scripts/lancer.sh" ]
            ;;
        *) return 1 ;;
    esac
}

# File known from the old package: the names of manage/scripts/ moved into
# core/scripts/ or scripts/, core/devzone, and all of core/test/ and core/docs/.
known_old_file() {
    local rel="$1" name
    case "$rel" in
        core/devzone | core/test/* | core/docs/*) return 0 ;;
        core/scripts/*) name="${rel#core/scripts/}" ;;
        scripts/*) name="${rel#scripts/}" ;;
        *) return 1 ;;
    esac
    [ -f "$PAQUET/manage/scripts/$name" ]
}

# Adds the missing lines of GITIGNORE_LINES to the .gitignore of a folder
complete_gitignore() {
    local folder="$1" line
    touch "$folder/.gitignore"
    for line in "${GITIGNORE_LINES[@]}"; do
        grep -qxF -- "$line" "$folder/.gitignore" || printf '%s\n' "$line" >>"$folder/.gitignore"
    done
}
