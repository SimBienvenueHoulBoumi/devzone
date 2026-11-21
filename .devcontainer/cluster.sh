#!/usr/bin/env bash
# devzone cluster (#280): the cluster where the modules that provide a service
# are deployed (postgres; gitlab with #279). A single choice per instance, kept
# in the state (line « cluster=<kubectl context> »): the services of an instance
# live in the same place and move together (devzone cluster CTX).
# Sourced library: the caller defines RACINE and ETAT.
#   cluster_saved                    chosen context, nothing if there is none
#   cluster_save CTX                 keeps the choice in the state
#   cluster_is_local CTX             0 if local cluster (config, no network)
#   cluster_candidates               local, then dedicated kind, then remote
#   cluster_choose [CTX] [--confirm CTX]
#                                    CTX validated (remote: confirmation),
#                                    otherwise kept choice, otherwise menu
#                                    (terminal only), otherwise local default
#   cluster_prepare CTX              creates the dedicated kind cluster if missing
#   cluster_release CTX              deletes the dedicated kind cluster once empty
#   kube_reachable_from_container FILE   rewrites 127.0.0.1/localhost
#   relay_start NAME CTX NS TARGET PORTS…   port-forward kept alive
#   relay_active NAME / relay_stop NAME
#   account_* (kube-account.sh #430)   limited account and admin context

# Kind and host clusters, as remoteEnv of devcontainer.json: a docker exec or a
# script run outside the container terminal does not have it, and the relay
# must see the host cluster
: "${KUBECONFIG:=$HOME/.kube/config:$HOME/.kube/hote.config}"
export KUBECONFIG

# Module state: defined by the caller; default value for the tests
: "${ETAT:=${DEVZONE_STATE:-$HOME/.devzone.modules}}"

# Safe state write (#417): lock, temporary file in the state folder, backup copy
# .prev — shared by devzone, ports and ports-auto
# shellcheck source=SCRIPTDIR/state.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/state.sh"

# Instance name: empty or « devzone » = default instance (no suffix)
: "${DEVZONE_INSTANCE:=}"
INSTANCE_SUFFIX=""
if [ -n "$DEVZONE_INSTANCE" ] && [ "$DEVZONE_INSTANCE" != "devzone" ]; then
    INSTANCE_SUFFIX="-${DEVZONE_INSTANCE}"
fi

# Dedicated kind cluster, created on the host Docker; name suffixed per instance
CLUSTER_DEDICATED=kind-devzone${INSTANCE_SUFFIX}
# Label set on every namespace created by devzone : a dedicated kind without a
# labelled namespace has no use left and can be deleted
CLUSTER_LABEL=app.kubernetes.io/managed-by=devzone

# Rewrite 127.0.0.1 → host.docker.internal (#291): shared with the kind wrapper,
# which applies it too to clusters created by hand
# shellcheck source=SCRIPTDIR/kube-reachable.sh
. "$(dirname "${BASH_SOURCE[0]}")/kube-reachable.sh"

# Limited Kubernetes account (#430): account_setup, account_allow,
# account_remove, account_token, account_admin (admin context); the installers
# use it, cluster_release too
# shellcheck source=SCRIPTDIR/kube-account.sh
. "$(dirname "${BASH_SOURCE[0]}")/kube-account.sh"

cluster_saved() {
    grep -E '^cluster=' "$ETAT" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

cluster_save() {
    state_write cluster "$1"
}

cluster_is_dedicated() {
    [ "$1" = "${CLUSTER_DEDICATED}" ]
}

# Local cluster: read from the KUBECONFIG configuration, without network call.
# The dedicated kind is always local; a host cluster is local when its server
# listens on a loopback address (127.0.0.1, localhost, ::1, host.docker.internal).
cluster_is_local() {
    local ctx="$1" cluster server host
    cluster_is_dedicated "$ctx" && return 0
    cluster="$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$ctx\")].context.cluster}" 2>/dev/null || true)"
    [ -n "$cluster" ] || return 1
    server="$(kubectl config view -o jsonpath="{.clusters[?(@.name==\"$cluster\")].cluster.server}" 2>/dev/null || true)"
    [ -n "$server" ] || return 1
    # Rule by name (old rule of metrics-server.sh)
    case "$ctx" in
        kind-* | docker-desktop | rancher-desktop | orbstack | minikube) return 0 ;;
    esac
    # Host extraction (IPv6 addresses in brackets handled)
    host="${server#*://}"
    host="${host%%/*}"
    if [[ "$host" == \[* ]]; then
        host="${host#[}"
        host="${host%%]*}"
    else
        host="${host%%:*}"
    fi
    case "$host" in
        127.0.0.1 | localhost | ::1 | host.docker.internal) return 0 ;;
        *-control-plane) return 0 ;;
    esac
    return 1
}

# Sets the « devzone » context (cluster + user) on the given context (default:
# the current one): after an installation on a new machine, --context devzone
# targets the chosen services cluster from the start (#396)
devzone_context_set() {
    local ctx cluster user
    ctx="${1:-$(kubectl config current-context 2>/dev/null || true)}"
    if [ -z "$ctx" ]; then
        return 1
    fi
    cluster="$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$ctx\")].context.cluster}" 2>/dev/null || true)"
    user="$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$ctx\")].context.user}" 2>/dev/null || true)"
    if [ -n "$cluster" ]; then
        kubectl config set-context devzone --cluster="$cluster" --user="$user" >/dev/null 2>&1
    else
        return 1
    fi
}

cluster_reachable() {
    kubectl --context "$1" --request-timeout=3s get --raw /readyz >/dev/null 2>&1
}

# Host contexts: local ones first, then the dedicated kind, finally the remote ones
cluster_candidates() {
    local host="${DEVZONE_KUBE_HOST:-$HOME/.kube/hote.config}" c
    if [ -f "$host" ]; then
        # 1. Local clusters of the host (server on a loopback address)
        for c in $(KUBECONFIG="$host" kubectl config get-contexts -o name 2>/dev/null); do
            cluster_is_dedicated "$c" && continue
            if cluster_is_local "$c" && cluster_reachable "$c"; then
                echo "$c"
            fi
        done
    fi
    # 2. Dedicated kind cluster
    echo "$CLUSTER_DEDICATED"
    if [ -f "$host" ]; then
        # 3. Remote clusters of the host
        for c in $(KUBECONFIG="$host" kubectl config get-contexts -o name 2>/dev/null); do
            cluster_is_dedicated "$c" && continue
            if ! cluster_is_local "$c" && cluster_reachable "$c"; then
                echo "$c"
            fi
        done
    fi
    return 0
}

# Menu on stderr (stdout carries the answer); Enter = first candidate
cluster_menu() {
    local candidates=() c i=1 answer
    while IFS= read -r c; do candidates+=("$c"); done < <(cluster_candidates)
{
        echo "devzone : on which cluster should the devzone services be installed?"
        for c in "${candidates[@]}"; do
            if cluster_is_dedicated "$c"; then
                echo "  $i) $c   dedicated kind cluster, in the container (default)"
            elif cluster_is_local "$c"; then
                echo "  $i) $c   local cluster"
            else
                echo "  $i) $c   remote cluster"
            fi
            i=$((i + 1))
        done
        [ -f "${DEVZONE_KUBE_HOST:-$HOME/.kube/hote.config}" ] ||
            echo "  (host clusters not visible: devzone enable kubernetes)"
    } >&2
    printf 'Number [1]: ' >&2
    read -r answer || answer=""
    answer="${answer:-1}"
    case "$answer" in
        *[!0-9]* | 0) echo "devzone : invalid choice: $answer" >&2; return 2 ;;
    esac
    if [ "$answer" -gt "${#candidates[@]}" ]; then
        echo "devzone : invalid choice: $answer" >&2
        return 2
    fi
    echo "${candidates[$((answer - 1))]}"
}

# Interactive terminal; DEVZONE_INTERACTIVE=1 for the tests (stdin redirected)
cluster_interactive() {
    [ "${DEVZONE_INTERACTIVE:-}" = 1 ] || [ -t 0 ]
}

cluster_choose() {
    local wanted="" confirm="" c answer arg
    while [ "$#" -gt 0 ]; do
        arg="$1"
        shift
        case "$arg" in
            --confirm)
                if [ "$#" -eq 0 ]; then
                    echo "devzone : --confirm needs a context" >&2
                    return 2
                fi
                confirm="$1"
                shift
                ;;
            --confirm=*) confirm="${arg#*=}" ;;
            -*)
                echo "devzone : unknown argument: $arg (cluster_choose [CTX] [--confirm CTX])" >&2
                return 2
                ;;
            *)
                if [ -n "$wanted" ]; then
                    echo "devzone : unknown argument: $arg (cluster_choose [CTX] [--confirm CTX])" >&2
                    return 2
                fi
                wanted="$arg"
                ;;
        esac
    done
    if [ -n "$wanted" ]; then
        while IFS= read -r c; do
            [ "$c" = "$wanted" ] && break
        done < <(cluster_candidates)
        if [ "$c" != "$wanted" ]; then
            echo "devzone : unknown or unreachable cluster: $wanted; candidates: $(cluster_candidates | tr '\n' ' ')" >&2
            return 2
        fi
        # Remote: confirmation required. --confirm counts only if it is exactly
        # the requested context; DEVZONE_CLUSTER_REMOTE is still accepted for
        # the tests and CI
        if ! cluster_is_local "$wanted"; then
            if [ -n "$confirm" ]; then
                if [ "$confirm" != "$wanted" ]; then
                    echo "devzone : remote cluster refused: $wanted (--confirm $wanted)" >&2
                    return 2
                fi
            elif [ -n "${DEVZONE_CLUSTER_REMOTE:-}" ]; then
                if [ "${DEVZONE_CLUSTER_REMOTE}" != "$wanted" ]; then
                    echo "devzone : remote cluster refused: $wanted (DEVZONE_CLUSTER_REMOTE must be exactly $wanted)" >&2
                    return 2
                fi
            elif cluster_interactive; then
                printf 'remote cluster: %s ; type its name to confirm: ' "$wanted" >&2
                read -r answer || answer=""
                if [ "$answer" != "$wanted" ]; then
                    echo "devzone : remote cluster refused: $wanted (--confirm $wanted)" >&2
                    return 2
                fi
            else
                echo "devzone : remote cluster refused: $wanted (--confirm $wanted)" >&2
                return 2
            fi
        fi
        echo "$wanted"
        return 0
    fi
    c="$(cluster_saved)"
    if [ -n "$c" ]; then
        echo "$c"
    elif cluster_interactive; then
        cluster_menu
    else
        # Default: local only (never remote by default)
        local host_choice=""
        if [ -f "${DEVZONE_KUBE_HOST:-$HOME/.kube/hote.config}" ]; then
            host_choice="$(KUBECONFIG="${DEVZONE_KUBE_HOST:-$HOME/.kube/hote.config}" kubectl config current-context 2>/dev/null || true)"
        fi
        if [ -n "$host_choice" ] && cluster_is_local "$host_choice" && cluster_reachable "$host_choice"; then
            echo "$host_choice"
        else
            echo "$CLUSTER_DEDICATED"
        fi
    fi
}

# Runs kind without switching kubectl's current context (#366): the previous
# one is restored, or removed if there was none. The kind exit code is returned
# even under set -e: the restore happens first.
kind_keep_context() {
    local previous code=0
    previous="$(kubectl config current-context 2>/dev/null || true)"
    kind "$@" || code=$?
    if [ -n "$previous" ]; then
        kubectl config use-context "$previous" >/dev/null 2>&1 || true
    else
        KUBECONFIG="$HOME/.kube/config" kubectl config unset current-context >/dev/null 2>&1 || true
    fi
    return "$code"
}

# Creates a kind cluster without switching kubectl's current context.
kind_create_keep_context() {
    kind_keep_context create cluster "$@"
}

cluster_prepare() {
    local ctx="$1"
    if [ "$ctx" = "$CLUSTER_DEDICATED" ]; then
        if ! kind get clusters 2>/dev/null | grep -qx "devzone${INSTANCE_SUFFIX}"; then
            echo "▶ Creating the kind devzone cluster (about 1 min)…"
            # On the host Docker, the API listens on the workstation's 127.0.0.1:
            # kube_reachable_from_container makes it reachable from the container
            # (host.docker.internal), without exposing it on the local network.
            # Busy host Docker (its Kubernetes, other clusters): the node API can
            # restart during initialization and kind gives up within seconds. A
            # second attempt, on a fresh cluster.
            if ! kind_create_keep_context --name "devzone${INSTANCE_SUFFIX}" --wait 120s; then
                echo "▶ Retrying the kind cluster creation…"
                kind delete cluster --name "devzone${INSTANCE_SUFFIX}" >/dev/null 2>&1 || true
                kind_create_keep_context --name "devzone${INSTANCE_SUFFIX}" --wait 120s || return 1
            fi
            kube_reachable_from_container "$HOME/.kube/config"
        fi
    elif ! cluster_reachable "$ctx"; then
        echo "devzone : cluster $ctx unreachable (kubernetes module enabled? cluster started?)" >&2
        return 1
    fi
    # If it has just been created, the services cluster must carry the devzone
    # context at once, otherwise the installation targets the old cluster (#396)
    devzone_context_set "$ctx" || echo "devzone : devzone context not set on $ctx" >&2
}

# Dedicated kind with no devzone namespace left: deleted (it only uses memory).
# Never a host cluster.
cluster_release() {
    local ctx="$1" left
    cluster_is_dedicated "$ctx" || return 0
    kind get clusters 2>/dev/null | grep -qx "devzone${INSTANCE_SUFFIX}" || return 0
    # Reading the namespaces labelled by the administrator (#430): the namespace
    # list is refused to the limited account
    left="$(account_admin "$ctx" get namespaces -l "$CLUSTER_LABEL" -o name 2>/dev/null || true)"
    if [ -z "$left" ]; then
        kind delete cluster --name "devzone${INSTANCE_SUFFIX}" >/dev/null 2>&1 || true
        echo "▶ kind devzone cluster removed (no service left)."
    fi
}

# ---- Relay: port of a cluster service on the container's 127.0.0.1 ----
# kubectl port-forward works on every cluster whose API answers (dedicated kind
# or host cluster), without exposing a port on the nodes. It stops when the pod
# restarts: the loop restarts it. PID and log in workspace/.<name>/ (module
# folder, ignored by git).
relay_dir() {
    echo "$RACINE/workspace/.$1"
}

relay_active() {
    local pid
    pid="$(cat "$(relay_dir "$1")/relais.pid" 2>/dev/null || true)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

relay_start() {
    local name="$1" ctx="$2" ns="$3" target="$4" dir
    shift 4
    dir="$(relay_dir "$name")"
    mkdir -p "$dir"
    relay_active "$name" && return 0
    # setsid: separate session, the relay survives the end of the script that
    # started it (postStartCommand, make shell); absent on macOS (bash 3.2 tests)
    local detached=()
    command -v setsid >/dev/null 2>&1 && detached=(setsid)
    # port-forward targets one precise pod and sees its disappearance only at the
    # next connection, which fails. For a service, the loop therefore follows the
    # ready pod behind it (UID in its endpoints): waits until there is one, then
    # restarts port-forward as soon as it changes (pod restarted).
    # shellcheck disable=SC2016 # variables expanded by the relay's bash
    ${detached[@]+"${detached[@]}"} nohup bash -c '
        pod() {
            case "$2" in
                svc/*) kubectl --context "$0" -n "$1" get endpoints "${2#svc/}" -o jsonpath="{.subsets[*].addresses[*].targetRef.uid}" 2>/dev/null ;;
                *) echo fixe ;;
            esac
        }
        while :; do
            until [ -n "$(pod "$@")" ]; do sleep 2; done
            actuel="$(pod "$@")"
            kubectl --context "$0" -n "$1" port-forward --address 127.0.0.1 "$2" "${@:3}" &
            pf=$!
            while kill -0 "$pf" 2>/dev/null; do
                sleep 5
                [ "$(pod "$@")" = "$actuel" ] || { kill "$pf" 2>/dev/null; break; }
            done
            wait "$pf" 2>/dev/null
            sleep 1
        done' \
        "$ctx" "$ns" "$target" "$@" >"$dir/relais.log" 2>&1 &
    echo "$!" >"$dir/relais.pid"
}

relay_stop() {
    local file pid children
    file="$(relay_dir "$1")/relais.pid"
    pid="$(cat "$file" 2>/dev/null || true)"
    if [ -n "$pid" ]; then
        # Children (port-forward) listed before: once the loop is killed, they
        # are reattached to init and pgrep -P no longer sees them. The loop first,
        # otherwise it would restart the port-forward.
        children="$(pgrep -P "$pid" 2>/dev/null || true)"
        kill "$pid" 2>/dev/null || true
        # shellcheck disable=SC2086 # list of PIDs
        [ -z "$children" ] || kill $children 2>/dev/null || true
    fi
    rm -f "$file"
}
