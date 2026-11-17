#!/usr/bin/env bash
# devzone workspace update [--version X.Y.Z] [--yes] (#622): the workspace moves
# to the latest stable release, or to X.Y.Z: image, charts and Argo CD
# Application at that tag. Sourced by manage/workspace.sh, which defines
# IMAGE_REPO, kube_ready_reason, workspace_deploy, services_reconcile and the
# Argo CD helpers (argocd-workspace.sh, argocd-services.sh).
#   update_workspace [--version X.Y.Z] [--yes]
# Nothing is written before the image of the release is seen on ghcr.io and
# the update is confirmed (--yes is required without a terminal). No gh, no
# Docker: git ls-remote for the tags, curl for the registry. The registry token
# is read into a variable and only sent in a request, never printed. bash 3.2
# (macOS).

# Latest stable release: tags vX.Y.Z only (no pre-release), in version order;
# prints its number without the v, nothing when none is found
update_latest_version() {
    git ls-remote --tags --refs "$DEVZONE_REPO_URL" 2>/dev/null |
        awk '$2 ~ /^refs\/tags\/v[0-9]+\.[0-9]+\.[0-9]+$/ { sub("refs/tags/v", "", $2); print $2 }' |
        sort -V | tail -1
}

# The image of the release on ghcr.io: anonymous pull token, then the manifest
# headers. Status 0 when the image exists; a failing network counts as absent
update_image_exists() {
    local repo_path="${IMAGE_REPO#ghcr.io/}" token
    token="$(curl -fsS "https://ghcr.io/token?scope=repository:$repo_path:pull" 2>/dev/null |
        sed -n 's/.*"token" *: *"\([^"]*\)".*/\1/p')" || token=""
    [ -n "$token" ] || return 1
    curl -fsSI -H "Authorization: Bearer $token" \
        -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json" \
        "https://ghcr.io/v2/$repo_path/manifests/$1" >/dev/null 2>&1
}

# "<targetRevision> <image.tag>" of the Application devzone-workspace; empty
# when there is none (workspace installed with helm direct)
update_current() {
    ak -n "$ARGOCD_NS" get application.argoproj.io "$WORKSPACE_APP" \
        -o jsonpath='{.spec.source.targetRevision} {.spec.source.helm.parameters[?(@.name=="image.tag")].value}' 2>/dev/null || true
}

update_workspace() {
    local version="" yes=no answer
    while [ $# -gt 0 ]; do
        case "$1" in
            --version)
                if [ $# -lt 2 ] || [ -z "$2" ]; then
                    echo "✖ option --version: give X.Y.Z (devzone workspace update [--version X.Y.Z] [--yes])" >&2
                    return 1
                fi
                version="$2"
                shift 2
                ;;
            --yes)
                yes=yes
                shift
                ;;
            *)
                echo "✖ unknown option: $1 (devzone workspace update [--version X.Y.Z] [--yes])" >&2
                return 1
                ;;
        esac
    done
    kube_ready_reason --hint >&2 || return 1
    if [ -n "$version" ]; then
        grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' <<<"$version" || {
            echo "✖ option --version: expected X.Y.Z, got: $version" >&2
            return 1
        }
    else
        version="$(update_latest_version || true)"
        [ -n "$version" ] || {
            echo "✖ no stable release found in $DEVZONE_REPO_URL (network, or no vX.Y.Z tag): nothing changed" >&2
            return 1
        }
    fi
    if ! update_image_exists "$version"; then
        echo "✖ image $IMAGE_REPO:$version not found on ghcr.io (the release may still be publishing, or the network is down): nothing changed" >&2
        return 1
    fi
    if [ "$(update_current)" = "v$version $version" ]; then
        echo "✔ already up to date: v$version"
        return 0
    fi
    echo "⚠ the workspace pod will be recreated: the VS Code windows attached to it will disconnect"
    if [ "$yes" != yes ]; then
        if [ ! -t 0 ]; then
            echo "✖ no terminal to confirm: run again with --yes (devzone workspace update --yes)" >&2
            return 1
        fi
        read -r -p "Update the workspace to v$version? [o/N] " answer || answer=""
        case "$answer" in
            o | O | oui | y | Y | yes) ;;
            *)
                echo "✖ canceled, nothing changed" >&2
                return 1
                ;;
        esac
    fi
    # Same path as workspace start, at the release: Argo CD revision and image tag
    export DEVZONE_ARGOCD_REVISION="v$version"
    workspace_deploy "$IMAGE_REPO" "$version" ""
    if argocd_holds_charts; then
        services_reconcile || return 1
    fi
    echo "✔ workspace on v$version; follow the rollout: devzone workspace status"
}
