#!/usr/bin/env bash
# shellcheck shell=bash
# devzone, ai module: the devzone skill of the assistants.
# Sourced by .devcontainer/devzone (split of the 1 600 lines file, #722):
# functions only, shared variables are defined in devzone.


# Repère de la skill devzone : posée si absente, mise à jour si elle porte le
# repère et n'a pas été modifiée, gardée si personnalisée (#161, règle opencode).
SKILL_REPERE='<!-- devzone : skill posée par devzone enable ia -->'
# Empreinte de la version posée, à côté de SKILL.md : elle distingue une skill
# non modifiée d'une skill personnalisée qui garde encore le repère.
SKILL_EMPREINTE='.devzone-empreinte'

# Dossiers de la skill devzone, dans les volumes de Claude Code et opencode.
skill_dossiers() {
    echo "$HOME/.claude/skills/devzone"
    echo "$HOME/.config/opencode/skills/devzone"
}

# Somme sha256 d'un fichier (sha256sum sous Linux, shasum sous macOS).
skill_somme() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# Vrai si la skill cible est encore celle posée : empreinte enregistrée, ou à
# défaut contenu identique au modèle.
skill_inchangee() {
    local cible="$1" empreinte="$2" modele="$3"
    if [ -n "$empreinte" ]; then
        [ "$(skill_somme "$cible")" = "$empreinte" ]
    else
        cmp -s "$modele" "$cible"
    fi
}

# Pose la skill devzone (modèle versionné) : écrite si absente, mise à jour
# tant qu'elle garde le repère et l'empreinte posée, gardée si personnalisée.
poser_skill_devzone() {
    local modele="$ICI/skills/devzone/SKILL.md" repere cible d empreinte
    repere="$SKILL_REPERE"
    for d in $(skill_dossiers); do
        mkdir -p "$d"
        cible="$d/SKILL.md"
        if [ ! -f "$cible" ]; then
            cp "$modele" "$cible"
            skill_somme "$cible" >"$d/$SKILL_EMPREINTE"
            echo "devzone : skill devzone posée dans $d"
            continue
        fi
        empreinte=""
        if [ -f "$d/$SKILL_EMPREINTE" ]; then
            empreinte="$(cat "$d/$SKILL_EMPREINTE")"
        fi
        if grep -qF "$repere" "$cible" && skill_inchangee "$cible" "$empreinte" "$modele"; then
            if ! cmp -s "$modele" "$cible"; then
                cp "$modele" "$cible"
                echo "devzone : skill devzone mise à jour dans $d"
            fi
            skill_somme "$cible" >"$d/$SKILL_EMPREINTE"
        else
            echo "devzone : skill devzone personnalisée dans $d, gardée"
        fi
    done
}

# Retire la skill devzone écrite par devzone si elle porte encore son repère
# et n'a pas été modifiée ; une skill personnalisée est gardée. Symétrique de
# poser_skill_devzone.
retirer_skill_devzone() {
    local repere modele cible d empreinte
    repere="$SKILL_REPERE"
    modele="$ICI/skills/devzone/SKILL.md"
    for d in $(skill_dossiers); do
        cible="$d/SKILL.md"
        if [ ! -f "$cible" ]; then
            rm -f "$d/$SKILL_EMPREINTE"
            continue
        fi
        empreinte=""
        if [ -f "$d/$SKILL_EMPREINTE" ]; then
            empreinte="$(cat "$d/$SKILL_EMPREINTE")"
        fi
        if grep -qF "$repere" "$cible" && skill_inchangee "$cible" "$empreinte" "$modele"; then
            rm -f "$cible" "$d/$SKILL_EMPREINTE"
            echo "devzone : skill devzone retirée de $d"
        else
            echo "devzone : skill devzone personnalisée dans $d, gardée"
        fi
    done
}
