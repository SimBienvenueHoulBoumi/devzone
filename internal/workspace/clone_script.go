package workspace

// cloneScript runs in the pod (bash -s, with the clone folder, the url, the git
// name and the git email as $1 to $4). It clones the url into the folder when the
// folder is missing, checks the remote of an existing clone, sets the git identity
// and installs the repowarden hooks. Same script as workspace_clone_pod_script in
// manage/scripts/workspace/workspace-clone.sh: exit 3 when the folder holds another project.
const cloneScript = `set -eu
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
`
