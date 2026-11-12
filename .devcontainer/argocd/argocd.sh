#!/usr/bin/env bash
# Module argocd (#411) : Argo CD dans le cluster des services de devzone.
#   argocd.sh installer | desinstaller | etat | relais-lancer | relais-arreter
#   argocd.sh app add <repo url> [path] [--name N] [--revision R] | app list | app remove <N>
# Namespace devzone-argocd isolé, relais 127.0.0.1:8443 dans le conteneur.
# Mot de passe admin dans workspace/.argocd/admin.env (600), repris dans
# .password ; jamais affiché.
set -euo pipefail

ICI="$(cd "$(dirname "$0")" && pwd)"
RACINE="${DEVZONE_RACINE:-$(dirname "$(dirname "$ICI")")}"
# shellcheck disable=SC2034 # lu par cluster.sh (bibliothèque sourcée)
ETAT="${DEVZONE_ETAT:-$RACINE/.devzone.modules}"
# shellcheck source=SCRIPTDIR/../cluster.sh
# shellcheck disable=SC1091
. "$ICI/../cluster.sh"
# shellcheck source=SCRIPTDIR/../password.sh
# shellcheck disable=SC1091
. "$ICI/../password.sh"
# Isolation réseau : namespace_isoler, posée avec le namespace devzone-argocd
# shellcheck source=SCRIPTDIR/../isolement.sh
# shellcheck disable=SC1091
. "$ICI/../isolement.sh"

NS=devzone-argocd
SECRETS="$RACINE/workspace/.argocd"
# Version figée du chart argo-cd, port du relais et attente d'installation
ARGOCD_VERSION="${ARGOCD_VERSION:-10.14.0}"
ARGOCD_PORT="${ARGOCD_PORT:-8443}"
ARGOCD_ATTENTE="${ARGOCD_ATTENTE:-600}"

# Refus du module : message préfixé et code 2 (même convention que postgres)
refuse() { echo "devzone : argocd : $*" >&2; exit 2; }

# Vue regroupée des identifiants : un échec n'empêche jamais l'opération
regenerer_identifiants() {
    password_regenerer ||
        echo "devzone : argocd : identifiants regroupés non mis à jour (devzone mots-de-passe)" >&2
}

# Convertit une quantité de mémoire Kubernetes (Ki, Mi, Gi, K, M, G, octets)
# en Kio, pour additionner la mémoire allouable des nœuds.
quantite_ki() {
    local q="${1:-}" nombre
    case "$q" in
        *Ki) nombre="${q%Ki}"; echo $((nombre)) ;;
        *Mi) nombre="${q%Mi}"; echo $((nombre * 1024)) ;;
        *Gi) nombre="${q%Gi}"; echo $((nombre * 1024 * 1024)) ;;
        *Ti) nombre="${q%Ti}"; echo $((nombre * 1024 * 1024 * 1024)) ;;
        *K | *k) nombre="${q%[Kk]}"; echo $((nombre * 1000 / 1024)) ;;
        *M) nombre="${q%M}"; echo $((nombre * 1000 * 1000 / 1024)) ;;
        *G) nombre="${q%G}"; echo $((nombre * 1000 * 1000 * 1000 / 1024)) ;;
        *)
            case "$q" in
                '' | *[!0-9]*) echo 0 ;;
                *) echo $((q / 1024)) ;;
            esac
            ;;
    esac
}

# Somme des mémoires allouables des nœuds du cluster des services, en Kio ;
# échoue si le cluster ne répond pas. Lecture des nœuds réservée à
# l'administrateur (#430).
memoire_cluster_ki() {
    local sortie valeur total=0
    sortie="$(compte_admin "$(compte_ctx)" get nodes \
        -o jsonpath='{range .items[*]}{.status.allocatable.memory}{"\n"}{end}' 2>/dev/null)" || return 1
    [ -n "$sortie" ] || return 1
    while IFS= read -r valeur; do
        [ -n "$valeur" ] || continue
        total=$((total + $(quantite_ki "$valeur")))
    done <<<"$sortie"
    echo "$total"
}

# Refuse l'installation sous 1 Go de mémoire allouable dans le cluster ; le
# message indique où agrandir le cluster et la commande à relancer.
verifier_memoire() {
    local memoire
    if ! memoire="$(memoire_cluster_ki)"; then
        echo "devzone : argocd : cluster des services injoignable : devzone cluster" >&2
        return 2
    fi
    if [ "$memoire" -lt 1048576 ]; then
        echo "devzone : argocd : il faut au moins 1 Go de mémoire allouable dans le cluster (disponible : $((memoire / 1024)) Mo) ; agrandir le cluster (Docker Desktop → Settings → Resources) puis relancer : devzone activer argocd" >&2
        return 2
    fi
}

# Namespace présent dans le cluster des services : Argo CD est installé.
# Lecture des namespaces réservée à l'administrateur (#430).
installe() {
    compte_admin "$(compte_ctx)" get namespace "$NS" >/dev/null 2>&1
}

# Crée le namespace et l'étiquette par l'administrateur, autorise le compte
# limité puis pose la NetworkPolicy isolante du module (#430).
preparer_namespace() {
    local ctx
    ctx="$(compte_ctx)"
    compte_admin "$ctx" create namespace "$NS" --dry-run=client -o yaml |
        compte_admin "$ctx" apply -f - >/dev/null
    compte_admin "$ctx" label namespace "$NS" "$CLUSTER_ETIQUETTE" --overwrite >/dev/null
    compte_autoriser "$ctx" "$NS"
    namespace_isoler "$NS"
}

# Lit le mot de passe initial dans le Secret du chart et l'écrit dans
# workspace/.argocd/admin.env (600) ; le contenu n'est jamais affiché.
enregistrer_admin() {
    local brut mdp
    if ! brut="$(kubectl --context devzone -n "$NS" get secret argocd-initial-admin-secret \
        -o jsonpath='{.data.password}' 2>/dev/null)"; then
        echo "devzone : argocd : secret argocd-initial-admin-secret introuvable" >&2
        return 1
    fi
    mdp="$(printf '%s' "$brut" | base64 -d 2>/dev/null || true)"
    if [ -z "$mdp" ]; then
        echo "devzone : argocd : mot de passe admin illisible dans le secret" >&2
        return 1
    fi
    mkdir -p "$SECRETS"
    chmod 700 "$SECRETS"
    (
        umask 077
        cat >"$SECRETS/admin.env" <<ENV
ARGOCD_URL=https://127.0.0.1:$ARGOCD_PORT
ARGOCD_USER=admin
ARGOCD_PASSWORD=$mdp
ENV
    )
    chmod 600 "$SECRETS/admin.env"
}

# Installe Argo CD avec le chart figé, prépare le namespace, range le mot de
# passe admin et lance le relais d'accès ; idempotent (upgrade --install).
installer() {
    echo "▶ Vérification de la mémoire allouable du cluster des services…"
    verifier_memoire || return 2
    preparer_namespace
    echo "▶ Ajout du dépôt Helm Argo…"
    helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
    helm repo update >/dev/null 2>&1 || true
    echo "▶ Installation d'Argo CD $ARGOCD_VERSION dans $NS…"
    compte_helm "$(compte_ctx)" upgrade --install argocd argo/argo-cd \
        --version "$ARGOCD_VERSION" \
        --namespace "$NS" \
        --create-namespace \
        -f "$ICI/values.yaml" \
        --timeout "${ARGOCD_ATTENTE}s" \
        --wait
    enregistrer_admin
    relais_lancer argocd devzone "$NS" svc/argocd-server "$ARGOCD_PORT:443"
    regenerer_identifiants
    echo "✔ module argocd prêt : https://127.0.0.1:$ARGOCD_PORT"
}

# Désinstalle la release Helm et supprime le namespace ; les autres services
# du cluster restent, sous helm direct. Le RoleBinding et le namespace partent
# par l'administrateur (#430).
desinstaller() {
    local ctx
    relais_arreter argocd
    if installe; then
        echo "▶ Suppression d'Argo CD sur le cluster des services…"
        if ! compte_helm "$(compte_ctx)" uninstall argocd -n "$NS" >/dev/null 2>&1; then
            echo "devzone : argocd : helm uninstall a échoué (release déjà absente ?)" >&2
        fi
        ctx="$(compte_ctx)"
        compte_retirer "$ctx" "$NS" >/dev/null 2>&1 || true
        compte_admin "$ctx" delete namespace "$NS" --wait=true >/dev/null
    fi
    rm -rf "$SECRETS"
    echo "✔ module argocd désactivé ; les services restent, sous helm direct."
    regenerer_identifiants
}

# État du module : désactivé sans namespace, prêt avec relais actif.
etat() {
    if ! installe; then
        echo "désactivé"
        return 0
    fi
    if ! relais_actif argocd; then
        echo "prêt, relais arrêté : devzone appliquer"
    else
        echo "prêt : https://127.0.0.1:$ARGOCD_PORT"
    fi
}

# Relance le relais d'accès seulement si le namespace Argo CD existe.
relais() {
    if installe; then
        relais_lancer argocd devzone "$NS" svc/argocd-server "$ARGOCD_PORT:443"
    fi
}

# Applications of the projects (#516): shared with the workstation (apps.sh),
# here with the limited devzone context (aggregate roles of the chart)
APPS_CMD="devzone argocd app"
APPS_GENERATOR="$ICI/application.sh"
# shellcheck source=SCRIPTDIR/apps.sh
# shellcheck disable=SC1091
. "$ICI/apps.sh"
argocd_kubectl() { kubectl --context devzone "$@"; }

case "${1:-}" in
    installer) installer ;;
    desinstaller) desinstaller ;;
    etat) etat ;;
    relais-lancer) relais ;;
    relais-arreter) relais_arreter argocd ;;
    app)
        if [ "${DEVZONE_WORKSPACE:-}" = kubernetes ]; then
            refuse "in the workspace pod, on the workstation: devzone workspace argocd app ${*:2}"
        fi
        installe || refuse "module inactif : devzone enable argocd"
        argocd_app "${@:2}"
        ;;
    *)
        echo "devzone argocd : installer | desinstaller | etat | app add|list|remove" >&2
        exit 1
        ;;
esac
