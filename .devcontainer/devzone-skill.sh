#!/usr/bin/env bash
# shellcheck shell=bash
# devzone, ai module: the devzone skill of the assistants.
# Sourced by .devcontainer/devzone (split of the 1 600 lines file, #722):
# functions only, shared variables are defined in devzone.


# Skill marker: the file is installed if missing, updated while it carries the
# marker and is unchanged, kept if customised (#161, opencode rule). The marker
# text is the one written in SKILL.md: it is kept as is.
SKILL_MARKER='<!-- devzone : skill set by devzone enable ia -->'
# Fingerprint of the installed version, next to SKILL.md: it tells an unchanged
# skill from a customised one that still carries the marker.
SKILL_FINGERPRINT='.devzone-empreinte'

# True if the file carries the devzone marker
has_skill_marker() { grep -qF -e "$SKILL_MARKER" "$1"; }

# Folders of the devzone skill, in the volumes of Claude Code and opencode.
skill_dirs() {
    echo "$HOME/.claude/skills/devzone"
    echo "$HOME/.config/opencode/skills/devzone"
}

# sha256 sum of a file (sha256sum on Linux, shasum on macOS).
skill_checksum() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# True if the target skill is still the installed one: recorded fingerprint,
# or else content identical to the model.
skill_unchanged() {
    local target="$1" fingerprint="$2" model="$3"
    if [ -n "$fingerprint" ]; then
        [ "$(skill_checksum "$target")" = "$fingerprint" ]
    else
        cmp -s "$model" "$target"
    fi
}

# Installs the devzone skill (versioned model): written if missing, updated
# while it keeps the marker and the installed fingerprint, kept if customised.
install_devzone_skill() {
    local model="$ICI/skills/devzone/SKILL.md" target d fingerprint
    for d in $(skill_dirs); do
        mkdir -p "$d"
        target="$d/SKILL.md"
        if [ ! -f "$target" ]; then
            cp "$model" "$target"
            skill_checksum "$target" >"$d/$SKILL_FINGERPRINT"
            echo "devzone : devzone skill installed in $d"
            continue
        fi
        fingerprint=""
        if [ -f "$d/$SKILL_FINGERPRINT" ]; then
            fingerprint="$(cat "$d/$SKILL_FINGERPRINT")"
        fi
        if has_skill_marker "$target" && skill_unchanged "$target" "$fingerprint" "$model"; then
            if ! cmp -s "$model" "$target"; then
                cp "$model" "$target"
                echo "devzone : devzone skill updated in $d"
            fi
            skill_checksum "$target" >"$d/$SKILL_FINGERPRINT"
        else
            echo "devzone : customised devzone skill in $d, kept"
        fi
    done
}

# Removes the devzone skill written by devzone if it still carries its marker
# and was not changed; a customised skill is kept. Symmetrical with
# install_devzone_skill.
remove_devzone_skill() {
    local model target d fingerprint
    model="$ICI/skills/devzone/SKILL.md"
    for d in $(skill_dirs); do
        target="$d/SKILL.md"
        if [ ! -f "$target" ]; then
            rm -f "$d/$SKILL_FINGERPRINT"
            continue
        fi
        fingerprint=""
        if [ -f "$d/$SKILL_FINGERPRINT" ]; then
            fingerprint="$(cat "$d/$SKILL_FINGERPRINT")"
        fi
        if has_skill_marker "$target" && skill_unchanged "$target" "$fingerprint" "$model"; then
            rm -f "$target" "$d/$SKILL_FINGERPRINT"
            echo "devzone : devzone skill removed from $d"
        else
            echo "devzone : customised devzone skill in $d, kept"
        fi
    done
}
