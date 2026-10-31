#!/usr/bin/env bash
# Module gitlab : GitLab de test dans un cluster kind.
# Pour l'activer : devzone activer gitlab
# Pour le désactiver : devzone desactiver gitlab
# set -euo pipefail pour ne rien lancer en erreur silencieuse.
set -euo pipefail

# Racine du dépôt devzone (deux niveaux au-dessus du module) ; DEVZONE_RACINE pour les tests
ICI="$(cd "$(dirname "$0")" && pwd)"
RACINE="${DEVZONE_RACINE:-$(dirname "$(dirname "$ICI")")}"

# ---- Variables de délai (secondes) ----
# GITLAB_ATTENTE : attente globale d'installation (défaut 1200)
GITLAB_ATTENTE="${GITLAB_ATTENTE:-1200}"

# ---- Chemins secrets ----
# Secrets stockés dans $RACINE/workspace/.gitlab/ (chmod 600), jamais affichés.
GITLAB_SECRETS_DIR="$RACINE/workspace/.gitlab"

# ---- Helper : vérifier la RAM libre (refus < 8 Go) ----
gitlab_verifier_ram() {
    local ram_kb
    ram_kb="$(awk '/^MemAvailable:/ {print $2}' "${DEVZONE_MEMINFO:-/proc/meminfo}" 2>/dev/null || true)"
    ram_kb="${ram_kb:-0}"
    if [ "$ram_kb" -lt 8388608 ]; then
        local ram_mb=$((ram_kb / 1024))
        echo "devzone : gitlab nécessite au moins 8 Go de RAM libre (disponible : ${ram_mb} Mo)" >&2
        return 1
    fi
    return 0
}

# ---- Helper : attendre que GitLab soit prêt ----
gitlab_attendre_pret() {
    local debut
    debut=$(date +%s)
    echo "▶ Attente de GitLab prêt (timeout ${GITLAB_ATTENTE}s)…"
    while [ $(( $(date +%s) - debut )) -lt "$GITLAB_ATTENTE" ]; do
        if curl -sf http://gitlab.localhost:8929/-/readiness >/dev/null 2>&1 || curl -sf http://gitlab.localhost:8929/users/sign_in >/dev/null 2>&1; then
            echo "▶ GitLab prêt."
            return 0
        fi
        sleep 5
    done
    echo "devzone : timeout attente GitLab." >&2
    return 1
}

# ---- seed : peupler GitLab de données de base ----
gitlab_seed() {
    echo "▶ Seed de GitLab…"

    mkdir -p "$GITLAB_SECRETS_DIR"

    # Mot de passe root lu dans le secret gitlab-gitlab-initial-root-password
    local mot_de_passe
    mot_de_passe="$(kubectl --context kind-gitlab get secret -n gitlab gitlab-gitlab-initial-root-password -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
    if [ -z "$mot_de_passe" ]; then
        echo "devzone : seed GitLab : secret root (gitlab-gitlab-initial-root-password) introuvable, arrêt du seed." >&2
        return 1
    fi
    printf '%s' "$mot_de_passe" > "$GITLAB_SECRETS_DIR/root-password"
    chmod 600 "$GITLAB_SECRETS_DIR/root-password"

    # Token d'accès root créé par kubectl exec dans le pod toolbox avec gitlab-rails runner
    local toolbox_pod root_token
    toolbox_pod="$(kubectl --context kind-gitlab get pod -n gitlab -l app=toolbox -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [ -z "$toolbox_pod" ]; then
        echo "devzone : seed GitLab : pod toolbox (label app=toolbox) introuvable, arrêt du seed." >&2
        return 1
    fi
    root_token="$(kubectl --context kind-gitlab exec -n gitlab "$toolbox_pod" -- gitlab-rails runner 'puts User.find_by_username("root").personal_access_tokens.create(name: "devzone", scopes: ["api", "write_repository"], expires_at: 30.days.from_now).token' 2>/dev/null | tail -n 1 || true)"
    if [ -z "$root_token" ]; then
        echo "devzone : seed GitLab : création du jeton root (gitlab-rails runner) échouée, arrêt du seed." >&2
        return 1
    fi
    printf '%s' "$root_token" > "$GITLAB_SECRETS_DIR/root-token"
    chmod 600 "$GITLAB_SECRETS_DIR/root-token"

    # Via l'API curl avec le token (jamais affiché en clair)
    local token groupe_id
    token="$(cat "$GITLAB_SECRETS_DIR/root-token")"

    # Groupe devzone (testé avant création)
    if ! curl -sf --header "PRIVATE-TOKEN: $token" "http://gitlab.localhost:8929/api/v4/groups/devzone" >/dev/null 2>&1; then
        if ! curl -sf --header "PRIVATE-TOKEN: $token" --request POST "http://gitlab.localhost:8929/api/v4/groups" --data "name=devzone&path=devzone&visibility=private" >/dev/null 2>&1; then
            echo "devzone : seed GitLab : création du groupe devzone échouée, arrêt du seed." >&2
            return 1
        fi
    fi
    groupe_id="$(curl -s --header "PRIVATE-TOKEN: $token" "http://gitlab.localhost:8929/api/v4/groups/devzone" | jq -r '.id // empty')"
    if [ -z "$groupe_id" ]; then
        echo "devzone : seed GitLab : lecture de l'identifiant numérique du groupe devzone échouée, arrêt du seed." >&2
        return 1
    fi

    # Projet devzone/demo (testé avant création, namespace_id = ID numérique du groupe)
    if ! curl -sf --header "PRIVATE-TOKEN: $token" "http://gitlab.localhost:8929/api/v4/projects/devzone%2Fdemo" >/dev/null 2>&1; then
        if ! curl -sf --header "PRIVATE-TOKEN: $token" --request POST "http://gitlab.localhost:8929/api/v4/projects" --data "name=demo&namespace_id=$groupe_id" >/dev/null 2>&1; then
            echo "devzone : seed GitLab : création du projet devzone/demo échouée, arrêt du seed." >&2
            return 1
        fi
    fi

    # Utilisateur dev (testé avant création, mot de passe généré aléatoirement)
    local users_json devpass
    users_json="$(curl -s --header "PRIVATE-TOKEN: $token" "http://gitlab.localhost:8929/api/v4/users?username=dev")"
    if [ "$(jq length <<<"$users_json")" -eq 0 ]; then
        devpass="$(openssl rand -base64 18 | tr -d '\n')"
        if ! curl -sf --header "PRIVATE-TOKEN: $token" --request POST "http://gitlab.localhost:8929/api/v4/users" --data "email=dev@gitlab.localhost&username=dev&name=dev&skip_confirmation=true" --data-urlencode "password=$devpass" >/dev/null 2>&1; then
            echo "devzone : seed GitLab : création de l'utilisateur dev échouée, arrêt du seed." >&2
            return 1
        fi
        printf '%s' "$devpass" > "$GITLAB_SECRETS_DIR/dev-password"
        chmod 600 "$GITLAB_SECRETS_DIR/dev-password"
    fi

    # Token de runner par POST /api/v4/user/runners (runner_type=instance_type)
    if [ ! -f "$GITLAB_SECRETS_DIR/runner-token" ]; then
        local rt_token
        rt_token="$(curl -s --header "PRIVATE-TOKEN: $token" --request POST "http://gitlab.localhost:8929/api/v4/user/runners" --data "runner_type=instance_type" 2>/dev/null | jq -r '.token // empty' || true)"
        if [ -z "$rt_token" ]; then
            echo "devzone : seed GitLab : création du jeton de runner (POST /api/v4/user/runners) échouée, arrêt du seed." >&2
            return 1
        fi
        printf '%s' "$rt_token" > "$GITLAB_SECRETS_DIR/runner-token"
        chmod 600 "$GITLAB_SECRETS_DIR/runner-token"
    fi

    # Push du contenu de demo/ dans devzone/demo (dépôt git temporaire, remote http avec le jeton dans l'URL, jamais affiché ; branche main)
    # Le push utilise le jeton root (write_repository) : le jeton de runner ne peut pas pousser.
    local push_token=""
    push_token="$(cat "$GITLAB_SECRETS_DIR/root-token")"
    if [ -z "$push_token" ]; then
        echo "devzone : seed GitLab : jeton root introuvable, arrêt du seed." >&2
        return 1
    fi
    # Déjà poussé (installation relancée) : rien à refaire
    if curl -sf --header "PRIVATE-TOKEN: $push_token" "http://gitlab.localhost:8929/api/v4/projects/devzone%2Fdemo/repository/branches/main" >/dev/null 2>&1; then
        echo "✔ Seed GitLab terminé (projet demo déjà poussé)."
        return 0
    fi
    if [ -d "$ICI/demo" ]; then
        local tmpdir
        tmpdir="$(mktemp -d)"
        cp -r "$ICI/demo/." "$tmpdir/"
        if (
            cd "$tmpdir"
            # Dépôt jetable du script : les hooks git globaux (repowarden) n'ont
            # rien à vérifier ici et refuseraient le commit
            export GIT_CONFIG_PARAMETERS="'core.hooksPath=/dev/null'"
            git init -q -b main
            git add -A
            git -c user.email=dev@gitlab.localhost -c user.name=dev commit -q -m "chore: projet de démonstration"
            # gitlab.localhost n'est pas toujours résolu par git : adresse
            # locale, et l'hôte attendu par l'ingress passé en en-tête
            git remote add origin "http://oauth2:${push_token}@127.0.0.1:8929/devzone/demo.git"
            git -c http.extraHeader="Host: gitlab.localhost" push -q -u origin main >/dev/null 2>&1
        ); then
            # Vérifie le push : la branche main existe bien sur le projet
            if ! curl -sf --header "PRIVATE-TOKEN: $push_token" "http://gitlab.localhost:8929/api/v4/projects/devzone%2Fdemo/repository/branches/main" >/dev/null 2>&1; then
                echo "devzone : seed GitLab : push du projet demo sur /devzone/demo.git réussi mais branche main absente, arrêt du seed." >&2
                rm -rf "$tmpdir"
                return 1
            fi
        else
            echo "devzone : seed GitLab : push du projet demo sur /devzone/demo.git échoué, arrêt du seed." >&2
            rm -rf "$tmpdir"
            return 1
        fi
        rm -rf "$tmpdir"
    fi

    echo "✔ Seed GitLab terminé."
}

# ---- installer : installer GitLab dans kind ----
gitlab_installer() {
    # RAM libre (refus < 8 Go) : seulement avant de créer le cluster ; une
    # instance déjà installée occupe elle-même cette mémoire
    if ! kind get clusters 2>/dev/null | grep -qx 'gitlab'; then
        echo "▶ Vérification de la mémoire disponible…"
        gitlab_verifier_ram || return 2
    fi

    # Noter le contexte précédent (pour la désinstallation)
    mkdir -p "$GITLAB_SECRETS_DIR"
    if [ ! -f "$GITLAB_SECRETS_DIR/contexte-precedent" ]; then
        local ctx
        ctx="$(kubectl config current-context 2>/dev/null || true)"
        if [ -n "$ctx" ] && [ "$ctx" != "kind-gitlab" ]; then
            printf '%s' "$ctx" > "$GITLAB_SECRETS_DIR/contexte-precedent"
        fi
    fi

    # S'assurer que le cluster kind gitlab existe
    echo "▶ Vérification/création du cluster kind gitlab…"
    if ! kind get clusters 2>/dev/null | grep -qx 'gitlab'; then
        echo "▶ Création du cluster kind gitlab…"
        kind create cluster --name gitlab --config "$ICI/kind.yaml" --wait 120s
    fi

    # Ajouter le dépôt GitLab Helm (idempotent)
    echo "▶ Ajout du dépôt Helm GitLab…"
    helm repo add gitlab https://charts.gitlab.io 2>/dev/null || true
    helm repo update >/dev/null 2>&1 || true

    # Installer GitLab via Helm
    echo "▶ Installation du chart GitLab…"
    helm --kube-context kind-gitlab upgrade --install gitlab gitlab/gitlab \
        --version 9.11.16 \
        --namespace gitlab \
        --create-namespace \
        -f "$ICI/values.yaml" \
        --timeout "${GITLAB_ATTENTE}s" \
        --wait

    # Attendre que GitLab soit prêt
    gitlab_attendre_pret

    # Seed des données de base
    gitlab_seed

    # Installer le runner GitLab
    echo "▶ Installation de l'exécuteur GitLab Runner…"
    local runner_token=""
    if [ -f "$GITLAB_SECRETS_DIR/runner-token" ]; then
        runner_token="$(cat "$GITLAB_SECRETS_DIR/runner-token")"
    fi
    if [ -z "$runner_token" ]; then
        echo "devzone : seed GitLab : jeton de runner introuvable (seed incomplet), arrêt du seed." >&2
        return 1
    fi
    helm --kube-context kind-gitlab upgrade --install gitlab-runner gitlab/gitlab-runner \
        --version 0.88.2 \
        --namespace gitlab \
        -f "$ICI/runner-values.yaml" \
        --set "runnerToken=${runner_token}"

    # Résumé
    echo "▶ Installation terminée."
    echo "  URL : http://gitlab.localhost:8929"
    echo "  Utilisateur : root"
    echo "  Mot de passe root : $GITLAB_SECRETS_DIR/root-password (chmod 600)"
}

# ---- desinstaller : retirer GitLab ----
gitlab_desinstaller() {
    echo "▶ Désinstallation de GitLab…"

    # Supprimer le cluster kind gitlab (tout part avec lui)
    kind delete cluster --name gitlab 2>/dev/null || true

    # Retirer contexte, cluster et utilisateur kind-gitlab de ~/.kube/config s'ils restent
    kubectl config delete-context kind-gitlab 2>/dev/null || true
    kubectl config delete-cluster kind-gitlab 2>/dev/null || true
    kubectl config delete-user kind-gitlab 2>/dev/null || true

    # Remettre current-context à celui d'avant s'il valait kind-gitlab
    if [ -f "$GITLAB_SECRETS_DIR/contexte-precedent" ]; then
        local ctx_prev
        ctx_prev="$(cat "$GITLAB_SECRETS_DIR/contexte-precedent" 2>/dev/null || true)"
        if [ -n "$ctx_prev" ]; then
            kubectl config use-context "$ctx_prev" >/dev/null 2>&1 || true
            echo "▶ current-context restauré : $ctx_prev"
        fi
    fi

    # Supprimer $RACINE/workspace/.gitlab/
    rm -rf "$GITLAB_SECRETS_DIR"

    echo "✔ GitLab désinstallé."
}

# ---- etat : vérifier l'état de GitLab ----
gitlab_etat() {
    # Désactivé s'il n'y a pas de cluster gitlab
    if ! kind get clusters 2>/dev/null | grep -qx 'gitlab'; then
        echo "désactivé"
        return 0
    fi

    # Vérifier que GitLab répond en readiness
    if curl -sf http://gitlab.localhost:8929/-/readiness >/dev/null 2>&1 || curl -sf http://gitlab.localhost:8929/users/sign_in >/dev/null 2>&1; then
        # Vérifier le runner en ligne ou hors ligne
        local runner_status="hors ligne"
        if [ -f "$GITLAB_SECRETS_DIR/root-token" ]; then
            local token count
            token="$(cat "$GITLAB_SECRETS_DIR/root-token")"
            count="$(curl -s --header "PRIVATE-TOKEN: $token" "http://gitlab.localhost:8929/api/v4/runners/all?status=online" 2>/dev/null | jq -r 'length' 2>/dev/null || true)"
            if [ "${count:-0}" -gt 0 ] 2>/dev/null; then
                runner_status="en ligne"
            fi
        fi
        echo "prêt : http://gitlab.localhost:8929, runner ${runner_status}"
        return 0
    fi

    echo "en échec : devzone appliquer"
    return 0
}

# Gestion des sous-commandes
case "${1:-}" in
    installer)   gitlab_installer ;;
    desinstaller) gitlab_desinstaller ;;
    etat)        gitlab_etat ;;
    seed)        gitlab_seed ;;
    *)           echo "devzone : commande inconnue : ${1:-} (devzone gitlab --help)" >&2
                 exit 1
                 ;;
esac
