#!/usr/bin/env bash
# Stale copies in the pod (#558), sourced by manage/workspace.sh:
#   status_workspace  pod status, then the legacy copies still in the pod
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
    echo "  1. save what you need: devzone workspace copy-from <folder>"
    echo "  2. remove them from the pod shell (devzone workspace shell), one folder at a time:"
    for d in $found; do echo "       rm -rf $PROJECTS_DIR/$d"; done
}
