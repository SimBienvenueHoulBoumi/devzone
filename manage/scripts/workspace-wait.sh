#!/usr/bin/env bash
# Waits for the workspace pod after helm upgrade (#486, #494, #512), sourced by
# manage/workspace.sh: moved here to keep workspace.sh under 250 lines (#515).
# Uses kubectl_flag and helm_flag from workspace.sh.

# Waits for the workspace pod; missing image or slow pod are reported clearly.
wait_for_pod() {
    local image="$1" timeout step start state events arch target_revision pod_revision
    timeout="${DEVZONE_WORKSPACE_ATTENTE:-120}"
    step="${DEVZONE_WORKSPACE_PAS:-2}"
    start="$SECONDS"
    while [ $((SECONDS - start)) -lt "$timeout" ]; do
        # Why: after helm upgrade the pod is still the old one; judge only the revision the StatefulSet is updating to, within the same wait bound.
        # shellcheck disable=SC2046
        target_revision="$(kubectl $(kubectl_flag) get statefulset devzone-workspace --namespace devzone-workspace -o jsonpath='{.status.updateRevision}' 2>/dev/null)" || true
        # shellcheck disable=SC2046
        pod_revision="$(kubectl $(kubectl_flag) get pod devzone-workspace-0 --namespace devzone-workspace -o jsonpath='{.metadata.labels.controller-revision-hash}' 2>/dev/null)" || true
        if [ -z "$target_revision" ] || [ -z "$pod_revision" ] || [ "$target_revision" != "$pod_revision" ]; then sleep "$step"; continue; fi
        # shellcheck disable=SC2046
        state="$(kubectl $(kubectl_flag) get pod devzone-workspace-0 --namespace devzone-workspace \
            -o jsonpath='{.status.phase} {.status.initContainerStatuses[*].state.waiting.reason} {.status.containerStatuses[*].state.waiting.reason}' 2>/dev/null)" || true
        case "$state" in
            *ErrImagePull* | *ImagePullBackOff*)
                # shellcheck disable=SC2046
                events="$(kubectl $(kubectl_flag) get events --namespace devzone-workspace \
                    --field-selector involvedObject.name=devzone-workspace-0 \
                    -o jsonpath='{.items[*].message}' 2>/dev/null)" || true
                case "$events" in
                    *"no match for platform"*)
                        # shellcheck disable=SC2046
                        arch="$(kubectl $(kubectl_flag) get nodes \
                            -o jsonpath='{.items[0].status.nodeInfo.architecture}' 2>/dev/null)" || true
                        echo "✖ image $image has no build for $arch: devzone releases publish it for amd64 and arm64." >&2
                        ;;
                    *)
                        echo "✖ image $image not found: it is published at each devzone release." >&2
                        ;;
                esac
                echo "  For a manually built image: devzone workspace start --image <repository:tag>" >&2
                # shellcheck disable=SC2046
                helm $(helm_flag) uninstall devzone-workspace --namespace devzone-workspace >/dev/null 2>&1 || true
                return 1
                ;;
            Running*)
                echo "✔ workspace started ($image)"
                return 0
                ;;
        esac
        sleep "$step"
    done
    echo "⚠ pod not ready after $timeout s: devzone workspace status" >&2
    return 0
}

# compatibility alias, removed with lot 4 (#509)
attendre_pod() { wait_for_pod "$@"; }
