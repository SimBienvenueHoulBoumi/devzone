#!/usr/bin/env bash
# shellcheck shell=bash
# devzone, ai module: guard of the host container tools.
# Sourced by .devcontainer/devzone (split of the 1 600 lines file, #722):
# functions only, shared variables are defined in devzone.

# Docker guard for the folders that are not this repository: a Claude Code
# PreToolUse hook in the global settings and the two opencode plugins in the
# global plugins folder. Idempotent, other user settings and hooks preserved.
poser_garde_docker() {
    local script="$ICI/ai/docker-guard.sh" config="$HOME/.claude/settings.json"
    local src="$ICI/ai/plugins" dst="$HOME/.config/opencode/plugins"
    local tmp f
    if ! command -v jq >/dev/null 2>&1; then
        echo "devzone : jq absent : garde-fou docker non posé pour Claude Code" >&2
    elif [ ! -f "$config" ]; then
        echo "devzone : $config absent : garde-fou docker non posé pour Claude Code" >&2
    elif ! jq -e . "$config" >/dev/null 2>&1; then
        echo "devzone : $config illisible (JSON invalide) : garde-fou docker non posé pour Claude Code" >&2
    else
        tmp="$(mktemp)"
        if jq --arg cmd "bash \"$script\" --format claude" '
            .hooks = (.hooks // {}) |
            .hooks.PreToolUse = (.hooks.PreToolUse // []) |
            if ([.hooks.PreToolUse[]? | .hooks[]? | (.command // "")] | any(contains("docker-guard.sh")))
            then .
            else .hooks.PreToolUse += [{"matcher": "Bash", "hooks": [{"type": "command", "command": $cmd}]}]
            end
        ' "$config" >"$tmp" 2>/dev/null; then
            mv "$tmp" "$config"
        else
            rm -f "$tmp"
            echo "devzone : $config inchangé : garde-fou docker non posé pour Claude Code" >&2
        fi
    fi
    mkdir -p "$dst"
    for f in devzone-guard.js devzone-guard-v2.js; do
        [ -f "$src/$f" ] || continue
        sed "s|__DEVZONE_DOCKER_GARDE__|$script|g" "$src/$f" >"$dst/$f"
    done
    echo "devzone : garde-fou docker actif pour Claude Code et opencode"
}

# Removes only the Docker guard entries (commands containing docker-guard.sh)
# and the two plugins; the rest of settings.json and of the plugins is kept.
retirer_garde_docker() {
    local config="$HOME/.claude/settings.json" tmp
    if [ -f "$config" ] && jq -e . "$config" >/dev/null 2>&1; then
        tmp="$(mktemp)"
        if jq '
            if (.hooks.PreToolUse // null) != null then
                .hooks.PreToolUse = [
                    .hooks.PreToolUse[] |
                    if (.hooks // null) != null then
                        .hooks = [ .hooks[] | select(((.command // "") | contains("docker-guard.sh")) | not) ] |
                        select((.hooks | length) > 0)
                    else
                        select(((.command // "") | contains("docker-guard.sh")) | not)
                    end
                ] |
                if (.hooks.PreToolUse | length) == 0 then del(.hooks.PreToolUse) else . end |
                if ((.hooks // {}) | keys | length) == 0 then del(.hooks) else . end
            else . end
        ' "$config" >"$tmp" 2>/dev/null; then
            if [ "$(cat "$tmp")" = "{}" ]; then
                rm -f "$tmp" "$config"
            else
                mv "$tmp" "$config"
            fi
        else
            rm -f "$tmp"
        fi
    fi
    rm -f "$HOME/.config/opencode/plugins/devzone-guard.js" \
          "$HOME/.config/opencode/plugins/devzone-guard-v2.js"
}
