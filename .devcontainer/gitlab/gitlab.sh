#!/usr/bin/env bash
# Module gitlab : GitLab de test dans le cluster des services (#396).
# Pour l'activer : devzone activer gitlab
# Pour le désactiver : devzone desactiver gitlab
# set -euo pipefail pour ne rien lancer en erreur silencieuse.
set -euo pipefail

# Racine du dépôt devzone (deux niveaux au-dessus du module) ; DEVZONE_RACINE pour les tests
ICI="$(cd "$(dirname "$0")" && pwd)"
RACINE="${DEVZONE_RACINE:-$(dirname "$(dirname "$ICI")")}"
# shellcheck source=SCRIPTDIR/../cluster.sh
. "$ICI/../cluster.sh"
# shellcheck source=SCRIPTDIR/../password.sh
# shellcheck disable=SC1091
. "$ICI/../password.sh"
# Isolation réseau : namespace_isoler, posée avec le namespace devzone-gitlab
# shellcheck source=SCRIPTDIR/../isolement.sh
# shellcheck disable=SC1091
. "$ICI/../isolement.sh"

# ---- Variables de délai (secondes) ----
# GITLAB_ATTENTE : attente globale d'installation (défaut 1200)
GITLAB_ATTENTE="${GITLAB_ATTENTE:-1200}"

# ---- Chemins secrets ----
# Secrets stockés dans $RACINE/workspace/.gitlab/ (chmod 600), jamais affichés.
GITLAB_SECRETS_DIR="$RACINE/workspace/.gitlab"

# Vue regroupée des identifiants : un échec n'empêche jamais l'opération
regenerer_identifiants() {
    password_regenerer ||
        echo "devzone : gitlab : identifiants regroupés non mis à jour (devzone mots-de-passe)" >&2
}

# ---- /etc/hosts du conteneur ----
# DEVZONE_HOSTS pour les tests (jamais le /etc/hosts réel)
HOSTS="${DEVZONE_HOSTS:-/etc/hosts}"
GITLAB_HOTE_MARQUE="# devzone:gitlab"

# Secret Rails GitLab (#347) : conservation dans workspace/.gitlab, réapplication
# avant helm upgrade --install et mot de passe régénérable
# shellcheck source=SCRIPTDIR/secrets.sh
# shellcheck disable=SC1091
. "$ICI/secrets.sh"

# ---- Installation, migration et relais du cluster des services ----
# Nouvelle logique hors de ce fichier (#396) : namespace devzone-gitlab,
# mémoire allouable, Helm contexte devzone, migration depuis kind-gitlab.
# shellcheck source=SCRIPTDIR/installation.sh
# shellcheck disable=SC1091
. "$ICI/installation.sh"

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

# ---- hote-poser / hote-retirer : gitlab.localhost dans /etc/hosts ----
# Pourquoi : ssh (clone ssh://git@gitlab.localhost:2224/…), glab et getent
# passent par le résolveur système. curl et git (libcurl) ignorent /etc/hosts
# pour les noms *.localhost (RFC 6761) et passent par le relais TCP ci-dessus,
# qui écoute sur 127.0.0.1. Le nom pointe donc vers 127.0.0.1 pour que ssh et
# glab empruntent le même chemin. /etc/hosts est un montage Docker que Docker
# régénère au démarrage du conteneur, d'où le re-pose à chaque démarrage
# (demarrage.sh) et à chaque activation. Jamais de sed -i ni de mv : le
# montage ne peut pas être renommé (écriture en place seulement) ; directe si
# le fichier est inscriptible, sinon sudo -n. Un échec n'échoue jamais :
# avertissement sur stderr et code 0, pour ne pas faire échouer l'installation
# pour un nom d'hôte.
gitlab_hote_poser() {
    local ligne tmp
    ligne="$(printf '127.0.0.1\tgitlab.localhost %s' "$GITLAB_HOTE_MARQUE")"
    # Déjà la bonne ligne, une seule fois : rien (idempotent)
    if [ "$(grep -c "$GITLAB_HOTE_MARQUE" "$HOSTS" 2>/dev/null || true)" = 1 ] &&
        grep -qxF "$ligne" "$HOSTS" 2>/dev/null; then
        return 0
    fi
    if grep -q "$GITLAB_HOTE_MARQUE" "$HOSTS" 2>/dev/null; then
        # Ligne marquée avec une autre adresse (IPv6 de #320) ou doublon :
        # on la remplace par la bonne, en gardant le reste du fichier.
        tmp="$(mktemp)"
        grep -v "$GITLAB_HOTE_MARQUE" "$HOSTS" >"$tmp" 2>/dev/null || true
        printf '%s\n' "$ligne" >>"$tmp"
        if [ -w "$HOSTS" ]; then
            cp "$tmp" "$HOSTS" 2>/dev/null ||
                echo "devzone : gitlab : nom gitlab.localhost non posé dans $HOSTS (droits d'écriture insuffisants)" >&2
        elif ! sudo -n cp "$tmp" "$HOSTS" >/dev/null 2>&1; then
            echo "devzone : gitlab : nom gitlab.localhost non posé dans $HOSTS (sudo -n indisponible ou refusé)" >&2
        fi
        rm -f "$tmp"
        return 0
    fi
    if [ -w "$HOSTS" ]; then
        printf '%s\n' "$ligne" >>"$HOSTS" 2>/dev/null ||
            echo "devzone : gitlab : nom gitlab.localhost non posé dans $HOSTS (droits d'écriture insuffisants)" >&2
    elif ! printf '%s\n' "$ligne" | sudo -n tee -a "$HOSTS" >/dev/null 2>&1; then
        echo "devzone : gitlab : nom gitlab.localhost non posé dans $HOSTS (sudo -n indisponible ou refusé)" >&2
    fi
    return 0
}

gitlab_hote_retirer() {
    # Aucune ligne repérée : rien (y compris fichier illisible)
    if ! grep -q "$GITLAB_HOTE_MARQUE" "$HOSTS" 2>/dev/null; then
        return 0
    fi
    local tmp
    tmp="$(mktemp)"
    grep -v "$GITLAB_HOTE_MARQUE" "$HOSTS" >"$tmp" 2>/dev/null || true
    if [ -w "$HOSTS" ]; then
        cp "$tmp" "$HOSTS" 2>/dev/null ||
            echo "devzone : gitlab : ligne gitlab.localhost non retirée de $HOSTS (droits d'écriture insuffisants)" >&2
    elif ! sudo -n cp "$tmp" "$HOSTS" >/dev/null 2>&1; then
        echo "devzone : gitlab : ligne gitlab.localhost non retirée de $HOSTS (sudo -n indisponible ou refusé)" >&2
    fi
    rm -f "$tmp"
    return 0
}

# ---- etat : vérifier l'état de GitLab ----
gitlab_etat() {
    # Désactivé si le namespace devzone-gitlab n'existe pas
    if ! gitlab_installe; then
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
    else
        echo "en échec : devzone appliquer"
    fi
    return 0
}

# Gestion des sous-commandes
case "${1:-}" in
    installer)    gitlab_installer ;;
    desinstaller) gitlab_desinstaller ;;
    migrer)       shift; gitlab_migrer "$@" ;;
    installe)     gitlab_installe ;;
    etat)         gitlab_etat ;;
    seed)         gitlab_seed ;;
    nouveau-mdp)  gitlab_nouveau_mdp "${@:2}" ;;
    relais-lancer) gitlab_relais_lancer ;;
    relais-arreter) gitlab_relais_arreter ;;
    relais-etat)  gitlab_relais_etat ;;
    hote-poser)   gitlab_hote_poser ;;
    hote-retirer) gitlab_hote_retirer ;;
    *)            echo "devzone : commande inconnue : ${1:-} (devzone gitlab --help)" >&2
                  exit 1
                  ;;
esac
