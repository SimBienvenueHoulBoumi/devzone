#!/usr/bin/env bash
# Désinstallation complète de devzone, lancée sur l'hôte :
#   make desinstaller                     tout, après confirmation
#   make desinstaller GARDER=connexions   tout sauf les connexions (gh, git,
#                                         Claude Code, opencode, modules)
# Supprime : conteneur, image, volume du Docker interne (images et clusters
# kind), volumes devzone-*, metrics-server installé par devzone sur les
# clusters locaux de l'hôte. Ne touche jamais : workspace/ (tes projets),
# l'image de base, un metrics-server que devzone n'a pas installé.
# Sans terminal : CONFIRMER=oui.
set -euo pipefail

ICI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ETAT="$ICI/.devzone.etat"
GARDER="${GARDER:-}"
CONNEXIONS=(gh git claude opencode-config opencode-data config)
LOCAUX='^(kind-.*|docker-desktop|rancher-desktop|orbstack|minikube)$'

case "$GARDER" in "" | connexions) ;; *)
    echo "GARDER : valeur inconnue : $GARDER (seule valeur : connexions)" >&2
    exit 1
    ;;
esac

# --- Inventaire --------------------------------------------------------------
echo "▶ Inventaire (dossier $ICI)"
conteneurs=() images=() dind=()
# Étiquette posée avec le chemin tel qu'ouvert (VS Code, make) : chemin
# logique ou physique selon les liens symboliques ; les deux sont cherchés
ids="$(for chemin in "$ICI" "$(cd "$ICI" && pwd -P)"; do docker ps -aq --filter "label=devcontainer.local_folder=$chemin"; done | sort -u)"
for id in $ids; do
    conteneurs+=("$id")
    images+=("$(docker inspect "$id" --format '{{.Config.Image}}')")
    v="$(docker inspect "$id" --format '{{range .Mounts}}{{if eq .Destination "/var/lib/docker"}}{{.Name}}{{end}}{{end}}')"
    [ -z "$v" ] || dind+=("$v")
done
# Conteneur déjà supprimé par make down : image et Docker interne notés alors
if [ "${#conteneurs[@]}" -eq 0 ] && [ -f "$ETAT" ]; then
    # Lu, jamais exécuté
    IMAGE="$(sed -n 's/^IMAGE=//p' "$ETAT")"
    DIND="$(sed -n 's/^DIND=//p' "$ETAT")"
    [ -z "${IMAGE:-}" ] || ! docker image inspect "$IMAGE" >/dev/null 2>&1 || images+=("$IMAGE")
    [ -z "${DIND:-}" ] || ! docker volume inspect "$DIND" >/dev/null 2>&1 || dind+=("$DIND")
fi

# Volumes : noms exacts de devcontainer.json (préfixe DEVZONE_VOLUMES compris)
volumes=() gardes=()
config="$(npx -y @devcontainers/cli read-configuration --workspace-folder "$ICI" 2>/dev/null)" || {
    echo "✖ lecture de .devcontainer/devcontainer.json impossible (npx @devcontainers/cli)" >&2
    exit 1
}
# shellcheck disable=SC2016 # ${m.source} : gabarit JavaScript, pas du shell
for nom in $(node -e '
    const c = JSON.parse(require("fs").readFileSync(0, "utf8")).configuration;
    for (const m of c.mounts || []) {
        const s = typeof m === "string" ? m : `source=${m.source},type=${m.type}`;
        if (/type=volume/.test(s)) { const r = /source=([^,]+)/.exec(s); if (r) console.log(r[1]); }
    }' <<<"$config"); do
    docker volume inspect "$nom" >/dev/null 2>&1 || continue
    garde=false
    if [ "$GARDER" = connexions ]; then
        for c in "${CONNEXIONS[@]}"; do [[ "$nom" == *-"$c" ]] && garde=true; done
    fi
    if [ "$garde" = true ]; then gardes+=("$nom"); else volumes+=("$nom"); fi
done

# metrics-server installé par devzone (étiquette devzone=installe), sur les
# clusters locaux de l'hôte joignables ; jamais un autre
metrics=() etrangers=()
if command -v kubectl >/dev/null 2>&1; then
    for ctx in $(kubectl config get-contexts -o name 2>/dev/null | grep -E "$LOCAUX" || true); do
        k=(kubectl --context "$ctx" --request-timeout=5s)
        "${k[@]}" get --raw /readyz >/dev/null 2>&1 || continue
        marque="$("${k[@]}" -n kube-system get deployment metrics-server -o jsonpath='{.metadata.labels.devzone}' 2>/dev/null)" || continue
        if [ "$marque" = installe ]; then metrics+=("$ctx"); else etrangers+=("$ctx"); fi
    done
fi

# --- Confirmation ------------------------------------------------------------
afficher() { if [ "$#" -eq 0 ]; then echo "  (rien)"; else printf '  %s\n' "$@"; fi; }
echo "À supprimer :"
echo " conteneur(s) :"; afficher ${conteneurs[@]+"${conteneurs[@]}"}
echo " image(s) :"; afficher ${images[@]+"${images[@]}"}
echo " Docker interne (images et clusters kind) :"; afficher ${dind[@]+"${dind[@]}"}
echo " volumes :"; afficher ${volumes[@]+"${volumes[@]}"}
echo " metrics-server installé par devzone, sur :"; afficher ${metrics[@]+"${metrics[@]}"}
[ "${#gardes[@]}" -eq 0 ] || { echo "Gardés (GARDER=connexions) :"; printf '  %s\n' "${gardes[@]}"; }
if [ "${#conteneurs[@]}" -eq 0 ] && [ ! -f "$ETAT" ] && [ "${#images[@]}" -eq 0 ]; then
    echo "ℹ Aucun conteneur ni trace de l'image : si un make down d'une version antérieure les a laissés,"
    echo "  les retrouver avec : docker images 'vsc-$(basename "$ICI")-*' ; docker volume ls -q -f name=dind-var-lib-docker"
fi

total=$((${#conteneurs[@]} + ${#images[@]} + ${#dind[@]} + ${#volumes[@]} + ${#metrics[@]}))
if [ "$total" -eq 0 ]; then
    echo "✔ Rien à supprimer."
else
    if [ "${CONFIRMER:-}" != oui ]; then
        if [ ! -t 0 ]; then
            echo "✖ Confirmation impossible sans terminal : CONFIRMER=oui make desinstaller" >&2
            exit 1
        fi
        read -r -p "Supprimer définitivement ? Taper oui : " reponse
        [ "$reponse" = oui ] || { echo "Abandon : rien n'a été supprimé."; exit 0; }
    fi

    # --- Suppression ---------------------------------------------------------
    for id in ${conteneurs[@]+"${conteneurs[@]}"}; do docker rm -f "$id" >/dev/null && echo "✔ conteneur supprimé : $id"; done
    for i in ${images[@]+"${images[@]}"}; do docker rmi "$i" >/dev/null && echo "✔ image supprimée : $i"; done
    for v in ${dind[@]+"${dind[@]}"} ${volumes[@]+"${volumes[@]}"}; do docker volume rm "$v" >/dev/null && echo "✔ volume supprimé : $v"; done
    if [ "${#metrics[@]}" -gt 0 ]; then
        version="$(sed -n 's/^VERSION=//p' "$ICI/.devcontainer/metrics-server.sh")"
        manifeste="https://github.com/kubernetes-sigs/metrics-server/releases/download/${version}/components.yaml"
        for ctx in "${metrics[@]}"; do
            kubectl --context "$ctx" delete -f "$manifeste" --ignore-not-found >/dev/null &&
                echo "✔ metrics-server retiré : $ctx"
        done
    fi
fi
rm -f "$ICI/.devzone.log" "$ETAT"

# --- Ce qui reste ------------------------------------------------------------
echo
echo "Non touché (à retirer toi-même si tu le souhaites) :"
echo "  workspace/ : tes projets"
for ctx in ${etrangers[@]+"${etrangers[@]}"}; do
    echo "  metrics-server sur $ctx : non installé par devzone (kubectl --context $ctx -n kube-system delete deployment metrics-server)"
done
command -v kubectl >/dev/null 2>&1 || echo "  metrics-server : kubectl absent de l'hôte, clusters de l'hôte non vérifiés"
echo "  image de base mcr.microsoft.com/devcontainers/base (partagée) : docker rmi mcr.microsoft.com/devcontainers/base:ubuntu-24.04"
echo "  cache npx du CLI devcontainer : ~/.npm/_npx"
echo "  autorisation « GitHub CLI » sur ton compte : GitHub → Settings → Applications"
echo "  ce dossier : $ICI"
