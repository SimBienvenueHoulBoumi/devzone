#!/usr/bin/env bash
# Ticket worktrees (#558), in the Kubernetes workspace pod and in the tools
# container:
#   devzone ticket <n> [--repo devzone|repowarden]
#   devzone ticket done <n> [--repo devzone|repowarden]
# In the pod: clone /workspaces/projets/<repo>, worktree
# /workspaces/projets/<repo>-wt/<dz|rw>-<n>. In the tools container: clone
# /workspaces/devzone, worktree workspace/wt/dz-<n> (devzone only).
# DEVZONE_TICKET_PROJECTS and DEVZONE_TICKET_TOOLS move those roots (tests).
set -euo pipefail

PROJECTS="${DEVZONE_TICKET_PROJECTS:-/workspaces/projets}"
TOOLS="${DEVZONE_TICKET_TOOLS:-/workspaces/devzone}"

refuse() { echo "devzone ticket: $*" >&2; exit 2; }

usage() {
    echo "usage: devzone ticket <n> [--repo devzone|repowarden]" >&2
    echo "       devzone ticket done <n> [--repo devzone|repowarden]" >&2
    exit 1
}

# Sets CLONE, WT and BASE (worktree folder prefix) for the repo.
ticket_paths() {
    local repo="$1" n="$2" prefix
    case "$repo" in
        devzone) prefix=dz ;;
        repowarden) prefix=rw ;;
        *) refuse "unknown repo: $repo (devzone or repowarden)" ;;
    esac
    if [ "${DEVZONE_WORKSPACE:-}" = kubernetes ]; then
        CLONE="$PROJECTS/$repo"
        WT="$PROJECTS/$repo-wt/$prefix-$n"
    else
        [ "$repo" = devzone ] || refuse "repo $repo only in the Kubernetes workspace pod"
        CLONE="$TOOLS"
        WT="$TOOLS/workspace/wt/$prefix-$n"
    fi
    [ -e "$CLONE/.git" ] || refuse "no clone in $CLONE (from the workstation: devzone workspace clone <url>)"
}

ticket_start() {
    local n="$1" repo="$2" branch
    ticket_paths "$repo" "$n"
    if [ -e "$WT" ]; then
        echo "worktree already there: $WT"
        echo "$WT"
        return 0
    fi
    git -C "$CLONE" fetch --quiet origin
    mkdir -p "$(dirname "$WT")"
    git -C "$CLONE" worktree add --quiet --detach "$WT" origin/develop
    # repowarden creates the ticket branch from develop and links it
    if ! (cd "$WT" && repowarden ticket "$n"); then
        git -C "$CLONE" worktree remove --force "$WT" || true
        refuse "repowarden ticket $n failed, worktree removed"
    fi
    branch="$(git -C "$WT" branch --show-current)"
    echo "ticket #$n: branch ${branch:-none}"
    echo "$WT"
}

ticket_done() {
    local n="$1" repo="$2" branch
    ticket_paths "$repo" "$n"
    [ -d "$WT" ] || refuse "no worktree for ticket $n: $WT"
    if [ -n "$(git -C "$WT" status --porcelain)" ]; then
        refuse "worktree $WT is not clean, commit or discard first"
    fi
    branch="$(git -C "$WT" branch --show-current)"
    if [ -n "$branch" ] && git -C "$CLONE" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
        refuse "branch $branch still exists on origin: merge the pull request first"
    fi
    git -C "$CLONE" worktree remove "$WT"
    if [ -n "$branch" ]; then git -C "$CLONE" branch -D "$branch" >/dev/null; fi
    echo "ticket #$n: worktree $WT and local branch ${branch:-none} removed"
}

main() {
    local action=start n="" repo=devzone
    [ "${1:-}" != "done" ] || { action="done"; shift; }
    while [ $# -gt 0 ]; do
        case "$1" in
            --repo)
                [ $# -ge 2 ] || usage
                repo="$2"
                shift 2
                ;;
            -*) usage ;;
            *)
                [ -z "$n" ] || usage
                n="$1"
                shift
                ;;
        esac
    done
    case "$n" in '' | *[!0-9]*) usage ;; esac
    if [ "$action" = "done" ]; then ticket_done "$n" "$repo"; else ticket_start "$n" "$repo"; fi
}

main "$@"
