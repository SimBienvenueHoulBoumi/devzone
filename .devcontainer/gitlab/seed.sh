#!/usr/bin/env bash
# Seed of the GitLab of devzone (#396, #538): the data a fresh instance needs,
# group devzone, demo project, dev user, runner. Sourced by gitlab.sh. The
# installer starts the relays and waits for GitLab before the seed; the seed
# command (devzone gitlab seed, run in the pod by services-admin.sh when Argo
# CD holds the chart) does it itself (gitlab_seed_commande).
#   gitlab_attendre_pret        waits for the readiness of GitLab (GITLAB_ATTENTE)
#   gitlab_seed                 group, project, user, runner token and its Secret
#   gitlab_seed_commande        devzone gitlab seed: relays, readiness, seed

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
    mot_de_passe="$(kubectl --context devzone get secret -n "$GITLAB_NS" gitlab-gitlab-initial-root-password -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
    if [ -z "$mot_de_passe" ]; then
        echo "devzone : seed GitLab : secret root (gitlab-gitlab-initial-root-password) introuvable, arrêt du seed." >&2
        return 1
    fi
    printf '%s' "$mot_de_passe" > "$GITLAB_SECRETS_DIR/root-password"
    chmod 600 "$GITLAB_SECRETS_DIR/root-password"

    # Token d'accès root créé par kubectl exec dans le pod toolbox avec gitlab-rails runner
    local toolbox_pod root_token
    toolbox_pod="$(kubectl --context devzone get pod -n "$GITLAB_NS" -l app=toolbox -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [ -z "$toolbox_pod" ]; then
        echo "devzone : seed GitLab : pod toolbox (label app=toolbox) introuvable, arrêt du seed." >&2
        return 1
    fi
    root_token="$(kubectl --context devzone exec -n "$GITLAB_NS" "$toolbox_pod" -- gitlab-rails runner 'puts User.find_by_username("root").personal_access_tokens.create(name: "devzone", scopes: ["api", "write_repository"], expires_at: 30.days.from_now).token' 2>/dev/null | tail -n 1 || true)"
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

    # Utilisateur dev (testé avant création, mot de passe généré aléatoirement) :
    # un dev-password existant n'est réutilisé que si l'utilisateur dev existe
    # encore (vérifié via l'API) ; sinon il est recréé avec un utilisateur nouveau.
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

    # Token de runner : vérifié via POST /api/v4/runners/verify ; un jeton valide
    # est gardé, un jeton refusé (403/404) est recréé, GitLab injoignable arrête le seed.
    local rt_jeton rt_code rt_token
    if [ -f "$GITLAB_SECRETS_DIR/runner-token" ]; then
        rt_jeton="$(cat "$GITLAB_SECRETS_DIR/runner-token")"
        rt_code="$(curl -s -o /dev/null -w '%{http_code}' --header "PRIVATE-TOKEN: $token" --request POST "http://gitlab.localhost:8929/api/v4/runners/verify" --data "token=${rt_jeton}" || true)"
        if [ "$rt_code" = "200" ]; then
            echo "✔ Jeton de runner valide : gardé."
        elif [ "$rt_code" = "403" ] || [ "$rt_code" = "404" ]; then
            echo "devzone : jeton de runner d'une installation précédente refusé : recréé."
            rt_token="$(curl -s --header "PRIVATE-TOKEN: $token" --request POST "http://gitlab.localhost:8929/api/v4/user/runners" --data "runner_type=instance_type" 2>/dev/null | jq -r '.token // empty' || true)"
            if [ -z "$rt_token" ]; then
                echo "devzone : seed GitLab : création du jeton de runner (POST /api/v4/user/runners) échouée, arrêt du seed." >&2
                return 1
            fi
            printf '%s' "$rt_token" > "$GITLAB_SECRETS_DIR/runner-token"
            chmod 600 "$GITLAB_SECRETS_DIR/runner-token"
        else
            echo "devzone : seed GitLab : vérification du jeton de runner impossible (code ${rt_code}), arrêt du seed." >&2
            return 1
        fi
    else
        rt_token="$(curl -s --header "PRIVATE-TOKEN: $token" --request POST "http://gitlab.localhost:8929/api/v4/user/runners" --data "runner_type=instance_type" 2>/dev/null | jq -r '.token // empty' || true)"
        if [ -z "$rt_token" ]; then
            echo "devzone : seed GitLab : création du jeton de runner (POST /api/v4/user/runners) échouée, arrêt du seed." >&2
            return 1
        fi
        printf '%s' "$rt_token" > "$GITLAB_SECRETS_DIR/runner-token"
        chmod 600 "$GITLAB_SECRETS_DIR/runner-token"
    fi

    # Secret of the runner of the chart (runners.secret, #538): created apart, out
    # of Git; the token is read from its file, never on a command line
    if ! kubectl --context devzone -n "$GITLAB_NS" create secret generic gitlab-runner-secret \
        --from-file=runner-token="$GITLAB_SECRETS_DIR/runner-token" \
        --from-literal=runner-registration-token= \
        --dry-run=client -o yaml |
        kubectl --context devzone -n "$GITLAB_NS" apply -f - >/dev/null 2>&1; then
        echo "devzone : seed GitLab : secret gitlab-runner-secret non créé, arrêt du seed." >&2
        return 1
    fi
    # A runner already running may hold the previous token: restarted on the
    # one just written (no runner yet: nothing to restart)
    kubectl --context devzone -n "$GITLAB_NS" rollout restart deployment \
        --selector=app=gitlab-gitlab-runner >/dev/null 2>&1 || true

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
        regenerer_identifiants
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
    regenerer_identifiants
}

# devzone gitlab seed: the seed alone, when Argo CD holds the chart (the
# workstation runs it in the pod, services-admin.sh seed gitlab). The API and
# the push go through the relays: they start, GitLab is awaited, then the seed.
# The Rails secret of the pod is mirrored when it is not kept yet.
gitlab_seed_commande() {
    gitlab_relais_lancer || return 1
    gitlab_attendre_pret || return 1
    gitlab_seed || return 1
    if [ ! -f "$GITLAB_RAILS_FICHIER" ]; then
        gitlab_secrets_copier
    fi
}
