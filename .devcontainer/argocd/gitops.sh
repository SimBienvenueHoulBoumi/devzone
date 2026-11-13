#!/usr/bin/env bash
# GitOps repository of the user for the Argo CD of devzone (#516):
# <login>/devzone-argocd on GitHub, private, written through the GitHub API
# (gh: no clone, no local commit). A root Application "devzone" follows its
# apps/ folder: every Application devzone declares (workspace, services,
# projects) is a file apps/<name>.yaml there, so the cluster is rebuilt from
# Git. Without a repository (gh not logged in, or argocd_repo=none in the
# state), the Applications are applied directly, as before.
#   gitops_init [--repo <url>] [--none]        creates or designates the repository
#   gitops_enabled                             a repository is designated
#   gitops_root                                repository Secret and root Application
#   gitops_apply_application <generator args>  file in Git (or direct apply)
#   gitops_delete_application <name> [keep]    file removed and Application deleted
#   gitops_direct_delete_application <name> [keep]   cluster only, the file stays
# The includer defines argocd_kubectl, APPS_GENERATOR, GITOPS_CMD (how init
# is spelled there) and ARGOCD_CONF (conf.sh): the repository is the key repo
# of the section [argocd] of .argocd.conf.
# Argo CD reads the repository with the gh token of the user
# (DEVZONE_GITOPS_TOKEN for another one). GitLab as the GitOps repository:
# lot B. bash 3.2 (macOS).

GITOPS_NS="devzone-argocd"
GITOPS_ROOT_APP="devzone"
GITOPS_REPO_NAME="${DEVZONE_GITOPS_REPO_NAME:-devzone-argocd}"
: "${GITOPS_CMD:=devzone argocd init}"

gitops_repo() { conf_get argocd repo; }
gitops_repo_note() { conf_set argocd "repo=$1"; }

gitops_enabled() {
    local r
    r="$(gitops_repo)"
    [ -n "$r" ] && [ "$r" != none ]
}

# owner/name of the GitHub repository
gitops_slug() {
    local r
    r="$(gitops_repo)"
    r="${r#https://github.com/}"
    printf '%s' "${r%.git}"
}

# Creates <login>/devzone-argocd when missing (private) and notes its URL;
# --repo: an existing GitHub repository; --none: no GitOps repository,
# Applications applied directly. Without gh logged in: a notice, state kept
gitops_init() {
    local repo="" expect="" arg login slug
    for arg in "$@"; do
        if [ "$expect" = repo ]; then repo="$arg"; expect=""; continue; fi
        case "$arg" in
            --none)
                gitops_repo_note none
                echo "✔ no GitOps repository: the Applications are applied directly ($GITOPS_CMD to change)"
                return 0
                ;;
            --repo) expect=repo ;;
            *) echo "✖ $GITOPS_CMD [--repo https://github.com/<owner>/<name>.git] [--none]" >&2; return 2 ;;
        esac
    done
    if [ -n "$expect" ]; then
        echo "✖ --repo needs a URL" >&2
        return 2
    fi
    if [ -n "$repo" ]; then
        case "$repo" in
            https://github.com/*/*) ;;
            *) echo "✖ GitHub repository URL expected (https://github.com/<owner>/<name>.git): $repo" >&2; return 2 ;;
        esac
        slug="${repo#https://github.com/}"
        slug="${slug%.git}"
        if gh auth status >/dev/null 2>&1 && ! gh repo view "$slug" --json name >/dev/null 2>&1; then
            # The designated GitHub repository does not exist yet: create it,
            # then write the files of a creation
            if ! gh repo create "$slug" --private --description "GitOps repository of devzone: the Applications Argo CD holds (workspace, services, projects)" >/dev/null; then
                echo "✖ cannot create the GitOps repository $slug" >&2
                return 1
            fi
            echo "✔ GitOps repository created: https://github.com/$slug (private)"
            gitops_repo_note "$repo"
            gitops_put_text README.md "# devzone-argocd

GitOps repository of devzone, written by the devzone commands (never by hand): the Argo CD of devzone follows the apps/ folder, one Application per file (the workspace, the services, the projects added with argocd app add). Removing a file removes the Application and its resources.
" "devzone: GitOps repository"
            gitops_put_text apps/.gitkeep "" "devzone: apps folder"
            return 0
        fi
        gitops_repo_note "$repo"
        echo "✔ GitOps repository: $repo ($ARGOCD_CONF)"
        return 0
    fi
    if gitops_enabled; then
        return 0
    fi
    if ! gh auth status >/dev/null 2>&1; then
        echo "ℹ GitHub not connected (gh auth login): no GitOps repository, the Applications are applied directly; $GITOPS_CMD --none to stop this notice"
        return 0
    fi
    login="$(gh api user --jq .login 2>/dev/null)" || login=""
    if [ -z "$login" ]; then
        echo "⚠ GitHub login unreadable (gh api user): Applications applied directly" >&2
        return 0
    fi
    slug="$login/$GITOPS_REPO_NAME"
    if ! gh repo view "$slug" --json name >/dev/null 2>&1; then
        if ! gh repo create "$slug" --private --description "GitOps repository of devzone: the Applications Argo CD holds (workspace, services, projects)" >/dev/null; then
            echo "✖ cannot create the GitOps repository $slug" >&2
            return 1
        fi
        echo "✔ GitOps repository created: https://github.com/$slug (private)"
    fi
    gitops_repo_note "https://github.com/$slug.git"
    gitops_put_text README.md "# devzone-argocd

GitOps repository of devzone, written by the devzone commands (never by hand): the Argo CD of devzone follows the apps/ folder, one Application per file (the workspace, the services, the projects added with argocd app add). Removing a file removes the Application and its resources.
" "devzone: GitOps repository"
    gitops_put_text apps/.gitkeep "" "devzone: apps folder"
}

# Blob sha of a file (git), to skip a write that changes nothing
gitops_blob() { git hash-object "$1" 2>/dev/null || true; }

gitops_sha() {
    gh api "repos/$(gitops_slug)/contents/$1" --jq .sha 2>/dev/null || true
}

# Writes <file> at <path> of the repository (create or update), <message>
gitops_put() {
    local path="$1" file="$2" message="$3" slug sha content
    slug="$(gitops_slug)"
    sha="$(gitops_sha "$path")"
    if [ -n "$sha" ] && [ "$sha" = "$(gitops_blob "$file")" ]; then
        return 0
    fi
    content="$(base64 <"$file" | tr -d '\n')"
    if [ -n "$sha" ]; then
        gh api -X PUT "repos/$slug/contents/$path" -f message="$message" -f content="$content" -f sha="$sha" >/dev/null
    else
        gh api -X PUT "repos/$slug/contents/$path" -f message="$message" -f content="$content" >/dev/null
    fi
}

gitops_put_text() {
    local tmp
    tmp="$(mktemp)"
    printf '%s' "$2" >"$tmp"
    gitops_put "$1" "$tmp" "$3"
    rm -f "$tmp"
}

gitops_delete() {
    local path="$1" message="$2" sha
    sha="$(gitops_sha "$path")"
    [ -n "$sha" ] || return 0
    gh api -X DELETE "repos/$(gitops_slug)/contents/$path" -f message="$message" -f sha="$sha" >/dev/null
}

# Repository Secret (token of gh) and root Application "devzone" on apps/
gitops_root() {
    local url token
    gitops_enabled || return 0
    url="$(gitops_repo)"
    token="${DEVZONE_GITOPS_TOKEN:-$(gh auth token 2>/dev/null || true)}"
    if [ -n "$token" ]; then
        argocd_kubectl -n "$GITOPS_NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: repo-$GITOPS_REPO_NAME
  namespace: $GITOPS_NS
  labels:
    argocd.argoproj.io/secret-type: repository
    app.kubernetes.io/managed-by: devzone
type: Opaque
stringData:
  type: git
  url: $url
  username: devzone
  password: $token
EOF
    else
        echo "⚠ no GitHub token for Argo CD (gh auth token): a private repository will not sync; DEVZONE_GITOPS_TOKEN=<token>" >&2
    fi
    bash "$APPS_GENERATOR" "$GITOPS_ROOT_APP" root "$GITOPS_NS" "$url" HEAD apps |
        argocd_kubectl apply -f - >/dev/null
}

# Argo CD reads Git every 3 min: a refresh of the root Application right away
gitops_refresh() {
    argocd_kubectl -n "$GITOPS_NS" annotate application.argoproj.io "$GITOPS_ROOT_APP" \
        argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
}

gitops_apply_application() {
    local name="$1" tmp
    if ! gitops_enabled; then
        bash "$APPS_GENERATOR" "$@" | argocd_kubectl apply -f - >/dev/null
        return
    fi
    tmp="$(mktemp)"
    if ! bash "$APPS_GENERATOR" "$@" >"$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! gitops_put "apps/$name.yaml" "$tmp" "devzone: application $name"; then
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
    gitops_refresh
}

# keep: finalizer dropped first, the resources stay
gitops_direct_delete_application() {
    local name="$1" mode="${2:-cascade}"
    if [ "$mode" = keep ]; then
        argocd_kubectl -n "$GITOPS_NS" patch application.argoproj.io "$name" --type merge \
            -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
    fi
    argocd_kubectl -n "$GITOPS_NS" delete application.argoproj.io "$name" --ignore-not-found --wait=true >/dev/null
}

# The file leaves Git first (so that the root Application never recreates
# the child), then the Application is deleted right away
gitops_delete_application() {
    local name="$1" mode="${2:-cascade}"
    if gitops_enabled; then
        gitops_delete "apps/$name.yaml" "devzone: application $name removed" || return 1
        gitops_refresh
    fi
    gitops_direct_delete_application "$name" "$mode"
}
