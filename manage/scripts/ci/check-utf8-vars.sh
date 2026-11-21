#!/usr/bin/env bash
# CI check: in the shell scripts tracked by git, a variable name immediately
# followed by a non-ASCII byte must be written ${NAME}. Under the macOS locale
# bash reads the multi-byte character as part of the name, so $NAME followed by
# an accented letter or an ellipsis breaks (#591). Scripts checked: *.sh,
# *.bash, .devcontainer/devzone, manage/devzone, and any tracked file whose
# first line is a bash shebang. A fault is printed as "path:line: text" and the
# run exits 1; otherwise it prints "utf8 vars check: N files ok" and exits 0.
# bash 3.2 (macOS).

set -u

ICI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$ICI/../../.." && pwd)"

# Byte matching only. The class is every byte outside printable ASCII, minus
# the tab (a tab after a name is not a fault). Built from a printf so this
# file holds no literal non-ASCII byte and never matches its own rule.
TAB="$(printf '\t')"
PATTERN='\$[A-Za-z_][A-Za-z_0-9]*[^ -~'"$TAB"']'

LC_ALL=C
export LC_ALL

# True when the tracked file $1 (relative to ROOT) is a bash script
is_bash_script() {
    local first
    case "$1" in
        *.sh | *.bash | .devcontainer/devzone | manage/devzone) return 0 ;;
    esac
    first="$(head -n 1 "$ROOT/$1" 2>/dev/null)"
    case "$first" in
        '#!'*bash*) return 0 ;;
    esac
    return 1
}

files="$(git -C "$ROOT" ls-files)" || {
    echo "check-utf8-vars: git ls-files fails in $ROOT" >&2
    exit 1
}

fails=0
count=0
while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$ROOT/$f" ] || continue
    is_bash_script "$f" || continue
    count=$((count + 1))
    matches="$(grep -naE -- "$PATTERN" "$ROOT/$f")" || matches=""
    while IFS= read -r m; do
        [ -n "$m" ] || continue
        n="${m%%:*}"
        printf '%s:%s: %s\n' "$f" "$n" "${m#*:}"
        fails=1
    done <<EOF
$matches
EOF
done <<EOF
$files
EOF

if [ "$fails" -ne 0 ]; then
    echo "check-utf8-vars: write \${NAME} instead of \$NAME before a non-ASCII byte" >&2
    exit 1
fi
echo "utf8 vars check: $count files ok"
