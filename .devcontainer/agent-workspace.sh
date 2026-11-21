#!/usr/bin/env bash
# Why: outside the pod, devzone agent launches opencode in the Kubernetes workspace
# already started (projects and journals of the pod), or locally with --local; the
# journal of the pod is brought back into that of the workstation (#431).
# Library sourced by agent.sh: no command is launched here.

# True in the workspace container of the cluster, which carries the chart marker.
agent_in_pod() {
    [ "${DEVZONE_WORKSPACE:-}" = kubernetes ]
}

# kubectl of the workstation: devzone context if it exists, then the workspace namespace.
agent_kc() {
    if kubectl config get-contexts -o name 2>/dev/null | grep -qx devzone; then
        kubectl --context devzone --namespace devzone-workspace "$@"
    else
        kubectl --namespace devzone-workspace "$@"
    fi
}

# Why: launching opencode is common to each model attempt, and the kubeconfig
# preparation depends on the Kubernetes workspace; this block lives here with the rest
# of the pod (#431), agent.sh only keeps the model loop.
opencode_launch() {
    local folder="$1" m="$2" brief="$3" journal="$4" state="$5"
    local agent_kube="$state/kubeconfig"
    if agent_in_pod; then
        # In the pod, the limited service account is the only access: no workstation
        # kubeconfig enters the environment of opencode.
        (cd "$folder" && env -u KUBECONFIG DEVZONE_AGENT_SESSION=1 opencode run --print-logs --log-level ERROR --auto -m "$(model_ref "$m")" "$(cat "$brief")" </dev/null >>"$journal" 2>&1) &
    else
        if [ -f "$HOME/.kube/config" ]; then
            (umask 077; KUBECONFIG="$HOME/.kube/config" kubectl config view --minify --flatten --context devzone >"$agent_kube") 2>/dev/null || : >"$agent_kube"
            chmod 600 "$agent_kube"
            [ -s "$agent_kube" ] || echo "=== kubernetes: no devzone context, session without access" >>"$journal"
        else
            : >"$agent_kube"
        fi
        (cd "$folder" && KUBECONFIG="$agent_kube" DEVZONE_AGENT_SESSION=1 opencode run --print-logs --log-level ERROR --auto -m "$(model_ref "$m")" "$(cat "$brief")" </dev/null >>"$journal" 2>&1) &
    fi
}

# True when the pod of the workspace runs and the command comes from the workstation.
workspace_available() {
    if agent_in_pod; then return 1; fi
    local phase
    phase="$(agent_kc get pod devzone-workspace-0 -o jsonpath='{.status.phase}' --request-timeout=5s 2>/dev/null)" || return 1
    [ "$phase" = Running ]
}

# Runs the brief in the pod, then brings its journal back even on failure.
# A /workspaces/projets/... path absent from here designates a folder of the pod
# (clone or worktree of devzone ticket, #558): nothing is copied.
agent_workspace() {
    local folder="$1" brief="$2" name journal code=0 in_pod=""
    local pod_root=/home/vscode/.local/share/devzone
    case "$folder" in
        /workspaces/projets/*) [ -d "$folder" ] || in_pod="$folder" ;;
    esac
    if [ -n "$in_pod" ]; then
        name="$(basename "$in_pod")"
        if ! agent_kc exec devzone-workspace-0 -c workspace -- test -d "$in_pod" 2>/dev/null; then
            refuse "folder not found in the pod: $in_pod (devzone workspace clone, then devzone ticket <n> in the pod)"
        fi
    else
        [ -d "$folder" ] || refuse "folder not found: $folder (searched from $(pwd))"
        name="$(basename "$(cd "$folder" && pwd -P)")"
        in_pod="/workspaces/projets/$name"
        if ! agent_kc exec devzone-workspace-0 -c workspace -- test -d "$in_pod" 2>/dev/null; then
            refuse "project $name missing from the Kubernetes workspace: devzone workspace copy-to $folder (on this machine), or --local"
        fi
    fi
    echo "devzone agent: Kubernetes workspace (pod devzone-workspace-0, $in_pod); --local for the container"
    agent_kc cp "$brief" "devzone-workspace-0:/tmp/devzone-agent-$name.md" -c workspace
    # shellcheck disable=SC2016 # the pod shell expands MODEL_OPT, not this one
    agent_kc exec devzone-workspace-0 -c workspace -- env DEVZONE_ROOT="$pod_root" MODEL_OPT="$MODEL_LIST" bash -lc 'devzone agent ${MODEL_OPT:+--model "$MODEL_OPT"} "$1" "$2"' _ "$in_pod" "/tmp/devzone-agent-$name.md" || code=$?
    journal="$(journal_of "$name")"
    mkdir -p "$(dirname "$journal")"
    if ! agent_kc exec devzone-workspace-0 -c workspace -- cat "$pod_root/workspace/.agents/$name.log" >>"$journal"; then
        echo "=== pod journal not found" >>"$journal"
    fi
    return "$code"
}

agent_help() {
    cat <<'AGENTEOF2'
usage: devzone agent [--model <m>[,<m2>…]] [--local] <folder> <brief-file>
        runs opencode on the brief, free models in rotation
        --model: models tried first, in order, then the rotation
        Kubernetes workspace first if it runs; --local: this container
        a /workspaces/projets/... path absent from here is a folder of the pod, without copy
        devzone agent state [--json]
        known sessions and excluded models
        devzone agent release [<model>|--all]
        lifts a model exclusion
AGENTEOF2
}
