#!/usr/bin/env bash
# Waits for the workspace pod after helm upgrade (#486, #494, #512), sourced by
# manage/workspace.sh: moved here to keep workspace.sh under 250 lines (#515).
# Uses drapeau_kubectl and drapeau_helm from workspace.sh.

# Attend le pod du workspace ; image introuvable ou pod lent sont dits clairement.
attendre_pod() {
    local image="$1" attente pas debut etat evenements arch target_revision pod_revision
    attente="${DEVZONE_WORKSPACE_ATTENTE:-120}"
    pas="${DEVZONE_WORKSPACE_PAS:-2}"
    debut="$SECONDS"
    while [ $((SECONDS - debut)) -lt "$attente" ]; do
        # Why: after helm upgrade the pod is still the old one; judge only the revision the StatefulSet is updating to, within the same wait bound.
        # shellcheck disable=SC2046
        target_revision="$(kubectl $(drapeau_kubectl) get statefulset devzone-workspace --namespace devzone-workspace -o jsonpath='{.status.updateRevision}' 2>/dev/null)" || true
        # shellcheck disable=SC2046
        pod_revision="$(kubectl $(drapeau_kubectl) get pod devzone-workspace-0 --namespace devzone-workspace -o jsonpath='{.metadata.labels.controller-revision-hash}' 2>/dev/null)" || true
        if [ -z "$target_revision" ] || [ -z "$pod_revision" ] || [ "$target_revision" != "$pod_revision" ]; then sleep "$pas"; continue; fi
        # shellcheck disable=SC2046
        etat="$(kubectl $(drapeau_kubectl) get pod devzone-workspace-0 --namespace devzone-workspace \
            -o jsonpath='{.status.phase} {.status.initContainerStatuses[*].state.waiting.reason} {.status.containerStatuses[*].state.waiting.reason}' 2>/dev/null)" || true
        case "$etat" in
            *ErrImagePull* | *ImagePullBackOff*)
                # shellcheck disable=SC2046
                evenements="$(kubectl $(drapeau_kubectl) get events --namespace devzone-workspace \
                    --field-selector involvedObject.name=devzone-workspace-0 \
                    -o jsonpath='{.items[*].message}' 2>/dev/null)" || true
                case "$evenements" in
                    *"no match for platform"*)
                        # shellcheck disable=SC2046
                        arch="$(kubectl $(drapeau_kubectl) get nodes \
                            -o jsonpath='{.items[0].status.nodeInfo.architecture}' 2>/dev/null)" || true
                        echo "✖ image $image sans version pour $arch : les livraisons de devzone la publient pour amd64 et arm64." >&2
                        ;;
                    *)
                        echo "✖ image $image introuvable : elle est publiée à chaque livraison de devzone." >&2
                        ;;
                esac
                echo "  Pour une image construite à la main : devzone workspace demarrer --image <repository:tag>" >&2
                # Application Argo CD ou release helm (#516) : sinon selfHeal recréerait le pod
                workspace_undeploy >/dev/null 2>&1 || true
                return 1
                ;;
            Running*)
                echo "✔ workspace démarré ($image)"
                return 0
                ;;
        esac
        sleep "$pas"
    done
    echo "⚠ pod pas encore prêt après $attente s : devzone workspace etat" >&2
    return 0
}
