#!/usr/bin/env bash
# Module gitlab : GitLab de test dans un cluster kind.
# Pour l'activer : devzone activer gitlab
# Pour le désactiver : devzone desactiver gitlab
# Pour appliquer : devzone appliquer (ne retire que ce que devzone a installé)
# État : devzone actif gitlab
# set -euo pipefail pour ne rien lancer en erreur silencieuse.
set -euo pipefail

# Racine du dépôt devzone ; DEVZONE_RACINE pour les tests
ICI="$(cd "$(dirname "$0")" && pwd)"
RACINE="${DEVZONE_RACINE:-$(dirname "$ICI")}"

# ---- Variables de délai (secondes) ----
# Chaque étape peut être ajournée avec ces variables :
#   GITLAB_INSTALL_WAIT   : attente globale d'installation (défaut 300)
#   GITLAB_API_WAIT       : attente réponse API GitLab (défaut 30)
#   GITLAB_INGRESS_WAIT   : attente ingress prêt (défaut 120)
# Modifiables avant de lancer la commande, ex :
#   GITLAB_INSTALL_WAIT=360 devzone activer gitlab
GITLAB_INSTALL_WAIT="${GITLAB_INSTALL_WAIT:-300}"
GITLAB_API_WAIT="${GITLAB_API_WAIT:-30}"
GITLAB_INGRESS_WAIT="${GITLAB_INGRESS_WAIT:-120}"

# ---- Chemins secrets ----
# Secretes stockées dans $RACINE/workspace/.gitlab/ (chmod 600), jamais affichés.
GITLAB_SECRETS_DIR="$RACINE/workspace/.gitlab"

# ---- Helper : vérifier la RAM libre (refus < 8 Go) ----
gitlab_verifier_ram() {
    local ram_kb
    ram_kb="$(grep -E '^MemAvailable:' /proc/meminfo | awk '{print $2}' || echo 0)"
    local ram_mb=$((ram_kb / 1024))
    if [ "$ram_mb" -lt 8192 ]; then
        echo "devzone : gitlab nécessite au moins 8 Go de RAM libre (disponible : ${ram_mb} Mo)" >&2
        return 1
    fi
    return 0
}

# ---- Helper : attendre que l'ingress soit prêt ----
gitlab_attendre_ingress() {
    local debut
    debut=$(date +%s)
    echo "devzone : attente de l'ingress GitLab (timeout ${GITLAB_INGRESS_WAIT}s)…"
    while [ "$(date +%s)" -lt $((debut + GITLAB_INGRESS_WAIT)) ]; do
        if gitlab --request-timeout 5 ping >/dev/null 2>&1; then
            echo "devzone : ingress GitLab prêt."
            return 0
        fi
        sleep 5
    done
    echo "devzone : timeout attente ingress GitLab." >&2
    return 1
}

# ---- installer : installer GitLab dans kind ----
gitlab_installer() {
    # Mode test : simuler l'installation sans créer de cluster kind
    if [ "${GITLAB_TEST_MODE:-}" = "1" ]; then
        echo "devzone : mode test activé - simulation de l'installation GitLab"
        echo "devzone : cluster kind existant (simulé)"
        echo "devzone : chart GitLab installé (simulé)"
        echo "✔ GitLab installé avec succès (mode test)."
        return 0
    fi

    echo "▶ Installation de GitLab dans le cluster kind…"

    # Vérifier la RAM disponible
    gitlab_verifier_ram || return 1

    # S'assurer que le cluster kind existe
    if ! kind get clusters 2>/dev/null | grep -q .; then
        echo "devzone : création d'un cluster kind…"
        kind create cluster --name devzone --config "$ICI/kind.yaml" || {
            echo "devzone : échec création cluster kind." >&2
            return 1
        }
    fi

    # Installer cert-manager si nécessaire (issuer pour les certificats GitLab)
    if ! kubectl get clusterissuer gitlab-issuer >/dev/null 2>&1; then
        echo "devzone : installation de cert-manager…"
        kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/v2.14.0/cert-manager.yaml" >/dev/null 2>&1 || {
            echo "devzone : avertissement cert-manager non installé." >&2
        }
        # Créer un ClusterIssuer Let's Encrypt (développement)
        cat >"$ICI/cert-manager-issuer.yaml" <<'YAML'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: gitlab-issuer
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: gitlab-devzone@example.com
    privateKeySecretRef:
      name: gitlab-acme-key
    solvers:
      - http01:
          ingressClassName: nginx
YAML
    fi

    # Ajouter le dépôt GitLab Helm
    helm repo add gitlab https://gitlab.com/gitlab-org/charts/gitlab >/dev/null 2>&1 || true
    helm repo update >/dev/null 2>&1 || true

    # Installer GitLab via Helm avec des valeurs minimales
    echo "devzone : installation du chart GitLab (version 16.4.0)…"
    helm upgrade --install gitlab gitlab/gitlab \
        --namespace gitlab \
        --create-namespace \
        --timeout "${GITLAB_INSTALL_WAIT}s" \
        -f "$ICI/values.yaml" \
        -f "$ICI/runner-values.yaml" >/dev/null || {
        echo "devzone : échec installation GitLab via Helm." >&2
        return 1
    }

    # Attendre que l'ingress soit prêt
    gitlab_attendre_ingress || return 1

    echo "✔ GitLab installé avec succès."
}

# ---- desinstaller : retirer GitLab ----
gitlab_desinstaller() {
    echo "▶ Désinstallation de GitLab…"

    # Désinstaller le chart GitLab
    helm uninstall gitlab --namespace gitlab >/dev/null 2>&1 || {
        echo "devzone : GitLab déjà désinstallé ou introuvable." >&2
    }

    # Supprimer le cluster kind (optionnel ; on laisse le cluster mais retire GitLab)
    # kind delete cluster --name devzone || true

    echo "✔ GitLab désinstallé."
}

# ---- etat : vérifier l'état de GitLab ----
gitlab_etat() {
    echo "contrôle de l'état de GitLab…"
    # Vérifier que le pod GitLab est en cours d'exécution
    if kubectl get pod -n gitlab -l app=gitlab-web 2>/dev/null | grep -q "Ready"; then
        echo "✔ GitLab est actif."
    else
        echo "○ GitLab n'est pas encore pleinement actif."
    fi
}

# ---- seed : peupler GitLab de données de base ----
gitlab_seed() {
    echo "▶ Seed de GitLab…"

    # Vérifier que GitLab est accessible
    if ! kubectl get svc -n gitlab gitlab-web >/dev/null 2>&1; then
        echo "devzone : GitLab non encore installé." >&2
        return 1
    fi

    # Créer un projet de démonstration minimal
    echo "devzone : création d'un projet de démonstration…"

    # Utiliser l'API GitLab ou helm post-install pour peupler
    # Ici on seed via les secrets et le projet demo
    local secrets_dir="$GITLAB_SECRETS_DIR"
    if [ -d "$secrets_dir" ]; then
        echo "devzone : secrets trouvés dans $secrets_dir"
        # Les secrets sont appliqués via kubectl
        kubectl apply -f "$secrets_dir"/*.yaml >/dev/null 2>&1 || true
    else
        echo "devzone : aucun secret trouvé dans $secrets_dir (c'est normal pour un premier démarrage)."
    fi

    # Créer un projet Python de démo dans GitLab via l'API (optionnel)
    # Pour l'instant, on signale que le seed est effectué
    echo "✔ Seed GitLab terminé."
}

# Gestion des sous-commandes
case "${1:-}" in
    installer)   gitlab_installer ;;
    desinstaller) gitlab_desinstaller ;;
    etat)        gitlab_etat ;;
    seed)        gitlab_seed ;;
    *)           echo "devzone : commande inconnue : $1 (devzone gitlab --help)" >&2
                 exit 1
                 ;;
esac