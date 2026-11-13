#!/usr/bin/env bash
# Full devzone uninstall, run on the host:
#   make desinstaller                     everything, after confirmation
#   make desinstaller KEEP=logins         everything except logins (gh, git,
#                                         Claude Code, opencode, modules)
# Removes: container, image, kind clusters of the instance and containers
# labeled devzone.instance on the host Docker (#291), former internal Docker
# volume (installs before #291), devzone-* volumes, metrics-server installed by
# devzone on host local clusters, namespace of devzone services (postgres
# module) on the chosen host cluster. Never touches: workspace/ (your projects),
# the base image, a metrics-server not installed by devzone.
# Without a terminal: CONFIRM=yes.
set -euo pipefail

# devzone folder: two levels above the script (manage/scripts/), so the command
# works when run from any folder
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE="$HERE/.devzone.etat"
KEEP="${KEEP:-${GARDER:-}}"
LOGINS=(gh git claude opencode-config opencode-data config)
LOCAL_CTX='^(kind-.*|docker-desktop|rancher-desktop|orbstack|minikube)$'

case "$KEEP" in "" | logins | connexions) ;; *)
    echo "KEEP: unknown value: $KEEP (only value: logins)" >&2
    exit 1
    ;;
esac

# Docker first: without it every docker call would show its raw error
# shellcheck source=SCRIPTDIR/docker.sh
. "$(dirname "${BASH_SOURCE[0]}")/docker.sh"
docker_ready "${DEVZONE_COMMANDE:-make desinstaller}" || exit 1

# .argocd.conf of the devzone folder: the GitOps repository is never removed
# with the devzone, only its designation can be changed later
# shellcheck disable=SC2034 # read by conf.sh
ARGOCD_CONF="$HERE/.argocd.conf"
# shellcheck source=SCRIPTDIR/../.devcontainer/argocd/conf.sh
# shellcheck disable=SC1091
. "$HERE/.devcontainer/argocd/conf.sh"

# Instance name: an instance name may contain a dash (my-devzone),
# so DEVZONE_VOLUMES is never split
DEVZONE_INSTANCE="${DEVZONE_VOLUMES:-devzone}"
INSTANCE_SUFFIX=""
if [ "$DEVZONE_INSTANCE" != "devzone" ]; then
    INSTANCE_SUFFIX="-${DEVZONE_INSTANCE}"
fi

# Run INSIDE the container, docker talks to host Docker (#291): volumes, images
# and containers seen are those of the workstation, and the host instance name
# (DEVZONE_VOLUMES) is unknown here. Touching Docker from the container could
# remove another instance's resources (or the default instance): only the
# Kubernetes part is handled.
# DEVZONE_DANS_CONTENEUR=yes|no forces the mode (tests, which run inside a container)
case "${DEVZONE_DANS_CONTENEUR:-}" in
    oui | yes) INSIDE_CONTAINER=true ;;
    non | no) INSIDE_CONTAINER=false ;;
    *) INSIDE_CONTAINER=false; [ ! -f /.dockerenv ] || INSIDE_CONTAINER=true ;;
esac

# --- Inventory ---------------------------------------------------------------
echo "▶ Inventory (folder $HERE)"
containers=() images=() dind=() volumes=() kept=()
kind_containers="" labeled_containers=""
if [ "$INSIDE_CONTAINER" = true ]; then
    echo "ℹ Inside the container: only metrics-server and devzone services are handled."
    echo "  Container, image, volumes and kind clusters: make desinstaller on your machine."
else
# Label set with the path as opened (VS Code, make): logical or physical path
# depending on symlinks; both are searched
ids="$(for path in "$HERE" "$(cd "$HERE" && pwd -P)"; do docker ps -aq --filter "label=devcontainer.local_folder=$path" 2>/dev/null || true; done | sort -u)"
for id in ${ids}; do
    containers+=("$id")
    images+=("$(docker inspect "$id" --format '{{.Config.Image}}')")
    v="$(docker inspect "$id" --format '{{range .Mounts}}{{if eq .Destination "/var/lib/docker"}}{{.Name}}{{end}}{{end}}')"
    [ -z "$v" ] || dind+=("$v")
done
# Container already removed by make down: image and internal Docker noted then
if [ "${#containers[@]}" -eq 0 ] && [ -f "$STATE" ]; then
    # Read only, never executed
    IMAGE="$(sed -n 's/^IMAGE=//p' "$STATE")"
    DIND="$(sed -n 's/^DIND=//p' "$STATE")"
    [ -z "${IMAGE:-}" ] || ! docker image inspect "$IMAGE" >/dev/null 2>&1 || images+=("$IMAGE")
    [ -z "${DIND:-}" ] || ! docker volume inspect "$DIND" >/dev/null 2>&1 || dind+=("$DIND")
fi

# Containers of the instance kind clusters on host Docker: a kind cluster is
# nothing more than containers carrying this label
kind_containers_devzone="$(docker ps -aq --filter "label=io.x-k8s.kind.cluster=devzone${INSTANCE_SUFFIX}" 2>/dev/null | sort -u)"
kind_containers_gitlab="$(docker ps -aq --filter "label=io.x-k8s.kind.cluster=gitlab${INSTANCE_SUFFIX}" 2>/dev/null | sort -u)"
kind_containers="${kind_containers_devzone} ${kind_containers_gitlab}"
kind_containers="${kind_containers# }"
kind_containers="${kind_containers% }"

# Containers carrying label devzone.instance=<instance>
labeled_containers="$(docker ps -aq --filter "label=devzone.instance=$DEVZONE_INSTANCE" 2>/dev/null | sort -u)"

# Volumes: exact names from devcontainer.json (including DEVZONE_VOLUMES prefix)
config="$(npx -y @devcontainers/cli read-configuration --workspace-folder "$HERE" 2>/dev/null)" || {
    echo "✖ cannot read .devcontainer/devcontainer.json (npx @devcontainers/cli)" >&2
    exit 1
}
# shellcheck disable=SC2016 # ${m.source}: JavaScript template, not shell
for name in $(node -e '
    const c = JSON.parse(require("fs").readFileSync(0, "utf8")).configuration;
    for (const m of c.mounts || []) {
        const s = typeof m === "string" ? m : `source=${m.source},type=${m.type}`;
        if (/type=volume/.test(s)) { const r = /source=([^,]+)/.exec(s); if (r) console.log(r[1]); }
    }' <<<"$config"); do
    docker volume inspect "$name" >/dev/null 2>&1 || continue
    keep=false
    if [ "$KEEP" = logins ] || [ "$KEEP" = connexions ]; then
        for c in "${LOGINS[@]}"; do [[ "$name" == *-"$c" ]] && keep=true; done
    fi
    if [ "$keep" = true ]; then kept+=("$name"); else volumes+=("$name"); fi
done
fi

# metrics-server installed by devzone (label devzone=installed), on reachable
# host local clusters; never another one
metrics=() foreign=()
if command -v kubectl >/dev/null 2>&1; then
    for ctx in $(kubectl config get-contexts -o name 2>/dev/null | grep -E "$LOCAL_CTX" || true); do
        k=(kubectl --context "$ctx" --request-timeout=5s)
        "${k[@]}" get --raw /readyz >/dev/null 2>&1 || continue
        mark="$("${k[@]}" -n kube-system get deployment metrics-server -o jsonpath='{.metadata.labels.devzone}' 2>/dev/null)" || continue
        if [ "$mark" = installe ] || [ "$mark" = installed ]; then metrics+=("$ctx"); else foreign+=("$ctx"); fi
    done
fi

# devzone services (postgres module, #280) on a host cluster: the namespace it
# created (label managed-by=devzone). On the dedicated kind, they go with that
# cluster (removed below). Read only, never executed.
services=()
CLUSTER="$(sed -n 's/^cluster=//p' "$HERE/.devzone.modules" 2>/dev/null | tail -1 || true)"
if [ -n "$CLUSTER" ] && [[ "$CLUSTER" != kind-* ]] && command -v kubectl >/dev/null 2>&1; then
    for ns in $(kubectl --context "$CLUSTER" --request-timeout=5s get namespaces -l app.kubernetes.io/managed-by=devzone -o name 2>/dev/null || true); do
        services+=("${ns#namespace/}")
    done
fi

# --- Confirmation ------------------------------------------------------------
show_list() { if [ "$#" -eq 0 ]; then echo "  (none)"; else printf '  %s\n' "$@"; fi; }
echo "To remove:"
echo " container(s):"; show_list ${containers[@]+"${containers[@]}"}
echo " image(s):"; show_list ${images[@]+"${images[@]}"}
echo " former internal Docker (installs before #291):"; show_list ${dind[@]+"${dind[@]}"}
echo " volumes:"; show_list ${volumes[@]+"${volumes[@]}"}
echo " metrics-server installed by devzone on:"; show_list ${metrics[@]+"${metrics[@]}"}
echo " devzone services (including postgres databases) on ${CLUSTER:-no cluster}:"; show_list ${services[@]+"${services[@]}"}
echo " kind clusters of the instance on host Docker:"
# shellcheck disable=SC2086
show_list ${kind_containers}
echo " containers labeled devzone.instance=$DEVZONE_INSTANCE:"
# shellcheck disable=SC2086
show_list ${labeled_containers}
[ "${#kept[@]}" -eq 0 ] || { echo "Kept (KEEP=logins):"; printf '  %s\n' "${kept[@]}"; }
if [ "$INSIDE_CONTAINER" = false ] && [ "${#containers[@]}" -eq 0 ] && [ ! -f "$STATE" ] && [ "${#images[@]}" -eq 0 ]; then
    echo "ℹ No container and no image trace: if a make down from an older version left them,"
    echo "  find them with: docker images 'vsc-$(basename "$HERE")-*' ; docker volume ls -q -f name=dind-var-lib-docker"
fi

nb_ck=0; for _ in ${kind_containers}; do nb_ck=$((nb_ck + 1)); done
nb_ce=0; for _ in ${labeled_containers}; do nb_ce=$((nb_ce + 1)); done
total=$((${#containers[@]} + ${#images[@]} + ${#dind[@]} + ${#volumes[@]} + ${#metrics[@]} + ${#services[@]} + nb_ck + nb_ce))
if [ "$total" -eq 0 ]; then
    echo "✔ Nothing to remove."
else
    CONFIRM_VALUE="${CONFIRM:-${CONFIRMER:-}}"
    if [ "$CONFIRM_VALUE" != yes ] && [ "$CONFIRM_VALUE" != oui ]; then
        if [ ! -t 0 ]; then
            echo "✖ Cannot confirm without a terminal: CONFIRM=yes make desinstaller" >&2
            exit 1
        fi
        read -r -p "Permanently remove? Type yes: " answer
        case "$answer" in
            yes | oui) ;;
            *) echo "Canceled: nothing was removed."; exit 0 ;;
        esac
    fi

    # --- Removal -------------------------------------------------------------
    for id in ${containers[@]+"${containers[@]}"}; do docker rm -f "$id" >/dev/null && echo "✔ container removed: $id"; done
    for i in ${images[@]+"${images[@]}"}; do docker rmi "$i" >/dev/null && echo "✔ image removed: $i"; done
    for v in ${dind[@]+"${dind[@]}"} ${volumes[@]+"${volumes[@]}"}; do docker volume rm "$v" >/dev/null && echo "✔ volume removed: $v"; done
    if [ "${#metrics[@]}" -gt 0 ]; then
        version="$(sed -n 's/^VERSION=//p' "$HERE/.devcontainer/metrics-server.sh")"
        manifest="https://github.com/kubernetes-sigs/metrics-server/releases/download/${version}/components.yaml"
        for ctx in "${metrics[@]}"; do
            kubectl --context "$ctx" delete -f "$manifest" --ignore-not-found >/dev/null &&
                echo "✔ metrics-server removed: $ctx"
        done
    fi
    for ns in ${services[@]+"${services[@]}"}; do
        kubectl --context "$CLUSTER" delete namespace "$ns" --wait=true >/dev/null &&
            echo "✔ namespace removed: $ns ($CLUSTER)"
    done
    for id in ${kind_containers}; do
        docker rm -f "$id" >/dev/null 2>&1 && echo "✔ kind cluster container removed: $id"
    done
    # kind Docker network: removed only if no container uses it anymore
    kind_network=""
    [ "$INSIDE_CONTAINER" = true ] || kind_network="$(docker network inspect kind 2>/dev/null || true)"
    if [ -n "$kind_network" ] && printf '%s\n' "$kind_network" | grep -q '"Containers": {}'; then
        if docker network rm kind >/dev/null 2>&1; then
            echo "✔ kind Docker network removed"
        fi
    fi
    for id in ${labeled_containers}; do
        docker rm -f "$id" >/dev/null 2>&1 && echo "✔ labeled container removed: $id"
    done
fi
rm -f "$HERE/.devzone.log" "$STATE"

# Instance module state (one "module=on|off" line): removed, modules return to
# their default values on next start
rm -f "$HERE/.devzone.modules"

# --- What remains ------------------------------------------------------------
echo
echo "Not touched (remove yourself if you want):"
echo "  workspace/: your projects"
for ctx in ${foreign[@]+"${foreign[@]}"}; do
    echo "  metrics-server on $ctx: not installed by devzone (kubectl --context $ctx -n kube-system delete deployment metrics-server)"
done
command -v kubectl >/dev/null 2>&1 || echo "  metrics-server: kubectl not on host, host clusters not checked"
echo "  base image mcr.microsoft.com/devcontainers/base (shared): docker rmi mcr.microsoft.com/devcontainers/base:ubuntu-24.04"
echo "  devcontainer CLI npx cache: ~/.npm/_npx"
echo "  \"GitHub CLI\" authorization on your account: GitHub → Settings → Applications"
ARGOCD_REPO="$(conf_get argocd repo)"
if [ -n "$ARGOCD_REPO" ] && [ "$ARGOCD_REPO" != none ]; then
    echo "  GitOps repository not removed: $ARGOCD_REPO (delete it yourself if you want to)"
fi
echo "  this folder: $HERE"
