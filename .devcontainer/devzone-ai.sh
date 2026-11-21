#!/usr/bin/env bash
# shellcheck shell=bash
# devzone, ai module: opencode config, assistants install, apply.
# Sourced by .devcontainer/devzone (split of the 1 600 lines file, #722):
# functions only, shared variables are defined in devzone.

# Marker of the default configuration: first line of opencode.jsonc. The former
# wording (French, before #722) is still recognised. Byte escapes keep the accent
# out of the source (check-english).
OPENCODE_MARKER='// devzone : default opencode configuration'
OPENCODE_MARKER_OLD="$(printf '// devzone : configuration opencode par d\303\251faut')"

# True if the file carries the default-configuration marker, in either wording
opencode_marked() { grep -qF -e "$OPENCODE_MARKER" -e "$OPENCODE_MARKER_OLD" "$1"; }

# Default opencode configuration (versioned model): written at first use,
# updated while it keeps the devzone marker, customised otherwise. The marker
# text is written in opencode.jsonc: it is kept as is.
opencode_config() {
    local model="$ICI/opencode.jsonc" target
    if [ -f "$HOME/.config/opencode/opencode.jsonc" ]; then
        target="$HOME/.config/opencode/opencode.jsonc"
    elif [ -f "$HOME/.config/opencode/opencode.json" ]; then
        target="$HOME/.config/opencode/opencode.json"
    else
        target="$HOME/.config/opencode/opencode.jsonc"
    fi
    mkdir -p "$(dirname "$target")"
    if [ ! -f "$target" ]; then
        cp "$model" "$target"
        echo "opencode : default configuration written"
    elif opencode_marked "$target"; then
        if ! cmp -s "$model" "$target"; then
            cp "$model" "$target"
            echo "opencode : default configuration updated"
        fi
    elif only_schema_key "$target"; then
        cp "$model" "$target"
        echo "opencode : default configuration updated"
    else
        echo "opencode : custom configuration, kept"
    fi
}

# Removes the opencode configuration written by devzone if it still carries its
# marker and was not changed; a custom configuration (no marker, or changed) is
# kept. Symmetrical with opencode_config.
remove_opencode_config() {
    local model target
    model="$ICI/opencode.jsonc"
    if [ -f "$HOME/.config/opencode/opencode.jsonc" ]; then
        target="$HOME/.config/opencode/opencode.jsonc"
    elif [ -f "$HOME/.config/opencode/opencode.json" ]; then
        target="$HOME/.config/opencode/opencode.json"
    else
        return 0
    fi
    if opencode_marked "$target" && cmp -s "$model" "$target"; then
        rm -f "$target"
        echo "opencode : default configuration removed"
    else
        echo "opencode : custom configuration, kept"
    fi
}

# Log of the last npm run (its path is to give on failure), or its folder;
# timestamped names: the last one in glob order is the most recent
last_npm_log() {
    local log="" f
    for f in "$HOME"/.npm/_logs/*-debug-0.log; do
        if [ -f "$f" ]; then log="$f"; fi
    done
    echo "${log:-$HOME/.npm/_logs}"
}

# Installs each pinned AI assistant with its own npm command (3 tries each),
# then checks its binary: npm silently drops a platform binary it failed to
# download (#194), and one assistant failing must not block the other.
install_ai() {
    local package binary attempt
    IA_FAILED=()
    for package in "${IA_PAQUETS[@]}"; do
        case "$package" in
            opencode-ai@*) binary=opencode ;;
            *) binary=claude ;;
        esac
        for attempt in 1 2 3; do
            if with_progress npm install -g --no-fund --no-audit --loglevel=error "$package" >/dev/null &&
                "$binary" --version >/dev/null 2>&1; then
                break
            fi
            if [ "$attempt" -lt 3 ]; then
                echo "devzone : installation of ${package%@*} incomplete, retrying ($((attempt + 1))/3)…" >&2
            else
                IA_FAILED+=("$package")
            fi
        done
    done
    [ "${#IA_FAILED[@]}" -eq 0 ]
}

apply_ia() {
    local log tmp detected
    if [ "$1" = on ]; then
        echo "devzone : installing Claude Code and opencode (a few minutes)…"
        if ! install_ai; then
            log="$(last_npm_log)"
            echo "npm log: $log" >"$(failure_marker_file ia)"
            echo "devzone : installation of ${IA_FAILED[*]} failed (npm install -g, 3 tries); npm log: $log; retry: devzone apply" >&2
            return 1
        fi
        rm -f "$(failure_marker_file ia)"
        echo "devzone : Claude Code and opencode installed"
        # repowarden guard (Claude Code PreToolUse hook, opencode plugin): the
        # agent is stopped before changing main/develop, committing without
        # repowarden cc, or bypassing the hooks. Global, in the ~/.claude and
        # ~/.config/opencode volumes: kept across rebuilds; rerun, nothing changes
        if command -v repowarden >/dev/null 2>&1 && repowarden agents init --global >/dev/null 2>&1; then
            echo "devzone : repowarden guard active for Claude Code and opencode"
        else
            echo "devzone : repowarden guard not connected (repowarden 4.10 or later required): repowarden agents init --global" >&2
        fi
        install_docker_guard
        opencode_config
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
        # opencode provider of the host models (Ollama), live detection:
        # silent and without effect if Ollama does not answer.
        set_provider || true
        # Reports the state of the detection (success in both cases).
        detected="$(modeles 2>/dev/null || true)"
        if [ -n "$detected" ]; then
            printf "devzone : %s model(s) of the host (Ollama) connected\n" "$(printf '%s\n' "$detected" | grep -c .)"
        else
            printf "devzone : no Ollama model detected on %s (host models not connected)\n" "$URL"
        fi
        # devzone skill: installed if missing, updated if unchanged, kept if customised.
        install_devzone_skill
        echo "devzone : ai active: claude (then /login), opencode auth login"
    else
        npm uninstall -g "${IA_NOMS[@]}" >/dev/null 2>&1 || true
        rm -f "$(failure_marker_file ia)"
        # repowarden guard: removed on disable (symmetrical with the enable).
        # repowarden does it itself when present; otherwise removal by jq of only
        # the PreToolUse entries calling the guard, the rest of settings.json
        # intact. The guard is called " repowarden guard " since repowarden
        # 4.17.3; " repowarden garde " is its old name, still an alias on the
        # repowarden side and recognised here.
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
        # opencode plugin of the guard (also removed by repowarden above)
        rm -f "$HOME/.config/opencode/plugins/repowarden-garde.js" \
              "$HOME/.config/opencode/plugins/repowarden-garde-v2.js"
        # docker guard: only its entries and its plugins are removed.
        remove_docker_guard
        # opencode configuration: removed only if it carries the devzone marker
        # and was not changed; customised -> kept.
        remove_opencode_config
        # Removes the opencode provider of the host models, keeps the rest of the file.
        unset_provider || true
        # devzone skill: removed only if unchanged; customised -> kept.
        remove_devzone_skill
        # devzone agent state: kept in the shared volume (disabling it in one
        # devzone does not remove the state of the others).
        echo "devzone : ai disabled (logins and devzone agent state kept in their volumes; workspace/.agents/ logs kept)"
    fi
}
