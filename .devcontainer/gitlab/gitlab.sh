#!/usr/bin/env bash
# Module gitlab : GitLab de test dans le cluster des services (#396).
# Pour l'activer : devzone enable gitlab
# Pour le désactiver : devzone disable gitlab
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
        echo "devzone : gitlab : identifiants regroupés non mis à jour (devzone passwords)" >&2
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
# Chart enveloppe (helm direct, chart.sh), Argo CD (argocd.sh), seed (seed.sh) (#538)
# shellcheck source=SCRIPTDIR/chart.sh
# shellcheck disable=SC1091
. "$ICI/chart.sh"
# shellcheck source=SCRIPTDIR/argocd.sh
# shellcheck disable=SC1091
. "$ICI/argocd.sh"
# shellcheck source=SCRIPTDIR/seed.sh
# shellcheck disable=SC1091
. "$ICI/seed.sh"

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
        echo "en échec : devzone apply"
    fi
    return 0
}

# Gestion des sous-commandes
case "${1:-}" in
    install)    gitlab_installer ;;
    uninstall) gitlab_desinstaller "${@:2}" ;;
    migrate)       shift; gitlab_migrer "$@" ;;
    installe)     gitlab_installe ;;
    status)         gitlab_etat ;;
    seed)         gitlab_seed_commande ;;
    new-password)  gitlab_nouveau_mdp "${@:2}" ;;
    relay-start) gitlab_relais_lancer ;;
    relay-stop) gitlab_relais_arreter ;;
    relay-status)  gitlab_relais_etat ;;
    hote-poser)   gitlab_hote_poser ;;
    hote-retirer) gitlab_hote_retirer ;;
    *)            echo "devzone : commande inconnue : ${1:-} (devzone gitlab --help)" >&2
                  exit 1
                  ;;
esac
