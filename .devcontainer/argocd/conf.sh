#!/usr/bin/env bash
# Configuration file of the Argo CD of devzone (#516): .argocd.conf at the
# root of the devzone folder, the same shape as .repowarden.conf:
#   [argocd]
#       repo = https://github.com/<login>/devzone-argocd.git   # none: direct apply
#   [app demo]
#       repo = https://github.com/argoproj/argocd-example-apps
#       path = guestbook
#       revision = HEAD
#       namespace = devzone-app-demo
#       username = root                           # private repositories
#       token-file = workspace/.gitlab/root-token
# The file is the declaration, versioned with the devzone folder: devzone
# writes it (argocd init, app add, app remove) and applies it (workspace
# start, argocd apply). Tokens never go in it, only paths to them. The
# includer defines ARGOCD_CONF (the path of the file).
#   conf_get <section> <key>          value, empty when absent
#   conf_sections <prefix>            names of the sections "[<prefix> <name>]"
#   conf_set <section> key=value...   section replaced (or added at the end)
#   conf_remove <section>
# bash 3.2 (macOS): no associative array, one pass per call.

conf_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Section name of a "[...]" line, trimmed
conf_section_of() {
    local s="$1"
    s="${s#\[}"
    s="${s%\]}"
    conf_trim "$s"
}

# Lines of the file as "section<TAB>key<TAB>value"; comments and blanks dropped
conf_entries() {
    local line section="" key value
    [ -f "$ARGOCD_CONF" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        line="$(conf_trim "$line")"
        case "$line" in
            '' | '#'*) continue ;;
            '['*']') section="$(conf_section_of "$line")"; continue ;;
        esac
        case "$line" in *=*) ;; *) continue ;; esac
        key="$(conf_trim "${line%%=*}")"
        value="${line#*=}"
        value="${value%%#*}"
        value="$(conf_trim "$value")"
        printf '%s\t%s\t%s\n' "$section" "$key" "$value"
    done <"$ARGOCD_CONF"
}

conf_get() {
    local s k v
    while IFS="$(printf '\t')" read -r s k v; do
        if [ "$s" = "$1" ] && [ "$k" = "$2" ]; then
            printf '%s' "$v"
            return 0
        fi
    done <<<"$(conf_entries)"
    return 0
}

conf_sections() {
    local line t n
    [ -f "$ARGOCD_CONF" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        t="$(conf_trim "$line")"
        case "$t" in
            '['*']')
                n="$(conf_section_of "$t")"
                case "$n" in
                    "$1 "*)
                        n="$(conf_trim "${n#"$1"}")"
                        [ -z "$n" ] || printf '%s\n' "$n"
                        ;;
                esac
                ;;
        esac
    done <"$ARGOCD_CONF"
}

# The file without the section $1 (its header and its keys)
conf_without() {
    local line t skip=0
    [ -f "$ARGOCD_CONF" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        t="$(conf_trim "$line")"
        case "$t" in
            '['*']')
                if [ "$(conf_section_of "$t")" = "$1" ]; then skip=1; continue; fi
                skip=0
                ;;
        esac
        [ "$skip" = 1 ] && continue
        printf '%s\n' "$line"
    done <"$ARGOCD_CONF"
}

conf_header() {
    cat <<'EOF'
# Argo CD of devzone (#516): what devzone declares in its GitOps repository.
# Written by devzone (argocd init, app add, app remove), applied by
# devzone workspace argocd apply and by workspace start. Tokens never go
# here, only paths to them (token-file).
EOF
}

# Section $1 replaced by the key=value pairs that follow (added at the end
# when absent); blank lines squeezed
conf_set() {
    local section="$1" tmp kv
    shift
    tmp="$(mktemp)"
    if [ -f "$ARGOCD_CONF" ]; then
        conf_without "$section" >"$tmp"
    else
        conf_header >"$tmp"
    fi
    {
        echo
        echo "[$section]"
        for kv in "$@"; do
            printf '    %s = %s\n' "${kv%%=*}" "${kv#*=}"
        done
    } >>"$tmp"
    cat -s "$tmp" >"$ARGOCD_CONF"
    rm -f "$tmp"
}

conf_remove() {
    local tmp
    [ -f "$ARGOCD_CONF" ] || return 0
    tmp="$(mktemp)"
    conf_without "$1" | cat -s >"$tmp"
    mv "$tmp" "$ARGOCD_CONF"
}
