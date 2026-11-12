#!/usr/bin/env bash
# Applications of the user's projects in the Argo CD of devzone (#516):
#   argocd_app add <repo url> [path] [--name N] [--revision R] [--namespace NS]
#   argocd_app list
#   argocd_app remove <N>
# Sourced by the container (argocd.sh: kubectl --context devzone) and by the
# workstation (manage/scripts/argocd-services.sh). The includer defines
# argocd_kubectl (kubectl with its context), APPS_GENERATOR (application.sh)
# and APPS_CMD (how the command is spelled there). Application app-<N> in
# devzone-argocd, resources in devzone-app-<N> (created by the sync),
# automated sync with prune and selfHeal. Public repositories only: the
# credentials of private ones are not handled here. bash 3.2 (macOS).

APPS_NS="devzone-argocd"
: "${APPS_CMD:=devzone argocd app}"

apps_usage() {
    echo "usage: $APPS_CMD add <repo url> [path] [--name N] [--revision R] [--namespace NS] | list | remove <N>" >&2
    return 2
}

# Name of an Application from its repository URL: last path element, without
# .git, lowercase, anything else turned into a dash
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

apps_add() {
    local repo="" path="." name="" revision="HEAD" namespace="" arg expect="" pos=0
    for arg in "$@"; do
        if [ -n "$expect" ]; then
            case "$expect" in
                name) name="$arg" ;;
                revision) revision="$arg" ;;
                namespace) namespace="$arg" ;;
            esac
            expect=""
            continue
        fi
        case "$arg" in
            --name) expect=name ;;
            --revision) expect=revision ;;
            --namespace) expect=namespace ;;
            -*)
                echo "✖ $APPS_CMD add: unknown option: $arg" >&2
                apps_usage
                return 2
                ;;
            *)
                pos=$((pos + 1))
                case "$pos" in
                    1) repo="$arg" ;;
                    2) path="$arg" ;;
                    *)
                        echo "✖ $APPS_CMD add: unexpected argument: $arg" >&2
                        apps_usage
                        return 2
                        ;;
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
        *)
            echo "✖ $APPS_CMD add: repository URL expected (https://…): $repo" >&2
            return 2
            ;;
    esac
    [ -n "$name" ] || name="$(apps_name_from_url "$repo")"
    if ! apps_name_valid "$name"; then
        echo "✖ $APPS_CMD add: invalid name: ${name:-(empty)} (lowercase letters, digits, dashes, 40 at most: --name N)" >&2
        return 2
    fi
    [ -n "$namespace" ] || namespace="devzone-app-$name"
    bash "$APPS_GENERATOR" "app-$name" project "$namespace" "$repo" "$revision" "$path" |
        argocd_kubectl apply -f - >/dev/null || return 1
    echo "✔ Application app-$name: $repo ($path, $revision) → namespace $namespace; sync status: $APPS_CMD list"
}

apps_list() {
    argocd_kubectl -n "$APPS_NS" get applications.argoproj.io -l devzone.io/kind=project \
        -o custom-columns='APPLICATION:.metadata.name,REPOSITORY:.spec.source.repoURL,PATH:.spec.source.path,REVISION:.spec.source.targetRevision,NAMESPACE:.spec.destination.namespace,SYNC:.status.sync.status,HEALTH:.status.health.status'
}

# The Application goes with its resources (finalizer); the namespace devzone
# created for it goes too, never one chosen with --namespace
apps_remove() {
    local name="${1:-}" namespace
    if ! apps_name_valid "$name"; then
        echo "✖ $APPS_CMD remove <name> ($APPS_CMD list)" >&2
        return 2
    fi
    namespace="$(argocd_kubectl -n "$APPS_NS" get application.argoproj.io "app-$name" \
        -o jsonpath='{.spec.destination.namespace}' 2>/dev/null)" || namespace=""
    if [ -z "$namespace" ]; then
        echo "✖ $APPS_CMD remove: no Application app-$name ($APPS_CMD list)" >&2
        return 1
    fi
    argocd_kubectl -n "$APPS_NS" delete application.argoproj.io "app-$name" --wait=true >/dev/null || return 1
    case "$namespace" in
        devzone-app-*) argocd_kubectl delete namespace "$namespace" --ignore-not-found --wait=true >/dev/null 2>&1 || true ;;
    esac
    echo "✔ Application app-$name removed with its resources (namespace $namespace)"
}

argocd_app() {
    case "${1:-}" in
        add) apps_add "${@:2}" ;;
        list) apps_list ;;
        remove) apps_remove "${@:2}" ;;
        *) apps_usage ;;
    esac
}
