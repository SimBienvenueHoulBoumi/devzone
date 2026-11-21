#!/usr/bin/env bash
# shellcheck shell=bash
# devzone, platform: GitHub or GitLab.
# Sourced by .devcontainer/devzone (split of the 1 600 lines file, #722):
# functions only, shared variables are defined in devzone.


# ---- Platform: GitHub (default) or GitLab (#240) ----
# Choice kept in the state file (plateforme=, gitlab_url=), per instance; the
# configuration of a service only exists while it is chosen (#242): glab and the
# URL disappear when going back to github.

# Current platform: github when there is no line (default)
platform_read() {
    local v
    v="$(grep -E '^plateforme=' "$ETAT" 2>/dev/null | tail -1 | cut -d= -f2 || true)"
    [ "$v" = gitlab ] && echo gitlab || echo github
}

# URL of the GitLab instance, nothing if missing
gitlab_url_read() {
    grep -E '^gitlab_url=' "$ETAT" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Host of a URL, without its protocol (glab --hostname)
host_of() {
    echo "$1" | sed -E 's#^[a-z]+://##; s#/$##'
}

# Removes glab and its configuration (back to github)
remove_glab() {
    rm -f "$GLAB"
    rm -rf "$HOME/.config/glab-cli"
}

# State line for the platform: github by default, or the GitLab instance with
# its connected glab on the login command otherwise
platform_line() {
    local url host
    if [ "$(platform_read)" = gitlab ]; then
        url="$(gitlab_url_read)"
        host="$(host_of "$url")"
        if [ -x "$GLAB" ] && "$GLAB" auth status --hostname "$host" >/dev/null 2>&1; then
            printf '  ✔ platform       gitlab: %s, glab connected\n' "$url"
        else
            printf '  ⚠ platform       gitlab: %s, glab not connected: glab auth login --hostname %s\n' "$url" "$host"
        fi
    else
        echo "  ✔ platform       github"
    fi
}

# Simple display of the platform (devzone platform)
platform_summary() {
    local url host
    if [ "$(platform_read)" = gitlab ]; then
        url="$(gitlab_url_read)"
        host="$(host_of "$url")"
        if [ -x "$GLAB" ] && "$GLAB" auth status --hostname "$host" >/dev/null 2>&1; then
            echo "devzone : gitlab platform: $url, glab connected"
        else
            echo "devzone : gitlab platform: $url, glab not connected: glab auth login --hostname $host"
        fi
    else
        echo "devzone : github platform (default)"
    fi
}

# Installs glab (official release, SHA-256 sum checked), nothing if it is
# already there; the binary ends in ~/.local/bin (remove_glab removes it)
install_glab() {
    local arch="" sum archive folder glab_tmp
    if [ -x "$GLAB" ] && "$GLAB" --version >/dev/null 2>&1; then
        return 0
    fi
    case "$(uname -m)" in
        arm64 | aarch64) arch=arm64 sum="$GLAB_SOMME_ARM64" ;;
        *) arch=amd64 sum="$GLAB_SOMME_AMD64" ;;
    esac
    echo "devzone : downloading glab $GLAB_VERSION (SHA-256 checked)…"
    archive="$(mktemp)"
    if ! curl -fsSL -o "$archive" "https://gitlab.com/gitlab-org/cli/-/releases/$GLAB_VERSION/downloads/glab_${GLAB_VERSION#v}_linux_${arch}.tar.gz"; then
        rm -f "$archive"
        echo "devzone : glab download failed (official gitlab.com release); retry: devzone platform gitlab --url URL" >&2
        return 1
    fi
    if [ "$(sha256sum "$archive" | cut -d' ' -f1)" != "$sum" ]; then
        rm -f "$archive"
        echo "devzone : glab SHA-256 sum unexpected, aborting; archive refused" >&2
        return 1
    fi
    folder="$(mktemp -d)"
    glab_tmp="$folder/bin/glab"
    if ! tar -xzf "$archive" -C "$folder" || [ ! -f "$glab_tmp" ]; then
        glab_tmp="$folder/glab"
    fi
    if [ ! -f "$glab_tmp" ]; then
        rm -rf "$folder" "$archive"
        echo "devzone : glab binary missing from the archive, aborting" >&2
        return 1
    fi
    mkdir -p "$HOME/.local/bin"
    mv "$glab_tmp" "$GLAB"
    chmod +x "$GLAB"
    rm -rf "$folder" "$archive"
}

# Login to the GitLab instance: instance of the gitlab module -> root token of
# the module (http protocol, never shown); another instance -> interactive, a
# browser asking for the login code. Checks: exit code of the auth login, then
# auth status --hostname; without that check, not "connected".
connect_glab() {
    local host="$1" url="$2" token
    if [ "$url" = "$GITLAB_URL_MODULE" ]; then
        if [ ! -f "$RACINE/workspace/.gitlab/root-token" ]; then
            echo "devzone : root token of the gitlab module not found ($RACINE/workspace/.gitlab/root-token): devzone enable gitlab, or by hand: glab auth login --hostname $host" >&2
            return 1
        fi
        token="$(cat "$RACINE/workspace/.gitlab/root-token")"
        if ! "$GLAB" auth login --hostname "$host" --api-protocol http --git-protocol http --token "$token"; then
            echo "devzone : cannot connect to the gitlab instance: devzone enable gitlab, or by hand: glab auth login --hostname $host" >&2
            return 1
        fi
    elif ! "$GLAB" auth login --hostname "$host"; then
        echo "devzone : cannot connect to the gitlab instance: glab auth login --hostname $host" >&2
        return 1
    fi
    if ! "$GLAB" auth status --hostname "$host" >/dev/null 2>&1; then
        echo "devzone : cannot verify the connection: glab auth status --hostname $host" >&2
        return 1
    fi
}

# Changes the platform: github (default, current behaviour) or gitlab
change_platform() {
    local target="${1:-}" url="" expect="" arg host
    case "$target" in
        github)
            # Removes the credential setting of the last gitlab host, if there is one
            if [ -n "$(gitlab_url_read)" ]; then
                git config --global --unset-all "credential.$(gitlab_url_read).helper" 2>/dev/null || true
            fi
            remove_glab
            remove_key plateforme
            remove_key gitlab_url
            echo "devzone : github platform (default): gh checks; glab and its configuration removed if they were installed"
            ;;
        gitlab)
            for arg in "${@:2}"; do
                if [ -n "$expect" ]; then url="$arg"; expect=""; continue; fi
                case "$arg" in
                    --url) expect=1 ;;
                    *) echo "devzone : unknown argument: $arg (devzone platform gitlab --url URL)" >&2; return 1 ;;
                esac
            done
            if [ -n "$expect" ]; then
                echo "devzone : --url expects a URL" >&2
                return 1
            fi
            if [ -z "$url" ]; then
                if [ "$(value_of gitlab)" = on ]; then
                    url="$GITLAB_URL_MODULE"
                else
                    echo "devzone : missing URL: devzone platform gitlab --url URL (or an active gitlab module for the local instance)" >&2
                    return 1
                fi
            fi
            host="$(host_of "$url")"
            if ! install_glab; then
                return 1
            fi
            if ! connect_glab "$host" "$url"; then
                echo "devzone : reconnect needed: glab auth login --hostname $host" >&2
                return 1
            fi
            if ! git config --global "credential.$url.helper" "!$GLAB auth git-credential"; then
                echo "devzone : cannot set the git credential" >&2
                return 1
            fi
            write_value plateforme gitlab
            write_value gitlab_url "$url"
            echo "devzone : gitlab platform: $url, glab connected"
            ;;
        *)
            echo "devzone : unknown platform: ${target:-(none)}; choices: github (default) or gitlab [--url URL]" >&2
            return 1
            ;;
    esac
}
