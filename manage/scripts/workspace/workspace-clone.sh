#!/usr/bin/env bash
# Working clones inside the pod (#558), sourced by manage/workspace.sh:
#   devzone workspace clone <url> [<name>]
# git clone into $PROJECTS_DIR/<name> of the pod over HTTPS, credentials given
# by the gh git credential helper set up in the pod, git identity copied from
# the workstation, then "repowarden install" in the clone (hooks). bash 3.2.

# Script run in the pod: $1 clone folder, $2 url, $3 git name, $4 git email.
# Exit 3: the folder exists and is not a clone of this url.
workspace_clone_pod_script() {
    cat <<'POD'
set -eu
dir="$1" url="$2" name="$3" email="$4"
norm() { local u="${1%/}"; echo "${u%.git}"; }
gh auth setup-git
if [ -d "$dir/.git" ]; then
    remote="$(git -C "$dir" remote get-url origin 2>/dev/null || true)"
    if [ "$(norm "$remote")" != "$(norm "$url")" ]; then
        echo "✖ $dir already exists with another remote: ${remote:-none}" >&2
        exit 3
    fi
    echo "$dir is already a clone of $url"
elif [ -e "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
    echo "✖ $dir already exists and is not a git clone" >&2
    exit 3
else
    git clone "$url" "$dir"
fi
[ -z "$name" ] || git -C "$dir" config user.name "$name"
[ -z "$email" ] || git -C "$dir" config user.email "$email"
if command -v repowarden >/dev/null 2>&1; then
    (cd "$dir" && repowarden install)
else
    echo "⚠ repowarden missing in the pod: hooks not installed in $dir" >&2
fi
POD
}

# Folder name from a url: last path segment without .git.
workspace_clone_name() {
    local u="${1%/}"
    u="${u##*/}"
    u="${u##*:}"
    echo "${u%.git}"
}

workspace_clone() {
    local url="${1:-}" name="${2:-}" git_name git_email
    if [ -z "$url" ] || [ $# -gt 2 ]; then
        echo "✖ usage: devzone workspace clone <url> [<name>]" >&2
        return 1
    fi
    [ -n "$name" ] || name="$(workspace_clone_name "$url")"
    case "$name" in
        '' | . | .. | -* | */* | *[!A-Za-z0-9._-]*)
            echo "✖ invalid folder name: ${name:-empty} (letters, digits, . _ - only)" >&2
            return 1
            ;;
    esac
    git_name="$(git config --get user.name 2>/dev/null || true)"
    git_email="$(git config --get user.email 2>/dev/null || true)"
    # shellcheck disable=SC2046
    workspace_clone_pod_script | kubectl $(kubectl_flag) exec -i "$POD" \
        --namespace "$NAMESPACE" -c workspace -- \
        bash -s -- "$PROJECTS_DIR/$name" "$url" "$git_name" "$git_email"
}

# Guard of the agents in the pod (#558): when the ai module is on there,
# "repowarden agents init --global" is run (idempotent), so that an agent
# launched in the pod cannot edit develop. Never fails the workspace start.
workspace_agents_guard() {
    # shellcheck disable=SC2046
    if kubectl $(kubectl_flag) exec "$POD" --namespace "$NAMESPACE" -c workspace -- \
        bash -lc 'devzone is-enabled ai && repowarden agents init --global' >/dev/null 2>&1; then
        echo "✔ repowarden guard active for the agents of the pod"
    fi
}
