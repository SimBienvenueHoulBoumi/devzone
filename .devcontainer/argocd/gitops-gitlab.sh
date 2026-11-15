#!/usr/bin/env bash
# GitLab as the GitOps repository of Argo CD (#559, step 6): devzone/devzone-argocd
# on the devzone GitLab, written through its API (files endpoint, no clone). The
# repository is designated with provider = gitlab in [argocd] of .argocd.conf;
# the repository URL is the internal one (Argo CD reads it in the cluster).
# The root token is read from workspace/.gitlab/root-token, sent through a curl
# config file (never on the command line) and never printed.
# Sourced by gitops.sh, which dispatches its put, sha, delete and root functions
# here when gitops_is_gitlab holds. The includer defines RACINE, conf_set and
# conf_get (conf.sh). GITLAB_GITOPS_API: base URL of the API seen by this
# process (the relay of the container by default). bash 3.2 (macOS).
#   gitlab_gitops_init              project created by the API, repository designated
#   gitlab_gitops_sha <path>        blob id of a file, empty when absent
#   gitlab_gitops_put <path> <file> <message>   create or update, same blob skipped
#   gitlab_gitops_delete <path> <message>       file removed
#   gitlab_gitops_root_token        the token of the Argo CD repository Secret

GITLAB_GITOPS_GROUP="${GITLAB_GITOPS_GROUP:-devzone}"
GITLAB_GITOPS_PROJECT="${GITLAB_GITOPS_PROJECT:-devzone-argocd}"
GITLAB_GITOPS_BRANCH="${GITLAB_GITOPS_BRANCH:-main}"
GITLAB_GITOPS_API="${GITLAB_GITOPS_API:-http://gitlab.localhost:8929}"
# Internal URL of the repository for Argo CD (the webservice of devzone-gitlab)
GITLAB_GITOPS_URL_INTERNE="${GITLAB_GITOPS_URL_INTERNE:-http://gitlab-webservice-default.devzone-gitlab.svc:8181/$GITLAB_GITOPS_GROUP/$GITLAB_GITOPS_PROJECT.git}"

# Root token of the devzone GitLab; refused when absent (devzone enable gitlab)
gitlab_gitops_root_token() {
    local file="$RACINE/workspace/.gitlab/root-token" token=""
    [ -s "$file" ] && token="$(cat "$file")"
    if [ -z "$token" ]; then
        echo "✖ GitLab root token missing ($file): devzone enable gitlab" >&2
        return 1
    fi
    printf '%s' "$token"
}

# One API call: METHOD PATH [curl options]; the token goes through a config file
# (mode 600, removed right after), so it never shows in the process list
gitlab_gitops_api() {
    local method="$1" path="$2" cfg token rc=0
    shift 2
    token="$(gitlab_gitops_root_token)" || return 1
    cfg="$(mktemp)"
    chmod 600 "$cfg"
    printf 'header = "PRIVATE-TOKEN: %s"\n' "$token" >"$cfg" || { rm -f "$cfg"; return 1; }
    curl -s --config "$cfg" --request "$method" "$GITLAB_GITOPS_API/api/v4$path" "$@" || rc=$?
    rm -f "$cfg"
    return "$rc"
}

# The project path, URL-encoded for the API (devzone%2Fdevzone-argocd)
gitlab_gitops_projet() {
    printf '%s' "$GITLAB_GITOPS_GROUP%2F$GITLAB_GITOPS_PROJECT"
}

# Numeric id of the project, empty when it does not exist
gitlab_gitops_id() {
    gitlab_gitops_api GET "/projects/$(gitlab_gitops_projet)" 2>/dev/null | jq -r '.id // empty' 2>/dev/null || true
}

# A file path URL-encoded for the files endpoint (apps/x.yaml -> apps%2Fx.yaml)
gitlab_gitops_chemin() {
    printf '%s' "$1" | jq -sRr '@uri'
}

# Blob id of a file on the branch (the files endpoint), empty when absent
gitlab_gitops_sha() {
    local id
    id="$(gitlab_gitops_id)"
    [ -n "$id" ] || return 0
    gitlab_gitops_api GET "/projects/$id/repository/files/$(gitlab_gitops_chemin "$1")?ref=$GITLAB_GITOPS_BRANCH" 2>/dev/null |
        jq -r '.blob_id // empty' 2>/dev/null || true
}

# Creates or updates a file: PUT when the file exists, POST when it is new
gitlab_gitops_put() {
    local path="$1" file="$2" message="$3" id sha content verb
    id="$(gitlab_gitops_id)"
    [ -n "$id" ] || { echo "✖ GitLab project $GITLAB_GITOPS_GROUP/$GITLAB_GITOPS_PROJECT missing: devzone argocd init --gitlab" >&2; return 1; }
    sha="$(gitlab_gitops_sha "$path")"
    if [ -n "$sha" ] && [ "$sha" = "$(git hash-object "$file" 2>/dev/null || true)" ]; then
        return 0
    fi
    content="$(base64 <"$file" | tr -d '\n')"
    verb=POST
    [ -z "$sha" ] || verb=PUT
    gitlab_gitops_api "$verb" "/projects/$id/repository/files/$(gitlab_gitops_chemin "$path")" \
        --data-urlencode "branch=$GITLAB_GITOPS_BRANCH" \
        --data-urlencode "encoding=base64" \
        --data-urlencode "content=$content" \
        --data-urlencode "commit_message=$message" >/dev/null
}

# Removes a file on the branch; nothing to do when it is absent
gitlab_gitops_delete() {
    local path="$1" message="$2" id
    id="$(gitlab_gitops_id)"
    [ -n "$id" ] || return 0
    [ -n "$(gitlab_gitops_sha "$path")" ] || return 0
    gitlab_gitops_api DELETE "/projects/$id/repository/files/$(gitlab_gitops_chemin "$path")" \
        --data-urlencode "branch=$GITLAB_GITOPS_BRANCH" \
        --data-urlencode "commit_message=$message" >/dev/null
}

# The group devzone (created by the seed when missing), then the project
# devzone/devzone-argocd with a first commit (README) so that the files can be
# written; the repository is designated in [argocd] (internal URL, provider)
gitlab_gitops_init() {
    local group id
    gitlab_gitops_root_token >/dev/null || return 1
    group="$(gitlab_gitops_api GET "/groups/$GITLAB_GITOPS_GROUP" 2>/dev/null | jq -r '.id // empty' 2>/dev/null || true)"
    if [ -z "$group" ]; then
        group="$(gitlab_gitops_api POST /groups --data-urlencode "name=$GITLAB_GITOPS_GROUP" \
            --data-urlencode "path=$GITLAB_GITOPS_GROUP" --data "visibility=private" 2>/dev/null | jq -r '.id // empty' 2>/dev/null || true)"
    fi
    [ -n "$group" ] || { echo "✖ GitLab group $GITLAB_GITOPS_GROUP not created" >&2; return 1; }
    id="$(gitlab_gitops_id)"
    if [ -z "$id" ]; then
        id="$(gitlab_gitops_api POST /projects --data-urlencode "name=$GITLAB_GITOPS_PROJECT" \
            --data "namespace_id=$group" --data "visibility=private" --data "initialize_with_readme=true" \
            --data-urlencode "default_branch=$GITLAB_GITOPS_BRANCH" 2>/dev/null | jq -r '.id // empty' 2>/dev/null || true)"
        [ -n "$id" ] || { echo "✖ GitLab project $GITLAB_GITOPS_GROUP/$GITLAB_GITOPS_PROJECT not created" >&2; return 1; }
        echo "✔ GitOps repository created on GitLab: $GITLAB_GITOPS_GROUP/$GITLAB_GITOPS_PROJECT (private)"
        gitops_put_text apps/.gitkeep "" "devzone: apps folder"
    fi
    conf_set argocd "repo=$GITLAB_GITOPS_URL_INTERNE" "provider=gitlab"
    echo "✔ GitOps repository: GitLab $GITLAB_GITOPS_GROUP/$GITLAB_GITOPS_PROJECT (internal URL in Argo CD)"
}
