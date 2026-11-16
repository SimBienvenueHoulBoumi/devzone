#!/usr/bin/env bash
# Module llm (#586): local code model (llama.cpp llama-server, CPU) in the
# cluster of the services, namespace devzone-llm, chart charts/devzone-llm.
#   llm.sh install [--preset default|light] [--context CTX]
#   llm.sh uninstall           release removed, the volume llm-models is kept
#   llm.sh status | relay-start | relay-stop | policy (ingress from devzone-workspace)
#   llm.sh preset [--preset P] preset stored for the next install (Argo CD path)
#   llm.sh apply on|off [...]  what `devzone enable|disable llm` runs
#   llm.sh delete-data [--yes] namespace and volume removed (the model is downloaded again)
#   llm.sh bench [--apply]     llama-bench Job and threads recommendation (bench.sh)
# First start = model download: LLM_ATTENTE (seconds, default 1800) is the wait.
# Relay LLM_PORT (default 8089); opencode provider: opencode.sh. bash 3.2 (macOS).
set -euo pipefail

ICI="$(cd "$(dirname "$0")" && pwd)"
RACINE="${DEVZONE_RACINE:-$(dirname "$(dirname "$ICI")")}"
# shellcheck disable=SC2034 # read by cluster.sh (sourced library)
ETAT="${DEVZONE_ETAT:-$RACINE/.devzone.modules}"
# shellcheck source=SCRIPTDIR/../cluster.sh
# shellcheck disable=SC1091
. "$ICI/../cluster.sh"
# shellcheck source=SCRIPTDIR/../chart-direct.sh
# shellcheck disable=SC1091
. "$ICI/../chart-direct.sh"
# shellcheck source=SCRIPTDIR/../isolement.sh
# shellcheck disable=SC1091
. "$ICI/../isolement.sh"
# shellcheck source=SCRIPTDIR/presets.sh
# shellcheck disable=SC1091
. "$ICI/presets.sh"
# shellcheck source=SCRIPTDIR/bench.sh
# shellcheck disable=SC1091
. "$ICI/bench.sh"
# Memory check of the services cluster, shared with the other modules (#608)
# shellcheck source=SCRIPTDIR/../memoire.sh
# shellcheck disable=SC1091
. "$ICI/../memoire.sh"

NS=devzone-llm
STATE_DIR="$RACINE/workspace/.llm"
LLM_PORT="${LLM_PORT:-8089}"
LLM_ATTENTE="${LLM_ATTENTE:-1800}"
LLM_SIZE="${LLM_SIZE:-8Gi}"

refuse() { echo "devzone: llm: $*" >&2; exit 2; }

k() { kubectl --context devzone -n "$NS" "$@"; }

installed() { compte_admin "$(compte_ctx)" get namespace "$NS" >/dev/null 2>&1; }

# Preset stored by the last install, "default" without one
preset_read() {
    local p
    p="$(cat "$STATE_DIR/preset" 2>/dev/null || true)"
    llm_preset_name "$p" 2>/dev/null || echo default
}

# --preset P and --context C of the arguments: PRESET and WANTED_CTX are set
parse_args() {
    local want="" arg
    PRESET=""
    WANTED_CTX=""
    for arg in "$@"; do
        if [ -n "$want" ]; then
            case "$want" in
                preset) PRESET="$arg" ;;
                context) WANTED_CTX="$arg" ;;
            esac
            want=""
            continue
        fi
        case "$arg" in
            --preset) want=preset ;;
            --context) want=context ;;
            *) refuse "unknown argument: $arg (devzone enable llm [--preset light] [--context CTX])" ;;
        esac
    done
    [ -z "$want" ] || refuse "--$want needs a value"
    if [ -n "$PRESET" ]; then
        PRESET="$(llm_preset_name "$PRESET")" || refuse "unknown preset (default or light)"
    fi
}

# Stores the preset: the explicit one, else the one already stored
preset_store() {
    parse_args "$@"
    [ -n "$PRESET" ] || PRESET="$(preset_read)"
    mkdir -p "$STATE_DIR"
    printf '%s\n' "$PRESET" >"$STATE_DIR/preset"
}

# Ingress from the workspace namespace (the pod of the workspace reaches
# llm:8080), next to the same-namespace rule of namespace_isoler
policy() {
    kubectl --context devzone -n "$NS" apply -f - >/dev/null <<YAML
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: devzone-llm-workspace
  labels:
    app.kubernetes.io/managed-by: devzone
spec:
  podSelector: {}
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: devzone-workspace
YAML
}

# Waits for the deployment, a progress line each minute (the model is
# downloaded on the first start)
wait_ready() {
    local waited=0 step=60
    echo "▶ Waiting for the model (first start: download, several minutes; timeout ${LLM_ATTENTE}s, LLM_ATTENTE)…"
    while [ "$waited" -lt "$LLM_ATTENTE" ]; do
        if k rollout status deployment/llm --timeout="${step}s" >/dev/null 2>&1; then
            return 0
        fi
        waited=$((waited + step))
        echo "  … ${waited}s/${LLM_ATTENTE}s: model not ready yet"
    done
    echo "devzone: llm: not ready after ${LLM_ATTENTE}s: kubectl --context devzone -n $NS logs deploy/llm -c fetch-model" >&2
    return 1
}

install() {
    local ctx sets minimum_go=12 astuce=""
    local -a args

    preset_store "$@"
    # The light preset (3B) asks for 8 Gi, the 7B model for 12 Gi
    if [ "$(preset_read)" = light ]; then
        minimum_go=8
    else
        astuce="--preset light (8 Go)"
    fi
    verifier_memoire_module llm "$minimum_go" "$astuce" || return 2

    ctx="$(cluster_lu)"
    if [ -z "$ctx" ]; then
        ctx="$(cluster_choisir "$WANTED_CTX")" || return 2
        cluster_ecrire "$ctx"
    fi
    cluster_preparer "$ctx"
    contexte_devzone_poser "$ctx" || { echo "devzone: llm: cannot set the devzone context on $ctx" >&2; return 1; }
    echo "▶ Local model on the cluster $ctx (namespace $NS, preset $(preset_read))…"
    compte_namespace "$ctx" "$NS"
    namespace_isoler "$NS" >/dev/null
    policy
    sets="$(llm_preset_sets "$(preset_read)") size=$LLM_SIZE"
    read -r -a args <<<"$sets"
    chart_install llm "$NS" "${args[@]}" || return 1
    wait_ready || return 1
    relais_arreter llm
    relais_lancer llm "$ctx" "$NS" svc/llm "$LLM_PORT:8080"
    bash "$ICI/opencode.sh" set
    echo "✔ Local model ready: http://llm.$NS.svc.cluster.local:8080/v1 (127.0.0.1:$LLM_PORT here)"
}

# The release leaves, the volume (model) and the namespace stay
uninstall() {
    local ctx
    ctx="$(cluster_lu)"
    relais_arreter llm
    bash "$ICI/opencode.sh" unset
    if [ -n "$ctx" ] && installed; then
        contexte_devzone_poser "$ctx" || true
        helm --kube-context devzone uninstall llm -n "$NS" >/dev/null 2>&1 || true
        echo "✔ llm removed from $ctx; volume llm-models kept (devzone llm delete-data removes it)"
    fi
}

delete_data() {
    local ctx yes="" answer
    ctx="$(cluster_lu)"
    [ "${1:-}" != --yes ] || yes=1
    installed || { echo "devzone: llm: nothing to delete"; return 0; }
    if [ -z "$yes" ]; then
        cluster_interactif || refuse "no terminal: devzone llm delete-data --yes"
        printf 'Delete the namespace %s and the downloaded model? [y/N] ' "$NS" >&2
        read -r answer || answer=""
        case "$answer" in y | Y | yes | o | O | oui) ;; *) echo "Aborted: nothing deleted."; return 0 ;; esac
    fi
    uninstall
    compte_retirer "$ctx" "$NS" >/dev/null 2>&1 || true
    compte_admin "$ctx" delete namespace "$NS" --wait=true >/dev/null
    cluster_liberer "$ctx"
    echo "✔ namespace $NS and model volume deleted"
}

status() {
    local ctx mem
    ctx="$(cluster_lu)"
    if [ -z "$ctx" ] || ! installed; then
        echo "disabled"
        return 0
    fi
    if [ "$(k get deployment llm -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)" != 1 ]; then
        echo "not ready on $ctx: starting (first download) or failed, devzone apply"
        return 0
    fi
    mem="$(k get deployment llm -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}' 2>/dev/null || true)"
    if relais_actif llm; then
        echo "ready on $ctx: $(llm_preset_file "$(preset_read)"), memory limit ${mem:-?}, reachable 127.0.0.1:$LLM_PORT"
    else
        echo "ready on $ctx: $(llm_preset_file "$(preset_read)"), memory limit ${mem:-?}, relay stopped: devzone apply"
    fi
}

relay_start() {
    local ctx
    ctx="$(cluster_lu)"
    [ -z "$ctx" ] || ! installed || relais_lancer llm "$ctx" "$NS" svc/llm "$LLM_PORT:8080"
}

# Writes llm=off in the state file (bad argument, no cluster)
state_off() {
    [ -f "$ETAT" ] || return 0
    grep -v '^llm=' "$ETAT" >"$ETAT.tmp" || true
    echo "llm=off" >>"$ETAT.tmp"
    mv "$ETAT.tmp" "$ETAT"
}

# What `devzone enable|disable llm` runs: on installs (or restarts the relay),
# off removes the release; a failure leaves a marker read by devzone status
apply() {
    local action="${1:-}" current marker="$ETAT-echec-llm"
    shift || true
    if [ "$action" = on ]; then
        current="$(status)"
        if [[ "$current" == *"relay stopped"* ]]; then
            relay_start
            echo "devzone: llm: relay restarted"
        elif [[ "$current" == "ready on"* ]]; then
            bash "$ICI/opencode.sh" set && echo "devzone: llm already active, nothing to do."
        elif ! bash "${BASH_SOURCE[0]}" install "$@"; then
            state_off
            echo llm >"$marker"
            return 1
        fi
        rm -f "$marker"
    else
        uninstall
        rm -f "$marker"
    fi
}

case "${1:-}" in
    install) install "${@:2}" ;;
    uninstall) uninstall ;;
    status) status ;;
    preset) preset_store "${@:2}" ;;
    policy) policy ;;
    apply) apply "${@:2}" ;;
    delete-data) delete_data "${2:-}" ;;
    bench) bench "${@:2}" ;;
    relay-start) relay_start ;;
    relay-stop) relais_arreter llm ;;
    *) echo "devzone llm: status | bench [--apply] | delete-data [--yes]" >&2; exit 1 ;;
esac
