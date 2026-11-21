#!/usr/bin/env bash
# System packages kept after a rebuild (#351): a list in the devzone folder
# (<root>/.devzone.packages, a comment header + one package name per line, sorted,
# without duplicates), reinstalled at each container creation (post-create.sh).
# A package installed by hand is lost by a rebuild, unless it is in this list.
#   packages.sh or packages.sh list        list with the state of each package
#   packages.sh add <name>…                validates, installs, adds to the list
#   packages.sh remove <name>…             removes from the list and uninstalls (except image packages)
#   packages.sh apply                      installs everything missing (post-create.sh)
# The state of a package comes from dpkg-query -W -f='${Status}'; the system
# commands go through overridable variables for the tests (sudo, apt-get,
# apt-cache, dpkg-query, mark, timestamp). Compatible with bash 3.2 (macOS).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${DEVZONE_ROOT:-$(dirname "$HERE")}"
LIST="${ROOT}/.devzone.packages"
MARK="${DEVZONE_PACKAGES_MARKER:-/tmp/devzone-packages.failed}"
UPDATED="${DEVZONE_PACKAGES_UPDATE:-/tmp/devzone-packages.updated}"
SUDO="${DEVZONE_PACKAGES_SUDO-sudo}"
APT="${DEVZONE_PACKAGES_APT:-apt-get}"
APTCACHE="${DEVZONE_PACKAGES_APTCACHE:-apt-cache}"
DPKGQUERY="${DEVZONE_PACKAGES_DPKG_QUERY:-dpkg-query}"
FORMAT="-f=\${Status}"
# Stored values, kept byte for byte (the users' list file): the header and the
# « already present » mark are written in UTF-8 as byte escapes (contract).
HEADER=$'# paquets ajout\303\251s par devzone packages add ; r\303\251install\303\251s \303\240 chaque cr\303\251ation du conteneur'
PRESENT_MARK=$'# d\303\251j\303\240 pr\303\251sent'


refuse() { echo "devzone : packages : $*" >&2; exit 1; }

as_root() {
    if [ -n "$SUDO" ]; then
        "$SUDO" "$@"
    else
        env "$@"
    fi
}

is_installed() {
    "$DPKGQUERY" -W "$FORMAT" "$1" 2>/dev/null | grep -q 'install ok installed'
}

# List lines as they are (name, or name followed by the present mark).
list_lines() {
    [ -f "$LIST" ] || return 0
    grep -vE '^[[:space:]]*(#|$)' "$LIST" 2>/dev/null |
        sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' |
        sort -k1,1 -u || true
}

# Names only: the end-of-line mark is ignored.
list_names() {
    list_lines | sed -e 's/[[:space:]]*#.*$//' | sort -u || true
}

name_listed() {
    local name
    while IFS= read -r name; do
        [ "$name" = "$1" ] && return 0
    done < <(list_names)
    return 1
}

# True if the package was marked as already present in the image.
mark_present() {
    grep -qxF -e "$1 $PRESENT_MARK" "$LIST" 2>/dev/null
}

# Rewrites the list: a single header, then the given lines (sorted by name).
write_list() {
    local tmp
    tmp="$(mktemp)"
    {
        echo "$HEADER"
        [ "$#" -eq 0 ] || printf '%s\n' "$@" | sort -k1,1 -u
    } >"$tmp"
    mv "$tmp" "$LIST"
}

update_index() {
    local last
    last="$(cat "$UPDATED" 2>/dev/null || true)"
    if [ -n "$last" ] && [ $(( $(date +%s) - last )) -lt 3600 ]; then
        return 0
    fi
    as_root "$APT" update || return 1
    date +%s >"$UPDATED"
}

list_packages() {
    local packages package
    packages="$(list_names)"
    if [ -z "$packages" ]; then
        echo "no package (devzone packages add <name>)"
        return 0
    fi
    while IFS= read -r package; do
        [ -n "$package" ] || continue
        if is_installed "$package"; then
            echo "  ✔ $package"
        else
            echo "  ○ $package"
        fi
    done < <(printf '%s\n' "$packages")
}

add_packages() {
    local -a a=()
    local -a entries=()
    local arg name line already=""
    for arg in "$@"; do
        case "$arg" in
            -*) refuse "unknown argument: $arg (devzone packages add <name>…)" ;;
            *) a+=("$arg") ;;
        esac
    done
    [ "${#a[@]}" -gt 0 ] || refuse "add expects at least one name: devzone packages add <name>…"
    update_index || echo "apt index not updated" >&2
    for name in "${a[@]}"; do
        if ! "$APTCACHE" show "$name" >/dev/null 2>&1; then
            refuse "unknown package: $name (list unchanged)"
        fi
    done
    # What is already installed before the installation comes from the image: marked
    for name in "${a[@]}"; do
        if is_installed "$name"; then
            already="$already $name"
        fi
    done
    if as_root DEBIAN_FRONTEND=noninteractive "$APT" install -y --no-install-recommends "${a[@]}"; then
        while IFS= read -r line; do
            entries+=("$line")
        done < <(list_lines)
        for name in "${a[@]}"; do
            if name_listed "$name"; then
                continue
            fi
            case " $already " in
                *" $name "*)
                    entries+=("$name $PRESENT_MARK")
                    echo "$name : already present before devzone packages (marked ; removing will leave it installed)"
                    ;;
                *) entries+=("$name") ;;
            esac
        done
        write_list "${entries[@]}"
    else
        refuse "installation failed: ${a[*]} (list unchanged)"
    fi
}

remove_packages() {
    local -a a=()
    local -a removals=()
    local -a remaining=()
    local arg name line name_line
    for arg in "$@"; do
        case "$arg" in
            -*) refuse "unknown argument: $arg (devzone packages remove <name>…)" ;;
            *) a+=("$arg") ;;
        esac
    done
    [ "${#a[@]}" -gt 0 ] || refuse "remove expects at least one name: devzone packages remove <name>…"
    for name in "${a[@]}"; do
        name_listed "$name" ||
            refuse "package not listed: $name (provided by the image?) : devzone packages remove does not add image packages"
        if ! mark_present "$name"; then
            removals+=("$name")
        fi
    done
    if [ "${#removals[@]}" -gt 0 ] && ! as_root "$APT" remove -y "${removals[@]}"; then
        refuse "removal failed: ${removals[*]} (list unchanged)"
    fi
    for name in "${a[@]}"; do
        if mark_present "$name"; then
            echo "$name : removed from the list, left installed (present before devzone packages)"
        fi
    done
    while IFS= read -r line; do
        name_line="${line%% *}"
        case " ${a[*]} " in
            *" $name_line "*) ;;
            *) remaining+=("$line") ;;
        esac
    done < <(list_lines)
    write_list "${remaining[@]+"${remaining[@]}"}"
}

apply_packages() {
    local package
    local -a missing=()
    while IFS= read -r package; do
        [ -n "$package" ] || continue
        if ! is_installed "$package"; then
            missing+=("$package")
        fi
    done < <(printf '%s\n' "$(list_names)")
    if [ "${#missing[@]}" -eq 0 ]; then
        rm -f "$MARK"
        return 0
    fi
    update_index || echo "apt index not updated" >&2
    for package in "${missing[@]}"; do
        as_root DEBIAN_FRONTEND=noninteractive "$APT" install -y --no-install-recommends "$package" || true
    done
    local -a still_missing=()
    for package in "${missing[@]}"; do
        if ! is_installed "$package"; then
            still_missing+=("$package")
        fi
    done
    if [ "${#still_missing[@]}" -gt 0 ]; then
        printf '%s\n' "${still_missing[@]}" >"$MARK"
        return 1
    fi
    rm -f "$MARK"
}

case "${1:-}" in
    '' | list) list_packages ;;
    add) add_packages "${@:2}" ;;
    remove) remove_packages "${@:2}" ;;
    apply) apply_packages ;;
    -h | --help | aide) awk 'NR==1{next} /^#$/{exit} /^#/{sub(/^# ?/,""); print; next} {exit}' "${BASH_SOURCE[0]}" ;;
    *) refuse "unknown command: ${1:-(none)} (devzone packages --help)" ;;
esac
