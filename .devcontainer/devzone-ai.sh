#!/usr/bin/env bash
# shellcheck shell=bash
# devzone, ai module: opencode config, assistants install, apply.
# Sourced by .devcontainer/devzone (split of the 1 600 lines file, #722):
# functions only, shared variables are defined in devzone.

# Configuration opencode par défaut (modèle versionné) : écrite au premier
# usage, mise à jour tant qu'elle garde le repère devzone, personnalisée sinon.
config_opencode() {
    local modele="$ICI/opencode.jsonc" repere cible
    repere='// devzone : configuration opencode par défaut'
    if [ -f "$HOME/.config/opencode/opencode.jsonc" ]; then
        cible="$HOME/.config/opencode/opencode.jsonc"
    elif [ -f "$HOME/.config/opencode/opencode.json" ]; then
        cible="$HOME/.config/opencode/opencode.json"
    else
        cible="$HOME/.config/opencode/opencode.jsonc"
    fi
    mkdir -p "$(dirname "$cible")"
    if [ ! -f "$cible" ]; then
        cp "$modele" "$cible"
        echo "opencode : configuration par défaut écrite"
    elif grep -qF "$repere" "$cible"; then
        if ! cmp -s "$modele" "$cible"; then
            cp "$modele" "$cible"
            echo "opencode : configuration par défaut mise à jour"
        fi
    elif contient_seulement_schema "$cible"; then
        cp "$modele" "$cible"
        echo "opencode : configuration par défaut mise à jour"
    else
        echo "opencode : configuration personnalisée, gardée"
    fi
}

# Retire la configuration opencode écrite par devzone si elle porte encore son
# repère et n'a pas été modifiée ; une config personnalisée (sans repère ou
# modifiée) est gardée. Symétrique de config_opencode.
retirer_config_opencode() {
    local repere modele cible
    repere='// devzone : configuration opencode par défaut'
    modele="$ICI/opencode.jsonc"
    if [ -f "$HOME/.config/opencode/opencode.jsonc" ]; then
        cible="$HOME/.config/opencode/opencode.jsonc"
    elif [ -f "$HOME/.config/opencode/opencode.json" ]; then
        cible="$HOME/.config/opencode/opencode.json"
    else
        return 0
    fi
    if grep -qF "$repere" "$cible" && cmp -s "$modele" "$cible"; then
        rm -f "$cible"
        echo "opencode : configuration par défaut retirée"
    else
        echo "opencode : configuration personnalisée, gardée"
    fi
}

# Journal du dernier npm (son chemin est à donner en cas d'échec), ou son
# dossier ; noms horodatés : le dernier dans l'ordre du glob est le plus récent
dernier_journal_npm() {
    local journal="" f
    for f in "$HOME"/.npm/_logs/*-debug-0.log; do
        if [ -f "$f" ]; then journal="$f"; fi
    done
    echo "${journal:-$HOME/.npm/_logs}"
}

# Installs each pinned AI assistant with its own npm command (3 tries each),
# then checks its binary: npm silently drops a platform binary it failed to
# download (#194), and one assistant failing must not block the other.
installer_ia() {
    local package binary attempt
    IA_FAILED=()
    for package in "${IA_PAQUETS[@]}"; do
        case "$package" in
            opencode-ai@*) binary=opencode ;;
            *) binary=claude ;;
        esac
        for attempt in 1 2 3; do
            if avec_progression npm install -g --no-fund --no-audit --loglevel=error "$package" >/dev/null &&
                "$binary" --version >/dev/null 2>&1; then
                break
            fi
            if [ "$attempt" -lt 3 ]; then
                echo "devzone : installation de ${package%@*} incomplète, nouvel essai ($((attempt + 1))/3)…" >&2
            else
                IA_FAILED+=("$package")
            fi
        done
    done
    [ "${#IA_FAILED[@]}" -eq 0 ]
}

appliquer_ia() {
    local journal tmp detectes
    if [ "$1" = on ]; then
        echo "devzone : installation de Claude Code et opencode (quelques minutes)…"
        if ! installer_ia; then
            journal="$(dernier_journal_npm)"
            echo "journal npm : $journal" >"$(fichier_echec ia)"
            echo "devzone : échec de l'installation de ${IA_FAILED[*]} (npm install -g, 3 essais) ; journal npm : $journal ; réessayer : devzone apply" >&2
            return 1
        fi
        rm -f "$(fichier_echec ia)"
        echo "devzone : Claude Code et opencode installés"
        # Garde-fou repowarden (hook PreToolUse de Claude Code, plugin opencode) :
        # agent arrêté avant de modifier main/develop, de commiter sans
        # repowarden cc ou de contourner les hooks. Global, dans les volumes
        # ~/.claude et ~/.config/opencode : gardé aux rebuilds ; relancé, rien ne change
        if command -v repowarden >/dev/null 2>&1 && repowarden agents init --global >/dev/null 2>&1; then
            echo "devzone : garde-fou repowarden actif pour Claude Code et opencode"
        else
            echo "devzone : garde-fou repowarden non branché (repowarden 4.10 ou plus requis) : repowarden agents init --global" >&2
        fi
        poser_garde_docker
        config_opencode
        # Remove the provider of the removed llm module from old configs (#669).
        if [ -f "$HOME/.config/opencode/config.json" ] && command -v jq >/dev/null 2>&1; then
            tmp="$(mktemp)"
            if jq '
                if .provider then del(.provider["devzone-llm"]) | (if .provider == {} then del(.provider) else . end) else . end
            ' "$HOME/.config/opencode/config.json" >"$tmp" 2>/dev/null; then
                if [ "$(cat "$tmp")" = "{}" ] || [ "$(jq -c 'del(."$schema") | length' "$tmp" 2>/dev/null)" = 0 ]; then
                    rm -f "$tmp" "$HOME/.config/opencode/config.json"
                else
                    mv "$tmp" "$HOME/.config/opencode/config.json"
                fi
            else
                rm -f "$tmp"
            fi
        fi
        # Provider opencode des modèles de l'hôte (Ollama), détection à chaud :
        # silencieux et sans effet si Ollama ne répond pas.
        set_provider || true
        # Signale l'état de la détection (succès dans les deux cas).
        detectes="$(modeles 2>/dev/null || true)"
        if [ -n "$detectes" ]; then
            printf "devzone : %s modèle(s) de l'hôte (Ollama) branché(s)\n" "$(printf '%s\n' "$detectes" | grep -c .)"
        else
            printf "devzone : aucun modèle Ollama détecté sur %s (modèles de l'hôte non branchés)\n" "$URL"
        fi
        # Skill devzone : posée si absente, mise à jour si inchangée, gardée si personnalisée.
        poser_skill_devzone
        echo "devzone : ia actif : claude (puis /login), opencode auth login"
    else
        npm uninstall -g "${IA_NOMS[@]}" >/dev/null 2>&1 || true
        rm -f "$(fichier_echec ia)"
        # Garde-fou repowarden : retiré à la désactivation (symétrique de
        # l'activation). repowarden le fait lui-même s'il est présent ; sinon
        # retrait par jq des seules entrées PreToolUse qui appellent le garde-fou,
        # le reste de settings.json intact. Le garde-fou s'appelle « repowarden
        # guard » depuis repowarden 4.17.3 ; « repowarden garde » est son ancien
        # nom, toujours alias côté repowarden et reconnu ici.
        if command -v repowarden >/dev/null 2>&1; then
            repowarden agents retirer --global >/dev/null 2>&1 || true
        elif [ -f "$HOME/.claude/settings.json" ]; then
            tmp="$(mktemp)"
            if jq '
                if (.hooks.PreToolUse // null) != null then
                    .hooks.PreToolUse = [
                        .hooks.PreToolUse[] |
                        if (.hooks // null) != null then
                            .hooks = [ .hooks[] | select(((.command // "") | (contains("repowarden garde") or contains("repowarden guard"))) | not) ] |
                            select((.hooks | length) > 0)
                        else
                            select(((.command // "") | (contains("repowarden garde") or contains("repowarden guard"))) | not)
                        end
                    ] |
                    if (.hooks.PreToolUse | length) == 0 then del(.hooks.PreToolUse) else . end |
                    if ((.hooks // {}) | keys | length) == 0 then del(.hooks) else . end
                else . end
            ' "$HOME/.claude/settings.json" >"$tmp" 2>/dev/null; then
                mv "$tmp" "$HOME/.claude/settings.json"
            else
                rm -f "$tmp"
            fi
        fi
        # Plugin opencode du garde-fou (retiré aussi par repowarden ci-dessus)
        rm -f "$HOME/.config/opencode/plugins/repowarden-garde.js" \
              "$HOME/.config/opencode/plugins/repowarden-garde-v2.js"
        # Garde-fou docker : seules ses entrées et ses plugins sont retirés.
        retirer_garde_docker
        # Configuration opencode : retirée seulement si elle porte le repère devzone
        # et n'a pas été modifiée ; personnalisée → gardée.
        retirer_config_opencode
        # Retire le fournisseur opencode des modèles de l'hôte, garde le reste du fichier.
        unset_provider || true
        # Skill devzone : retirée seulement si non modifiée ; personnalisée → gardée.
        retirer_skill_devzone
        # État de devzone agent : gardé dans le volume partagé (désactivation
        # dans l'une des devzone ne supprime pas l'état des autres).
        echo "devzone : ia désactivé (connexions et état de devzone agent gardés dans leurs volumes ; journaux workspace/.agents/ gardés)"
    fi
}
