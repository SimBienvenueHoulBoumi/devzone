#!/usr/bin/env bash
# Ephemeral session pod for devzone agent (#222).
# Sourced by agent.sh: launches the session pod (devzone agent --pod), waits for
# its end, keeps its log, deletes the pod and its ConfigMap, lists session pods (status).
#
# Constraints:
# - bash 3.2 compatible
# - shellcheck -x clean
# - no real cluster: kubectl is faked in tests
# - the pod and its ConfigMap are always deleted (EXIT, INT, TERM trap)

ICI="${ICI:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=agent-pod-manifest.sh disable=SC1091
. "${ICI}/agent-pod-manifest.sh"

# Resources of the current launch, read by the cleanup trap.
AGENT_POD_ACTIVE_NAME=""
AGENT_POD_ACTIVE_MANIFEST=""
AGENT_POD_CLEANED=0

# --- Pod and ConfigMap names ---

agent_pod_name() {
    local base="${1:-}"
    if [ -z "$base" ]; then
        base="${AGENT_POD_SESSION_LABEL:-session}"
    else
        base="$(basename "$base")"
    fi
    # Kubernetes object names must be lowercase.
    base="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')"
    echo "agent-${base}-$RANDOM"
}

agent_pod_configmap_name() {
    echo "$1-consigne"
}

agent_pod_create_configmap() {
    local pod_name="$1" consigne_file="$2"
    kubectl create configmap "$(agent_pod_configmap_name "$pod_name")" \
        --from-file=consigne.md="$consigne_file" >/dev/null 2>&1
}

agent_pod_delete_configmap() {
    local pod_name="$1"
    kubectl delete configmap "$(agent_pod_configmap_name "$pod_name")" >/dev/null 2>&1 || true
}

# --- Create the pod ---

agent_pod_create() {
    local manifest_file="$1"
    kubectl create -f "$manifest_file" >/dev/null 2>&1
}

# --- Wait for the pod to finish ---

agent_pod_wait() {
    local pod_name="$1"
    local elapsed=0
    local max_wait="$DEVZONE_AGENT_POD_TIMEOUT"
    local phase=""

    while [ "$elapsed" -lt "$max_wait" ]; do
        phase="$(kubectl get pod "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null)" || true
        if [ "$phase" = "Succeeded" ] || [ "$phase" = "Failed" ]; then
            echo "$phase"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    phase="$(kubectl get pod "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null)" || true
    echo "${phase:-Unknown}"
    return 1
}

# --- Keep the log of the session ---

agent_pod_fetch_logs() {
    local pod_name="$1" journal_file="$2"
    kubectl logs "$pod_name" >>"$journal_file" 2>/dev/null || true
}

# Last lines of the log on stderr: the cause of a failure is there.
agent_pod_show_tail() {
    local journal_file="$1"
    tail -n 15 "$journal_file" >&2 || true
}

# --- Delete the pod ---

agent_pod_delete() {
    local pod_name="$1"
    kubectl delete pod "$pod_name" >/dev/null 2>&1 || true
}

# --- Status : list session pods with their limits ---

agent_pod_status() {
    kubectl get pods -l "devzone.io/agent-session" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].resources.limits.cpu}{"\t"}{.spec.containers[0].resources.limits.memory}{"\n"}{end}' 2>/dev/null || true
}

# --- Cleanup trap: pod, ConfigMap, temporary manifest (not the log) ---

agent_pod_cleanup() {
    if [ "$AGENT_POD_CLEANED" = 1 ]; then
        return 0
    fi
    AGENT_POD_CLEANED=1
    if [ -n "$AGENT_POD_ACTIVE_NAME" ]; then
        agent_pod_delete "$AGENT_POD_ACTIVE_NAME"
        agent_pod_delete_configmap "$AGENT_POD_ACTIVE_NAME"
    fi
    if [ -n "$AGENT_POD_ACTIVE_MANIFEST" ]; then
        rm -f "$AGENT_POD_ACTIVE_MANIFEST"
    fi
    return 0
}

# Set before any object is created. INT and TERM leave with 130 / 143;
# EXIT keeps the exit code of the script.
agent_pod_set_trap() {
    trap 'agent_pod_cleanup' EXIT
    trap 'agent_pod_cleanup; exit 130' INT
    trap 'agent_pod_cleanup; exit 143' TERM
}

# --- Launch a session agent in an ephemeral pod (devzone agent --pod) ---

agent_pod_lancer() {
    local folder_raw="${1:-}" consigne_raw="${2:-}"
    local folder consigne pod_name journal_file phase manifest_file etat
    local rc=0

    if [ "${DEVZONE_WORKSPACE:-}" != "kubernetes" ]; then
        echo "devzone agent --pod : must be called from the workspace pod (DEVZONE_WORKSPACE=kubernetes)" >&2
        exit 1
    fi

    if ! printf '%s' "$folder_raw" | grep -Eq '^/workspaces/projets/[A-Za-z0-9._/-]+$'; then
        echo "devzone agent --pod : invalid folder path : ${folder_raw:-}" >&2
        exit 1
    fi
    if [ ! -d "$folder_raw" ]; then
        echo "devzone agent --pod : folder not found : $folder_raw" >&2
        exit 1
    fi
    folder="$(cd "$folder_raw" && pwd -P)" || {
        echo "devzone agent --pod : folder not found : $folder_raw" >&2
        exit 1
    }
    if [ ! -r "${consigne_raw:-}" ]; then
        echo "devzone agent --pod : consigne not found : ${consigne_raw:-}" >&2
        exit 1
    fi
    consigne="$(cd "$(dirname "$consigne_raw")" && pwd -P)/$(basename "$consigne_raw")"

    if ! agent_pod_validate_folder "$folder"; then
        exit 1
    fi
    # The pod mounts this file read-only: refuse before any object is created.
    if [ ! -f "$AGENT_POD_MODULES_FILE" ]; then
        echo "devzone agent --pod : modules file missing : $AGENT_POD_MODULES_FILE (run devzone enable ia on the workspace)" >&2
        exit 1
    fi

    # The log of the session stays in the agent state directory (shared with the pod).
    etat="${AGENT_ETAT:-$HOME/.local/state/oc-lancer}"
    mkdir -p "$etat"
    journal_file="$etat/${AGENT_POD_SESSION_LABEL}.pod.log"
    : >"$journal_file"

    pod_name="$(agent_pod_name "$folder")"
    AGENT_POD_ACTIVE_NAME="$pod_name"
    agent_pod_set_trap

    if ! agent_pod_create_configmap "$pod_name" "$consigne"; then
        echo "devzone agent --pod : unable to create the configmap" >&2
        exit 1
    fi

    manifest_file="$(agent_pod_build_manifest "$folder" "$consigne" "$pod_name")" || {
        echo "devzone agent --pod : unable to build the manifest" >&2
        exit 1
    }
    AGENT_POD_ACTIVE_MANIFEST="$manifest_file"

    if ! agent_pod_create "$manifest_file"; then
        echo "devzone agent --pod : unable to create the pod (kubectl create -f)" >&2
        echo "devzone agent --pod : try again without --pod" >&2
        exit 1
    fi

    phase="$(agent_pod_wait "$pod_name")" || rc=$?
    agent_pod_fetch_logs "$pod_name" "$journal_file"
    echo "=== end of agent session in pod (phase: ${phase:-Unknown})" >>"$journal_file"
    agent_pod_show_tail "$journal_file"

    if [ "$rc" -ne 0 ]; then
        echo "devzone agent --pod : pod did not finish in time (phase: ${phase:-Unknown}) ; log : $journal_file" >&2
        exit 1
    fi
    if [ "$phase" = "Failed" ]; then
        echo "devzone agent --pod : session ended in failure ; log : $journal_file" >&2
        exit 1
    fi
    echo "devzone agent --pod : session ended (phase: $phase) ; log : $journal_file" >&2
    exit 0
}
