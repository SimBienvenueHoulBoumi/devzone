#!/usr/bin/env bash
# Grouped credentials of the accounts created by devzone (#332).
#   password.sh regenerate   reads the module files, writes $ROOT/.password
#   password.sh path         prints the path of $ROOT/.password
# The module files stay the source: .password is a regenerated view.
# Plain-text secrets: never printed, never committed (.gitignore), mode 600.
set -euo pipefail

PASSWORD_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASSWORD_ROOT="${DEVZONE_ROOT:-$(dirname "$PASSWORD_HERE")}"
PASSWORD_TARGET="$PASSWORD_ROOT/.password"

# Regenerates $ROOT/.password from workspace/.gitlab, workspace/.postgres,
# workspace/.argocd, workspace/.mysql and the other workspace/.<app>/ folders.
# Silent on success; without any account, the file is removed.
password_regenerate() (
    umask 077
    local target="$PASSWORD_TARGET" root="$PASSWORD_ROOT"
    local gl="$root/workspace/.gitlab" pg="$root/workspace/.postgres"
    local ar="$root/workspace/.argocd"
    local my="$root/workspace/.mysql"
    local tab entries tmp file name service address user secret
    tab="$(printf '\t')"
    entries="$(mktemp "$root/.password.entries.XXXXXX")" || return 1
    tmp=""

    if [ -s "$gl/root-password" ]; then
        secret="$(cat "$gl/root-password")"
        if [ -n "$secret" ]; then
            printf 'gitlab\t%s\troot\t%s\n' "http://gitlab.localhost:8929" "$secret" >>"$entries"
        fi
    fi
    if [ -s "$gl/dev-password" ]; then
        secret="$(cat "$gl/dev-password")"
        if [ -n "$secret" ]; then
            printf 'gitlab\t%s\tdev\t%s\n' "http://gitlab.localhost:8929" "$secret" >>"$entries"
        fi
    fi
    if [ -s "$pg/admin-password" ]; then
        secret="$(cat "$pg/admin-password")"
        if [ -n "$secret" ]; then
            printf 'postgres\t%s\tpostgres\t%s\n' "127.0.0.1:5432" "$secret" >>"$entries"
        fi
    fi
    # Catalogue MySQL root (direct helm or Argo CD, #538): mirror of the workstation
    if [ -s "$my/admin-password" ]; then
        secret="$(cat "$my/admin-password")"
        if [ -n "$secret" ]; then
            printf 'mysql\t%s\troot\t%s\n' "127.0.0.1:3306" "$secret" >>"$entries"
        fi
    fi
    if [ -s "$ar/admin.env" ]; then
        user="$(sed -n 's/^ARGOCD_USER=//p' "$ar/admin.env" 2>/dev/null | tail -1 || true)"
        secret="$(sed -n 's/^ARGOCD_PASSWORD=//p' "$ar/admin.env" 2>/dev/null | tail -1 || true)"
        if [ -n "$user" ] && [ -n "$secret" ]; then
            printf 'argocd\t%s\t%s\t%s\n' "https://127.0.0.1:8443" "$user" "$secret" >>"$entries"
        fi
    fi
    for file in "$pg"/*.env; do
        [ -f "$file" ] || continue
        name="${file##*/}"
        name="${name%.env}"
        service="postgres:$name"
        user="$(sed -n 's/^DB_USER=//p' "$file" 2>/dev/null | tail -1 || true)"
        secret="$(sed -n 's/^DB_PASSWORD=//p' "$file" 2>/dev/null | tail -1 || true)"
        address="$(sed -n 's/^DB_NAME=//p' "$file" 2>/dev/null | tail -1 || true)"
        if [ -z "$user" ] || [ -z "$secret" ]; then
            continue
        fi
        address="127.0.0.1:5432/${address:-$name}"
        printf '%s\t%s\t%s\t%s\n' "$service" "$address" "$user" "$secret" >>"$entries"
    done
    # Each other catalogue application: workspace/.<app>/*.env, keys <APP>_HOST,
    # <APP>_PORT, <APP>_USER, <APP>_PASSWORD (or MYSQL_* for mysql)
    for dir in "$root"/workspace/.*/; do
        [ -d "$dir" ] || continue
        app="${dir%/}"
        app="${app##*/}"
        case "$app" in . | .. | .gitlab | .postgres | .argocd) continue ;; esac
        app="${app#.}"
        app_upper="$(printf '%s' "$app" | tr '[:lower:]' '[:upper:]')"
        for file in "$dir"*.env; do
            [ -f "$file" ] || continue
            base="${file##*/}"
            base="${base%.env}"
            user="$(sed -n "s/^${app_upper}_USER=//p" "$file" 2>/dev/null | tail -1 || true)"
            [ -z "$user" ] && user="$(sed -n 's/^DB_USER=//p' "$file" 2>/dev/null | tail -1 || true)"
            [ -z "$user" ] && user="$(sed -n 's/^MYSQL_USER=//p' "$file" 2>/dev/null | tail -1 || true)"
            secret="$(sed -n "s/^${app_upper}_PASSWORD=//p" "$file" 2>/dev/null | tail -1 || true)"
            [ -z "$secret" ] && secret="$(sed -n 's/^DB_PASSWORD=//p' "$file" 2>/dev/null | tail -1 || true)"
            [ -z "$secret" ] && secret="$(sed -n 's/^MYSQL_PASSWORD=//p' "$file" 2>/dev/null | tail -1 || true)"
            [ -z "$user" ] || [ -z "$secret" ] && continue
            host="$(sed -n "s/^${app_upper}_HOST=//p" "$file" 2>/dev/null | tail -1 || true)"
            [ -z "$host" ] && host="$(sed -n 's/^DB_HOST=//p' "$file" 2>/dev/null | tail -1 || true)"
            [ -z "$host" ] && host="$(sed -n 's/^MYSQL_HOST=//p' "$file" 2>/dev/null | tail -1 || true)"
            [ -z "$host" ] && host=127.0.0.1
            port="$(sed -n "s/^${app_upper}_PORT=//p" "$file" 2>/dev/null | tail -1 || true)"
            [ -z "$port" ] && port="$(sed -n 's/^DB_PORT=//p' "$file" 2>/dev/null | tail -1 || true)"
            [ -z "$port" ] && port="$(sed -n 's/^MYSQL_PORT=//p' "$file" 2>/dev/null | tail -1 || true)"
            [ -z "$port" ] && port=3306
            printf '%s\t%s\t%s\t%s\n' "$app:$base" "$host:$port" "$user" "$secret" >>"$entries"
        done
    done

    if [ ! -s "$entries" ]; then
        rm -f "$entries" "$target"
        return 0
    fi

    tmp="$(mktemp "$root/.password.XXXXXX")" || {
        rm -f "$entries"
        return 1
    }
    {
        printf '%s\n' \
            '# devzone : identifiers of the accounts created by devzone. Plain-text secrets:' \
            '# never commit, copy or paste them into a ticket. Regenerated by devzone.' \
            "# service${tab}address${tab}user${tab}password"
        LC_ALL=C sort -t "$tab" -k1,1 -k3,3 "$entries"
    } >"$tmp" || {
        rm -f "$entries" "$tmp"
        return 1
    }
    chmod 600 "$tmp" || {
        rm -f "$entries" "$tmp"
        return 1
    }
    mv "$tmp" "$target" || {
        rm -f "$entries" "$tmp"
        return 1
    }
    chmod 600 "$target" || {
        rm -f "$entries"
        return 1
    }
    rm -f "$entries"
)

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        regenerate) password_regenerate ;;
        path) printf '%s\n' "$PASSWORD_TARGET" ;;
        *)
            echo "devzone : password.sh : regenerate | path" >&2
            exit 1
            ;;
    esac
fi
