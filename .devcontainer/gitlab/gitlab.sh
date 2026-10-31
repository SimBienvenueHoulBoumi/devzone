#!/usr/bin/env bash
# Module gitlab : GitLab de test dans un cluster kind.
# Pour l'activer : devzone activer gitlab
# Pour le désactiver : devzone desactiver gitlab
# set -euo pipefail pour ne rien lancer en erreur silencieuse.
set -euo pipefail

# Racine du dépôt devzone ; DEVZONE_RACINE pour les tests
ICI="$(cd "$(dirname "$0")" && pwd)"
RACINE="${DEVZONE_RACINE:-$(dirname "$ICI")}"

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
gitlab_attendre_prêt() {
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
    if [ -n "$mot_de_passe" ]; then
        printf '%s' "$mot_de_passe" > "$GITLAB_SECRETS_DIR/root-password"
        chmod 600 "$GITLAB_SECRETS_DIR/root-password"
    fi

    # Token d'accès root créé par kubectl exec dans le pod toolbox avec gitlab-rails runner
    local toolbox_pod root_token
    toolbox_pod="$(kubectl --context kind-gitlab get pod -n gitlab -l app=toolbox -o jsonpath='{.items[0].name}' 2>/dev/null || true)"
    if [ -n "$toolbox_pod" ]; then
        root_token="$(kubectl --context kind-gitlab exec -n gitlab "$toolbox_pod" -- gitlab-rails runner 'puts User.find_by_username("root").personal_access_tokens.create(scopes: ["api", "write_repository"], expires_at: 30.days.from_now).token' 2>/dev/null | tail -n 1 || true)"
    else
        root_token=""
    fi
    if [ -n "$root_token" ]; then
        printf '%s' "$root_token" > "$GITLAB_SECRETS_DIR/root-token"
        chmod 600 "$GITLAB_SECRETS_DIR/root-token"
    fi

    # Via l'API curl avec le token (jamais affiché en clair)
    if [ -f "$GITLAB_SECRETS_DIR/root-token" ]; then
        local token
        token="$(cat "$GITLAB_SECRETS_DIR/root-token")"

        # Groupe devzone (testé avant création)
        if ! curl -sf --header "PRIVATE-TOKEN: $token" "http://gitlab.localhost:8929/api/v4/groups/devzone" >/dev/null 2>&1; then
            curl -s --header "PRIVATE-TOKEN: $token" --request POST "http://gitlab.localhost:8929/api/v4/groups" --data "name=devzone&path=devzone&visibility=private" >/dev/null 2>&1 || true
        fi

        # Projet devzone/demo (testé avant création)
        if ! curl -sf --header "PRIVATE-TOKEN: $token" "http://gitlab.localhost:8929/api/v4/projects/devzone%2Fdemo" >/dev/null 2>&1; then
            curl -s --header "PRIVATE-TOKEN: $token" --request POST "http://gitlab.localhost:8929/api/v4/projects" --data "name=demo&path=demo&namespace_id=devzone" >/dev/null 2>&1 || true
        fi

        # Utilisateur dev (testé avant création)
        if ! curl -sf --header "PRIVATE-TOKEN: $token" "http://gitlab.localhost:8929/api/v4/users?username=dev" >/dev/null 2>&1 | grep -q '"username":"dev"'; then
            curl -s --header "PRIVATE-TOKEN: $token" --request POST "http://gitlab.localhost:8929/api/v4/users" --data "email=dev@gitlab.localhost&password=devpass&username=dev&name=dev" >/dev/null 2>&1 || true
        fi
    fi

    # Token de runner par POST /api/v4/user/runners (runner_type=instance_type)
    if [ -f "$GITLAB_SECRETS_DIR/root-token" ] && [ ! -f "$GITLAB_SECRETS_DIR/runner-token" ]; then
        local rt_token
        token="$(cat "$GITLAB_SECRETS_DIR/root-token")"
        rt_token="$(curl -s --header "PRIVATE-TOKEN: $token" --request POST "http://gitlab.localhost:8929/api/v4/user/runners" --data "runner_type=instance_type" 2>/dev/null | sed -n 's/.*"token":"\([^"]*\)".*/\1/p' || true)"
        if [ -n "$rt_token" ]; then
            printf '%s' "$rt_token" > "$GITLAB_SECRETS_DIR/runner-token"
            chmod 600 "$GITLAB_SECRETS_DIR/runner-token"
        fi
    fi

    # Push du contenu de demo/ dans devzone/demo (dépôt git temporaire, remote http avec le jeton dans l'URL, jamais affiché ; branche main)
    local push_token=""
    if [ -f "$GITLAB_SECRETS_DIR/runner-token" ]; then
        push_token="$(cat "$GITLAB_SECRETS_DIR/runner-token")"
    elif [ -f "$GITLAB_SECRETS_DIR/root-token" ]; then
        push_token="$(cat "$GITLAB_SECRETS_DIR/root-token")"
    fi
    if [ -d "$ICI/demo" ] && [ -n "$push_token" ]; then
        local tmpdir
        tmpdir="$(mktemp -d)"
        cp -r "$ICI/demo/." "$tmpdir/"
        (
            cd "$tmpdir"
            git init -b main >/dev/null 2>&1 || { git init >/dev/null 2>&1; git symbolic-ref HEAD refs/heads/main >/dev/null 2>&1; }
            git add -A
            git -c user.email=dev@gitlab.localhost -c user.name=dev commit -m "Init demo project" >/dev/null 2>&1 || true
            git remote add origin "http://oauth2:${push_token}@gitlab.localhost:8929/devzone/demo.git" >/dev/null 2>&1 || true
            git push -u origin main >/dev/null 2>&1 || true
        )
        rm -rf "$tmpdir"
    fi

    echo "✔ Seed GitLab terminé."
}

# ---- installer : installer GitLab dans kind ----
gitlab_installer() {
    # Vérifier la RAM disponible (refus < 8 Go)
    echo "▶ Vérification de la mémoire disponible…"
    gitlab_verifier_ram || return 2

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
    gitlab_attendre_prêt

    # Seed des données de base
    gitlab_seed

    # Installer le runner GitLab
    echo "▶ Installation de l'exécuteur GitLab Runner…"
    local runner_token=""
    if [ -f "$GITLAB_SECRETS_DIR/runner-token" ]; then
        runner_token="$(cat "$GITLAB_SECRETS_DIR/runner-token")"
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
            count="$(curl -s --header "PRIVATE-TOKEN: $token" "http://gitlab.localhost:8929/api/v4/runners/all" 2>/dev/null | grep -o 'active' | wc -l || true)"
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
