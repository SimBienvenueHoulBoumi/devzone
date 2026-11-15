#!/usr/bin/env bash
# Stale copies in the pod (#558), sourced by manage/workspace.sh:
#   status_workspace  pod status, then the legacy copies still in the pod
#   copy_guard        copy-to never overwrites a pod clone of another remote
# Uses kubectl_flag, POD, NAMESPACE and PROJECTS_DIR from workspace.sh.

# Shows workspace pod status, then the legacy copies still in the pod.
status_workspace() {
    # shellcheck disable=SC2046
    kubectl $(kubectl_flag) get pods --namespace devzone-workspace
    workspace_legacy_copies || true
}

# Script run in the pod: prints the legacy copies, one folder per line
# (repogarde, wt): their .git file points to a git folder missing from the pod.
workspace_legacy_pod_script() {
    cat <<'POD'
broken() {
    local g
    [ -f "$1/.git" ] || return 1
    g="$(sed -n 's/^gitdir: *//p' "$1/.git" | head -1)"
    [ -n "$g" ] && [ ! -e "$g" ]
}
cd "$1" || exit 0
if broken repogarde; then echo repogarde; fi
for d in wt/*; do
    if broken "$d"; then echo wt; break; fi
done
POD
}

# Legacy copies (repogarde/, wt/) are reported with the command to remove them;
# the removal itself is manual, after a backup.
workspace_legacy_copies() {
    local found d dirs=""
    # shellcheck disable=SC2046
    found="$(workspace_legacy_pod_script | kubectl $(kubectl_flag) exec -i "$POD" \
        --namespace "$NAMESPACE" -c workspace -- bash -s -- "$PROJECTS_DIR" 2>/dev/null)" || return 0
    [ -n "$found" ] || return 0
    for d in $found; do dirs="$dirs $PROJECTS_DIR/$d"; done
    echo "⚠ legacy copies in the pod (their .git points outside the pod):$dirs"
    echo "  save what you need first (devzone workspace copy-from <folder>), then remove them:"
    # shellcheck disable=SC2046
    echo "  kubectl $(kubectl_flag) exec $POD --namespace $NAMESPACE -c workspace -- rm -rf$dirs"
}

# Script run in the pod: $1 pod folder, $2 remote of the workstation folder.
# Exit 3 (remote printed) when the pod folder is a clone of another remote.
workspace_copy_pod_script() {
    cat <<'POD'
[ -e "$1/.git" ] || exit 0
r="$(git -C "$1" remote get-url origin 2>/dev/null || true)"
n() { local u="${1%/}"; echo "${u%.git}"; }
[ "$(n "$r")" = "$(n "$2")" ] && exit 0
echo "${r:-none}"
exit 3
POD
}

# copy-to never overwrites a pod clone of another repository.
copy_guard() {
    local folder="$1" mine other code=0
    mine="$(git -C "$folder" remote get-url origin 2>/dev/null || true)"
    # shellcheck disable=SC2046
    other="$(workspace_copy_pod_script | kubectl $(kubectl_flag) exec -i "$POD" \
        --namespace "$NAMESPACE" -c workspace -- bash -s -- \
        "$PROJECTS_DIR/$(basename "$folder")" "$mine" 2>/dev/null)" || code=$?
    if [ "$code" -eq 3 ]; then
        echo "✖ $PROJECTS_DIR/$(basename "$folder") in the pod is a git clone with another remote ($other, here: ${mine:-none}); not overwritten" >&2
        echo "  work in that clone (devzone workspace clone), or remove it first" >&2
        return 1
    fi
    return 0
}
