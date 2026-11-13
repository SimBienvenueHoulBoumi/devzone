#!/usr/bin/env bash
# Applications of the user's projects in the Argo CD of devzone (#516),
# declared in .argocd.conf (conf.sh) and reconciled:
#   argocd_app add <repo url> [path] [--name N] [--revision R] [--namespace NS] [--token T] [--username U]
#   argocd_app list
#   argocd_app remove <N>
#   apps_reconcile      every [app N] of .argocd.conf applied, the others removed
# Sourced by the container (argocd.sh: kubectl --context devzone) and by the
# workstation (manage/scripts/argocd-services.sh), after conf.sh and
# gitops.sh. The includer defines argocd_kubectl, APPS_GENERATOR, APPS_CMD,
# ARGOCD_CONF and ARGOCD_CONF_DIR (the devzone folder: token-file paths are
# relative to it), and may define apps_gitlab_token (root token of the
# devzone GitLab, on stdout).
# Application app-<N> in devzone-argocd, resources in devzone-app-<N>. GitHub
# or any public repository: nothing else. A private one: --token (kept in
# workspace/.argocd/tokens/<N>, 600, out of Git) or token-file, and username
# (root by default), in a repository Secret, never in the Application. The
# GitLab of devzone: its gitlab.localhost URL is rewritten to the service of
# the cluster, the root token of the module is used unless a token is given,
# and the NetworkPolicy of devzone-gitlab lets the devzone namespaces in.
# bash 3.2 (macOS).

APPS_NS="devzone-argocd"
: "${APPS_CMD:=devzone argocd app}"
: "${APPS_GITLAB_NS:=devzone-gitlab}"

apps_usage() {
    echo "usage: $APPS_CMD add <repo url> [path] [--name N] [--revision R] [--namespace NS] [--token T] [--username U] | list | remove <N>" >&2
    return 2
}

apps_name_from_url() {
    local n="$1"
    n="${n%/}"
    n="${n##*/}"
    n="${n%.git}"
    printf '%s' "$n" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed 's/^-*//; s/-*$//'
}

apps_name_valid() {
    case "${1:-}" in
        '' | *[!a-z0-9-]* | -*) return 1 ;;
    esac
    [ "${#1}" -le 40 ]
}

apps_is_devzone_gitlab() {
    case "$1" in
        http://gitlab.localhost:8929/* | http://gitlab.localhost/* | https://gitlab.localhost/* | https://gitlab.localhost:*/*) return 0 ;;
    esac
    return 1
}

# Address Argo CD reaches: the webservice of the GitLab namespace
apps_repo_internal() {
    local url="$1" path
    if apps_is_devzone_gitlab "$url"; then
        path="${url#*://gitlab.localhost}"
        case "$path" in :*) path="/${path#*/}" ;; esac
        printf 'http://gitlab-webservice-default.%s.svc:8181%s' "$APPS_GITLAB_NS" "$path"
    else
        printf '%s' "$url"
    fi
}

# Token of an app: its token-file (relative to the devzone folder), else the
# root token of the devzone GitLab for a devzone GitLab repository
apps_token_of() {
    local file="$1" repo="$2"
    if [ -n "$file" ]; then
        case "$file" in /*) cat "$file" 2>/dev/null ;; *) cat "$ARGOCD_CONF_DIR/$file" 2>/dev/null ;; esac
        return 0
    fi
    apps_is_devzone_gitlab "$repo" || return 0
    if command -v apps_gitlab_token >/dev/null 2>&1; then
        apps_gitlab_token
    else
        cat "$ARGOCD_CONF_DIR/workspace/.gitlab/root-token" 2>/dev/null
    fi
}

apps_repo_secret() {
    local name="$1" url="$2" username="$3" token="$4"
    argocd_kubectl -n "$APPS_NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: repo-$name
  namespace: $APPS_NS
  labels:
    argocd.argoproj.io/secret-type: repository
    app.kubernetes.io/managed-by: devzone
type: Opaque
stringData:
  type: git
  url: $url
  username: $username
  password: $token
EOF
}

# Ingress of the GitLab namespace opened to the devzone namespaces (Argo CD
# repo-server among them): same rule as devzone postgres autoriser
apps_gitlab_allow_argocd() {
    argocd_kubectl -n "$APPS_GITLAB_NS" patch networkpolicy devzone-meme-namespace --type merge \
        -p '{"spec":{"ingress":[{"from":[{"podSelector":{},"namespaceSelector":{"matchLabels":{"app.kubernetes.io/managed-by":"devzone"}}}]}]}}' >/dev/null 2>&1 ||
        echo "⚠ NetworkPolicy of $APPS_GITLAB_NS not opened to Argo CD: devzone postgres autoriser $APPS_NS, or the sync will fail" >&2
}

# One [app N] of .argocd.conf applied: Secret when a token exists, then the Application
apps_apply_one() {
    local name="$1" repo path revision namespace username file token url
    repo="$(conf_get "app $name" repo)"
    if [ -z "$repo" ]; then
        echo "⚠ [app $name] without repo in $ARGOCD_CONF: skipped" >&2
        return 0
    fi
    path="$(conf_get "app $name" path)"; path="${path:-.}"
    revision="$(conf_get "app $name" revision)"; revision="${revision:-HEAD}"
    namespace="$(conf_get "app $name" namespace)"; namespace="${namespace:-devzone-app-$name}"
    username="$(conf_get "app $name" username)"; username="${username:-root}"
    file="$(conf_get "app $name" token-file)"
    url="$(apps_repo_internal "$repo")"
    token="$(apps_token_of "$file" "$repo")"
    if apps_is_devzone_gitlab "$repo"; then
        if [ -z "$token" ]; then
            echo "✖ [app $name]: token of the devzone GitLab not found (workspace/.gitlab/root-token or token-file)" >&2
            return 1
        fi
        apps_gitlab_allow_argocd
    fi
    if [ -n "$token" ]; then
        apps_repo_secret "$name" "$url" "$username" "$token" || return 1
    fi
    gitops_apply_application "app-$name" project "$namespace" "$url" "$revision" "$path" || return 1
    echo "✔ Application app-$name: $url ($path, $revision) → namespace $namespace${token:+; credentials in the Secret repo-$name}"
}

# An Application leaves the cluster with its resources, its repository
# Secret and the namespace devzone created for it (never one chosen by hand)
apps_purge() {
    local name="$1" namespace
    namespace="$(argocd_kubectl -n "$APPS_NS" get application.argoproj.io "app-$name" \
        -o jsonpath='{.spec.destination.namespace}' 2>/dev/null)" || namespace=""
    gitops_delete_application "app-$name" || return 1
    argocd_kubectl -n "$APPS_NS" delete secret "repo-$name" --ignore-not-found >/dev/null 2>&1 || true
    case "$namespace" in
        devzone-app-*) argocd_kubectl delete namespace "$namespace" --ignore-not-found --wait=true >/dev/null 2>&1 || true ;;
    esac
    echo "✔ Application app-$name removed with its resources${namespace:+ (namespace $namespace)}"
}

# Every [app N] applied, the project Applications absent from the file removed
apps_reconcile() {
    local name declared=" " app code=0
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        declared="$declared$name "
        apps_apply_one "$name" || code=1
    done <<<"$(conf_sections app)"
    while IFS= read -r app; do
        [ -n "$app" ] || continue
        app="${app#*/}"
        app="${app#app-}"
        case "$declared" in *" $app "*) continue ;; esac
        apps_purge "$app" || code=1
    done <<<"$(argocd_kubectl -n "$APPS_NS" get applications.argoproj.io -l devzone.io/kind=project -o name 2>/dev/null || true)"
    return "$code"
}

apps_add() {
    local repo="" path="" name="" revision="" namespace="" token="" username=""
    local arg expect="" pos=0 keys file
    for arg in "$@"; do
        if [ -n "$expect" ]; then
            case "$expect" in
                name) name="$arg" ;; revision) revision="$arg" ;; namespace) namespace="$arg" ;;
                token) token="$arg" ;; username) username="$arg" ;;
            esac
            expect=""
            continue
        fi
        case "$arg" in
            --name) expect=name ;;
            --revision) expect=revision ;;
            --namespace) expect=namespace ;;
            --token) expect=token ;;
            --username) expect=username ;;
            -*) echo "✖ $APPS_CMD add: unknown option: $arg" >&2; apps_usage; return 2 ;;
            *)
                pos=$((pos + 1))
                case "$pos" in
                    1) repo="$arg" ;;
                    2) path="$arg" ;;
                    *) echo "✖ $APPS_CMD add: unexpected argument: $arg" >&2; apps_usage; return 2 ;;
                esac
                ;;
        esac
    done
    if [ -n "$expect" ]; then
        echo "✖ $APPS_CMD add: --$expect needs a value" >&2
        return 2
    fi
    [ -n "$repo" ] || { apps_usage; return 2; }
    case "$repo" in
        https://* | http://* | ssh://* | git@*) ;;
        *) echo "✖ $APPS_CMD add: repository URL expected (https://…): $repo" >&2; return 2 ;;
    esac
    [ -n "$name" ] || name="$(apps_name_from_url "$repo")"
    if ! apps_name_valid "$name"; then
        echo "✖ $APPS_CMD add: invalid name: ${name:-(empty)} (lowercase letters, digits, dashes, 40 at most: --name N)" >&2
        return 2
    fi
    if apps_is_devzone_gitlab "$repo" && [ -z "$token" ] && [ -z "$(apps_token_of "" "$repo")" ]; then
        echo "✖ $APPS_CMD add: token of the devzone GitLab not found (workspace/.gitlab/root-token): --token T" >&2
        return 2
    fi
    keys="repo=$repo path=${path:-.} revision=${revision:-HEAD} namespace=${namespace:-devzone-app-$name}"
    [ -z "$username" ] || keys="$keys username=$username"
    if [ -n "$token" ]; then
        # The token stays out of the file and out of Git: workspace/ is ignored
        file="workspace/.argocd/tokens/$name"
        mkdir -p "$ARGOCD_CONF_DIR/workspace/.argocd/tokens"
        chmod 700 "$ARGOCD_CONF_DIR/workspace/.argocd" "$ARGOCD_CONF_DIR/workspace/.argocd/tokens"
        (umask 077 && printf '%s' "$token" >"$ARGOCD_CONF_DIR/$file")
        keys="$keys token-file=$file"
    fi
    # shellcheck disable=SC2086
    conf_set "app $name" $keys
    apps_apply_one "$name" || return 1
    echo "  declared in $ARGOCD_CONF; sync status: $APPS_CMD list"
}

apps_list() {
    argocd_kubectl -n "$APPS_NS" get applications.argoproj.io -l devzone.io/kind=project \
        -o custom-columns='APPLICATION:.metadata.name,REPOSITORY:.spec.source.repoURL,PATH:.spec.source.path,REVISION:.spec.source.targetRevision,NAMESPACE:.spec.destination.namespace,SYNC:.status.sync.status,HEALTH:.status.health.status'
}

apps_remove() {
    local name="${1:-}"
    if ! apps_name_valid "$name"; then
        echo "✖ $APPS_CMD remove <name> ($APPS_CMD list)" >&2
        return 2
    fi
    if ! argocd_kubectl -n "$APPS_NS" get application.argoproj.io "app-$name" >/dev/null 2>&1 &&
        ! conf_sections app | grep -qx -- "$name"; then
        echo "✖ $APPS_CMD remove: no Application app-$name ($APPS_CMD list)" >&2
        return 1
    fi
    conf_remove "app $name"
    rm -f "$ARGOCD_CONF_DIR/workspace/.argocd/tokens/$name"
    apps_purge "$name"
}

argocd_app() {
    case "${1:-}" in
        add) apps_add "${@:2}" ;;
        list) apps_list ;;
        remove) apps_remove "${@:2}" ;;
        *) apps_usage ;;
    esac
}
