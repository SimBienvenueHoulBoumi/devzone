#!/usr/bin/env bash
# shellcheck shell=bash
# devzone, working cluster: change, use.
# Sourced by .devcontainer/devzone (split of the 1 600 lines file, #722):
# functions only, shared variables are defined in devzone.

# All the databases disappear: confirmation in the terminal (without a terminal,
# the command is explicit); a yes or --yes sets DELETE_DATA, read by
# apply_mysql to run delete-data (#441). The arguments go through reject_renamed:
# --oui is refused before reaching here, only --yes passes (#695).
confirm_removal() {
    local app="$1" answer arg
    DELETE_DATA=""
    [ "$(value_of "$app")" = on ] || return 0
    for arg in "${@:2}"; do
        case "$arg" in --yes) DELETE_DATA=1 ;; esac
    done
    [ -z "$DELETE_DATA" ] || return 0
    cluster_interactive || return 0
    # mysql: the question is about the namespace (volume and databases stay);
    # postgres: everything goes, the refusal cancels; gitlab: the Rails secret
    # stays, its deletion only happens on a full uninstall on purpose
    if [ "$app" = mysql ]; then
        printf 'Disabling mysql removes the server; the volume and databases stay. Also delete the devzone-mysql namespace and its volumes? [y/N] ' >&2
    elif [ "$app" = gitlab ]; then
        printf 'Disabling gitlab keeps the Rails secret (browser sessions stay valid at reinstall). Also delete the Rails secret? [y/N] ' >&2
    else
        printf 'Disabling %s deletes all its databases. Continue? [y/N] ' "$app" >&2
    fi
    read -r answer || answer=""
    case "$answer" in
        y | Y | yes) DELETE_DATA=1; return 0 ;;
    esac
    # refusal: mysql and gitlab still disable (data kept), postgres cancels
    case "$app" in
        mysql | gitlab) return 0 ;;
        *) echo "Aborted: nothing was deleted."; return 1 ;;
    esac
}

# devzone cluster [CTX] [--yes]: shows the services cluster, or moves the
# services to it (uninstalled from the old one, installed on the new one: data
# not migrated, hence the confirmation)
change_cluster() {
    local wanted="" yes="" confirm_ctx="" expect="" arg current new answer ctx_old ctx_new NS
    NS=devzone-postgres
    for arg in "$@"; do
        if [ -n "$expect" ]; then
            confirm_ctx="$arg"
            expect=""
            continue
        fi
        case "$arg" in
            --yes) yes=1 ;;
            --confirm) expect=1 ;;
            -*) echo "devzone : unknown argument: $arg (devzone cluster [CTX] [--yes] [--confirm CTX])" >&2; return 2 ;;
            *) wanted="$arg" ;;
        esac
    done
    if [ -n "$expect" ]; then
        echo "devzone : --confirm expects a context" >&2
        return 2
    fi
    current="$(cluster_saved)"
    if [ -z "$wanted" ]; then
        if [ -z "$current" ]; then
            echo "devzone : no cluster chosen (set when a module is enabled: devzone enable postgres)"
        elif cluster_is_dedicated "$current"; then
            echo "devzone : cluster $current (dedicated kind, in the container)"
        else
            echo "devzone : cluster $current (host cluster)"
        fi
        echo "  possible: $(cluster_candidates | tr '\n' ' ')"
        return 0
    fi
    if [ -n "$confirm_ctx" ]; then
        new="$(cluster_choose "$wanted" --confirm "$confirm_ctx")" || return 2
    else
        new="$(cluster_choose "$wanted")" || return 2
    fi
    if [ "$new" = "$current" ]; then
        echo "devzone : already on $new, nothing to do."
        return 0
    fi
    ctx_old="$current"
    ctx_new="$new"
    if [ "$(value_of postgres)" = on ]; then
        if [ -z "$yes" ]; then
            if ! cluster_interactive; then
                echo "devzone : the postgres databases will be deleted from $ctx_old (not migrated): devzone cluster $ctx_new --yes" >&2
                return 1
            fi
            printf 'postgres will be reinstalled on %s, its databases deleted from %s (not migrated). Continue? [y/N] ' "$ctx_new" "$ctx_old" >&2
            read -r answer || answer=""
            case "$answer" in
                y | Y | yes) ;;
                *) echo "Aborted: nothing changed."; return 0 ;;
            esac
        fi
        # Removes PostgreSQL from the old cluster (explicit context);
        # namespace and RoleBinding by the administrator (#430)
        export KUBECONFIG="$HOME/.kube/config:$HOME/.kube/hote.config"
        account_remove "$ctx_old" "$NS" >/dev/null 2>&1 || true
        account_admin "$ctx_old" delete namespace "$NS" --wait=true >/dev/null 2>&1 || true
        cluster_release "$ctx_old"
        # The new cluster becomes the devzone context
        cluster_save "$ctx_new"
        # Sets the devzone context on the new cluster (cluster + user:
        # important command, failure shown and rendered #396)
        if ! devzone_context_set "$ctx_new"; then
            echo "devzone : cannot set the devzone context on $ctx_new" >&2
            return 1
        fi
        # Installs PostgreSQL on the new cluster (via --context devzone which now points to it)
        devzone postgres install
    else
        cluster_save "$ctx_new"
        # Sets the devzone context on the new cluster (cluster + user:
        # important command, failure shown and rendered #396)
        if ! devzone_context_set "$ctx_new"; then
            echo "devzone : cannot set the devzone context on $ctx_new" >&2
            return 1
        fi
    fi
    echo "devzone : services cluster: $ctx_new"
}

# Switches the user's working cluster (#341). Never touches the devzone services
# cluster: no cluster_save, no cluster= line in the state.
use_cluster() {
    local ctx="" confirm_ctx="" namespace="" answer arg current
    while [ "$#" -gt 0 ]; do
        arg="$1"
        shift
        case "$arg" in
            -n | --namespace)
                if [ "$#" -eq 0 ]; then
                    echo "devzone : -n expects a namespace" >&2
                    return 2
                fi
                namespace="$1"
                shift
                ;;
            --namespace=*) namespace="${arg#*=}" ;;
            --confirm)
                if [ "$#" -eq 0 ]; then
                    echo "devzone : --confirm expects a context" >&2
                    return 2
                fi
                confirm_ctx="$1"
                shift
                ;;
            --confirm=*) confirm_ctx="${arg#*=}" ;;
            -*)
                echo "devzone : unknown argument: $arg (devzone use CTX [-n NS] [--confirm CTX])" >&2
                return 2
                ;;
            *)
                if [ -n "$ctx" ]; then
                    echo "devzone : unknown argument: $arg (devzone use CTX [-n NS] [--confirm CTX])" >&2
                    return 2
                fi
                ctx="$arg"
                ;;
        esac
    done
    if [ -z "$ctx" ]; then
        if [ -z "$namespace" ]; then
            echo "devzone : missing context: devzone use CTX" >&2
            return 2
        fi
        current="$(kubectl config current-context 2>/dev/null || true)"
        if [ -z "$current" ]; then
            echo "devzone : no current context" >&2
            return 2
        fi
        ctx="$current"
    fi
    if ! kubectl config get-contexts -o name 2>/dev/null | grep -qxF -- "$ctx"; then
        echo "devzone : unknown context: $ctx (see kubectl config get-contexts)" >&2
        return 2
    fi
    current="$(kubectl config current-context 2>/dev/null || true)"
    if [ "$ctx" != "$current" ]; then
        if ! cluster_is_local "$ctx"; then
            if [ -n "$confirm_ctx" ]; then
                if [ "$confirm_ctx" != "$ctx" ]; then
                    echo "devzone : remote cluster refused: $ctx (--confirm $ctx)" >&2
                    return 2
                fi
            elif cluster_interactive; then
                printf 'remote cluster: %s; type its name to confirm: ' "$ctx" >&2
                read -r answer || answer=""
                if [ "$answer" != "$ctx" ]; then
                    echo "devzone : remote cluster refused: $ctx (--confirm $ctx)" >&2
                    return 2
                fi
            else
                echo "devzone : remote cluster refused: $ctx (--confirm $ctx)" >&2
                return 2
            fi
        fi
        kubectl config use-context "$ctx" >/dev/null
    fi
    if [ -n "$namespace" ]; then
        kubectl config set-context "$ctx" --namespace "$namespace" >/dev/null
    fi
    echo "working cluster: $ctx"
    [ -z "$namespace" ] || echo "namespace: $namespace"
}
