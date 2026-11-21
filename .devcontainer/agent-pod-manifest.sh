#!/usr/bin/env bash
# Manifest and validation helpers for the ephemeral session pod (#222).
# Sourced by agent-pod.sh.
# bash 3.2 compatible ; shellcheck -x clean.
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/agent-pod-egress.sh"

# --- Defaults ---

DEVZONE_AGENT_POD_ACTIVE_DEADLINE_SECONDS="${DEVZONE_AGENT_POD_ACTIVE_DEADLINE_SECONDS:-1800}"
DEVZONE_AGENT_POD_CPU_LIMIT="${DEVZONE_AGENT_POD_CPU_LIMIT:-2}"
DEVZONE_AGENT_POD_MEM_LIMIT="${DEVZONE_AGENT_POD_MEM_LIMIT:-4Gi}"
DEVZONE_AGENT_POD_TIMEOUT="${DEVZONE_AGENT_POD_TIMEOUT:-$((DEVZONE_AGENT_POD_ACTIVE_DEADLINE_SECONDS + 120))}"
# Projects root, read by the launcher only (no trailing slash). The pod keeps
# /workspaces/projets in its own environment (DEVZONE_ROOT in the manifest).
AGENT_POD_ROOT="${DEVZONE_ROOT:-/workspaces/projets}"
# Module state file on the workspace volume (subPath .devzone.modules, read-only in the pod).
# shellcheck disable=SC2034 # read by agent-pod.sh
AGENT_POD_MODULES_FILE="${DEVZONE_AGENT_POD_MODULES_FILE:-${AGENT_POD_ROOT}/.devzone.modules}"

# --- Path check : under AGENT_POD_ROOT, only [A-Za-z0-9._/-], no . or .. part ---

agent_pod_path_ok() {
    printf '%s' "$AGENT_POD_ROOT" | grep -Eq '^/[A-Za-z0-9._/-]*[A-Za-z0-9._-]$' || return 1
    case "$1" in "$AGENT_POD_ROOT"/*) ;; *) return 1 ;; esac
    printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._/-]+$' || return 1
    case "$1/" in */./* | */../* | *//*) return 1 ;; esac
    return 0
}

# --- State filled by agent_pod_validate_folder ---

AGENT_POD_WORKTREE_SUBPATH=""
AGENT_POD_WORKTREE_MOUNTPATH=""
AGENT_POD_GIT_SUBPATH=""
AGENT_POD_GIT_MOUNTPATH=""
AGENT_POD_SESSION_LABEL=""
AGENT_POD_TICKET=""

# --- Helpers : read the workspace pod (devzone-workspace-0, container workspace) ---

agent_pod_image_workspace() {
    local result
    result="$(kubectl get pod devzone-workspace-0 -o jsonpath='{.spec.containers[?(@.name=="workspace")].image}' 2>/dev/null)" || true
    echo "${result:-ghcr.io/simbienvenuehoulboumi/devzone-workspace:latest}"
}

agent_pod_path_workspace() {
    local result
    result="$(kubectl get pod devzone-workspace-0 -o jsonpath='{.spec.containers[?(@.name=="workspace")].env[?(@.name=="PATH")].value}' 2>/dev/null)" || true
    echo "${result:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
}

agent_pod_pvc_workspace() {
    local result
    result="$(kubectl get pod devzone-workspace-0 -o jsonpath='{.spec.volumes[?(@.name=="workspace")].persistentVolumeClaim.claimName}' 2>/dev/null)" || true
    echo "${result:-workspace-devzone-workspace-0}"
}

agent_pod_pvc_etat() {
    local result
    result="$(kubectl get pod devzone-workspace-0 -o jsonpath='{.spec.volumes[?(@.name=="etat")].persistentVolumeClaim.claimName}' 2>/dev/null)" || true
    echo "${result:-etat-devzone-workspace-0}"
}

# --- Validation of the folder to session ---

agent_pod_validate_folder() {
    local folder="$1" gitfile gitdir common base
    if [ -z "$folder" ]; then
        echo "devzone agent --pod : folder missing" >&2
        return 1
    fi
    case "$folder" in
        "$AGENT_POD_ROOT"/*) ;;
        *)
            echo "devzone agent --pod : folder outside the projects root $AGENT_POD_ROOT : $folder" >&2
            return 1
            ;;
    esac
    if ! agent_pod_path_ok "$folder"; then
        echo "devzone agent --pod : invalid folder path : $folder" >&2
        return 1
    fi
    gitfile="$folder/.git"
    if [ ! -f "$gitfile" ]; then
        echo "devzone agent --pod : no .git file (not a git worktree) : $folder" >&2
        return 1
    fi
    gitdir="$(grep '^gitdir:' "$gitfile" 2>/dev/null | head -1 | sed 's/^gitdir:[[:space:]]*//;s/[[:space:]]*$//')"
    if [ -z "$gitdir" ]; then
        echo "devzone agent --pod : .git without gitdir line : $folder" >&2
        return 1
    fi
    case "$gitdir" in
        */worktrees/*) common="${gitdir%/worktrees/*}" ;;
        *)
            echo "devzone agent --pod : gitdir is not a worktree : $gitdir" >&2
            return 1
            ;;
    esac
    case "$common" in
        "$AGENT_POD_ROOT"/*) ;;
        *)
            echo "devzone agent --pod : worktree depot outside the projects root $AGENT_POD_ROOT : $common" >&2
            return 1
            ;;
    esac
    if ! agent_pod_path_ok "$common"; then
        echo "devzone agent --pod : invalid depot path : $common" >&2
        return 1
    fi
    base="$(basename "$folder")"
    if ! printf '%s' "$base" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$'; then
        echo "devzone agent --pod : invalid label value : $base" >&2
        return 1
    fi
    if [ "${#base}" -gt 63 ]; then
        echo "devzone agent --pod : label value too long : $base" >&2
        return 1
    fi
    AGENT_POD_WORKTREE_MOUNTPATH="$folder"
    AGENT_POD_WORKTREE_SUBPATH="${folder#"$AGENT_POD_ROOT"/}"
    AGENT_POD_GIT_MOUNTPATH="$common"
    AGENT_POD_GIT_SUBPATH="${common#"$AGENT_POD_ROOT"/}"
    AGENT_POD_SESSION_LABEL="$base"
    # Keep the ticket only for an exact dz-<number> name.
    if ! printf '%s' "$base" | grep -Eq '^dz-[0-9]+$'; then
        AGENT_POD_TICKET=""
    else
        AGENT_POD_TICKET="${base#dz-}"
    fi
    return 0
}

# --- Build the session pod manifest ---

agent_pod_build_manifest() {
    # $2 (the brief) is never written here: it only goes to the ConfigMap.
    local folder="$1" pod_name="$3"
    local ws_image ws_path pvc_workspace pvc_etat manifest_file ticket_block=""

    ws_image="$(agent_pod_image_workspace)"
    ws_path="$(agent_pod_path_workspace)"
    pvc_workspace="$(agent_pod_pvc_workspace)"
    pvc_etat="$(agent_pod_pvc_etat)"

    if [ -n "$AGENT_POD_TICKET" ]; then
        ticket_block="    devzone.io/agent-ticket: \"${AGENT_POD_TICKET}\""
    fi

    manifest_file="$(mktemp "${TMPDIR:-/tmp}/devzone-agent-pod-manifest.XXXXXX.yaml")"; egress_mode="$(agent_pod_egress_mode)"

    {
        printf '%s\n' "apiVersion: v1"
        printf '%s\n' "kind: Pod"
        printf '%s\n' "metadata:"
        printf '%s\n' "  name: ${pod_name}"
        printf '%s\n' "  labels:"
        printf '%s\n' "    devzone.io/agent-session: ${AGENT_POD_SESSION_LABEL}"
        if [ -n "$ticket_block" ]; then
            printf '%s\n' "$ticket_block"
        fi
        printf '%s\n' "spec:"
        agent_pod_egress_init_lines "$egress_mode" "$ws_image"
        printf '%s\n' "  restartPolicy: Never"
        printf '%s\n' "  activeDeadlineSeconds: ${DEVZONE_AGENT_POD_ACTIVE_DEADLINE_SECONDS}"
        printf '%s\n' "  automountServiceAccountToken: false"
        printf '%s\n' "  securityContext:"
        printf '%s\n' "    runAsUser: 1000"
        printf '%s\n' "    runAsGroup: 1000"
        printf '%s\n' "    runAsNonRoot: true"
        printf '%s\n' "    fsGroup: 1000"
        printf '%s\n' "  affinity:"
        printf '%s\n' "    podAffinity:"
        printf '%s\n' "      requiredDuringSchedulingIgnoredDuringExecution:"
        printf '%s\n' "      - labelSelector:"
        printf '%s\n' "          matchExpressions:"
        printf '%s\n' "          - key: statefulset.kubernetes.io/pod-name"
        printf '%s\n' "            operator: In"
        printf '%s\n' "            values:"
        printf '%s\n' "            - devzone-workspace-0"
        printf '%s\n' "        topologyKey: kubernetes.io/hostname"
        printf '%s\n' "  containers:"
        printf '%s\n' "  - name: agent"
        printf '%s\n' "    image: ${ws_image}"
        printf '%s\n' "    env:"
        printf '%s\n' "    - name: HOME"
        printf '%s\n' "      value: \"/home/vscode\""
        printf '%s\n' "    - name: NPM_CONFIG_PREFIX"
        printf '%s\n' "      value: \"/home/vscode/.local/npm\""
        printf '%s\n' "    - name: PATH"
        printf '%s\n' "      value: \"${ws_path}\""
        printf '%s\n' "    - name: DEVZONE_WORKSPACE"
        printf '%s\n' "      value: \"kubernetes\""
        printf '%s\n' "    - name: DEVZONE_ROOT"
        printf '%s\n' "      value: \"/workspaces/projets\""; agent_pod_egress_manifest_lines "$egress_mode"
        printf '%s\n' "    resources:"
        printf '%s\n' "      limits:"
        printf '%s\n' "        cpu: ${DEVZONE_AGENT_POD_CPU_LIMIT}"
        printf '%s\n' "        memory: ${DEVZONE_AGENT_POD_MEM_LIMIT}"
        printf '%s\n' "    volumeMounts:"
        printf '%s\n' "    - name: workspace"
        printf '%s\n' "      mountPath: ${AGENT_POD_WORKTREE_MOUNTPATH}"
        printf '%s\n' "      subPath: ${AGENT_POD_WORKTREE_SUBPATH}"
        printf '%s\n' "    - name: workspace"
        printf '%s\n' "      mountPath: ${AGENT_POD_GIT_MOUNTPATH}"
        printf '%s\n' "      subPath: ${AGENT_POD_GIT_SUBPATH}"
        printf '%s\n' "    - name: workspace"
        printf '%s\n' "      mountPath: /workspaces/projets/.devzone.modules"
        printf '%s\n' "      subPath: .devzone.modules"
        printf '%s\n' "      readOnly: true"
        printf '%s\n' "    - name: etat"
        printf '%s\n' "      mountPath: /home/vscode/.config/opencode"
        printf '%s\n' "      subPath: .config/opencode"
        printf '%s\n' "    - name: etat"
        printf '%s\n' "      mountPath: /home/vscode/.local/share/opencode"
        printf '%s\n' "      subPath: .local/share/opencode"
        printf '%s\n' "    - name: etat"
        printf '%s\n' "      mountPath: /home/vscode/.local/state/oc-lancer"
        printf '%s\n' "      subPath: .local/state/oc-lancer"
        printf '%s\n' "    - name: etat"
        printf '%s\n' "      mountPath: /home/vscode/.local/npm"
        printf '%s\n' "      subPath: .local/npm"
        printf '%s\n' "      readOnly: true"
        printf '%s\n' "    - name: consigne"
        printf '%s\n' "      mountPath: /agent-consigne"
        printf '%s\n' "      readOnly: true"
        printf '%s\n' "    - name: session-workspace"
        printf '%s\n' "      mountPath: /workspaces/projets/workspace"
        printf '%s\n' "    command: [\"/bin/bash\", \"-lc\"]"
        printf '%s\n' "    args:"
        printf '%s\n' "    - 'devzone agent --local ${folder} /agent-consigne/consigne.md; code=\$?; cat \"\$DEVZONE_ROOT/workspace/.agents/${AGENT_POD_SESSION_LABEL}.log\" 2>/dev/null; exit \$code'"
        printf '%s\n' "  volumes:"
        printf '%s\n' "  - name: workspace"
        printf '%s\n' "    persistentVolumeClaim:"
        printf '%s\n' "      claimName: ${pvc_workspace}"
        printf '%s\n' "  - name: etat"
        printf '%s\n' "    persistentVolumeClaim:"
        printf '%s\n' "      claimName: ${pvc_etat}"
        printf '%s\n' "  - name: consigne"
        printf '%s\n' "    configMap:"
        printf '%s\n' "      name: ${pod_name}-consigne"
        printf '%s\n' "  - name: session-workspace"
        printf '%s\n' "    emptyDir:"
        printf '%s\n' "      sizeLimit: 256Mi"
    } >"$manifest_file"

    echo "$manifest_file"
}
