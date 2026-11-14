#!/usr/bin/env bash
# MySQL du catalogue (#414) : creer, liste, supprimer, etat, relais, installer, supprimer-donnees.
set -euo pipefail
ICI="$(cd "$(dirname "$0")" && pwd)"
RACINE="${DEVZONE_RACINE:-$(dirname "$(dirname "$(dirname "$ICI")")")}"
ETAT="${DEVZONE_ETAT:-$RACINE/.devzone.modules}"
# shellcheck source=SCRIPTDIR/../../cluster.sh
# shellcheck disable=SC1091
. "$ICI/../../cluster.sh"
# shellcheck source=SCRIPTDIR/../../password.sh
# shellcheck disable=SC1091
. "$ICI/../../password.sh"
# shellcheck source=SCRIPTDIR/../../isolement.sh
# shellcheck disable=SC1091
. "$ICI/../../isolement.sh"
# shellcheck source=SCRIPTDIR/volume.sh
# shellcheck disable=SC1091
. "$ICI/volume.sh"
# shellcheck source=SCRIPTDIR/installer.sh
# shellcheck disable=SC1091
. "$ICI/installer.sh"
# Le module argocd actif : MySQL installé par une Application (#538)
# shellcheck source=SCRIPTDIR/../../argocd/catalogue-argocd.sh
# shellcheck disable=SC1091
. "$ICI/../../argocd/catalogue-argocd.sh"
NS=devzone-mysql
SECRETS="$RACINE/workspace/.mysql"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_IMAGE="${MYSQL_IMAGE:-mysql:8.4}"
MYSQL_MEMOIRE="${MYSQL_MEMOIRE:-1Gi}"
MYSQL_TAILLE="${MYSQL_TAILLE:-5Gi}"
MYSQL_ATTENTE="${MYSQL_ATTENTE:-300}"
# Refus standard avec message et code 2
refuse() { echo "devzone : catalogue mysql : $*" >&2; exit 2; }
# Secret mysql-admin du hook services.sh : le même que l'installation directe
services_secret_mysql() { mysql_secret; }
# Régénère la vue .password (échec non bloquant)
regenerer_identifiants() {
    password_regenerer ||
        echo "devzone : catalogue mysql : identifiants regroupés non mis à jour (devzone mots-de-passe)" >&2
}
# Raccourci kubectl dans le namespace devzone-mysql
k() { kubectl --context devzone -n "$NS" "$@"; }
# Le namespace devzone-mysql existe-t-il ? Lecture des namespaces réservée à
# l'administrateur (#430)
installe() { compte_admin "$(compte_ctx)" get namespace "$NS" >/dev/null 2>&1; }
# Contexte du module : celui du cluster de devzone
contexte() {
    local c
    c="$(cluster_lu)"
    [ -n "$c" ] || refuse "aucun cluster choisi : devzone activer mysql"
    echo "$c"
}
# Marque d'échec du module (même schéma que fichier_echec de devzone)
fichier_echec() { echo "$ETAT-echec-mysql"; }
# Nom de projet : identifiant SQL simple, jamais à échapper, pas un nom réservé
valider_projet() {
    local p="${1:-}"
    [ -n "$p" ] || refuse "nom de projet manquant"
    [[ "$p" =~ ^[a-z][a-z0-9_]{0,62}$ ]] || refuse "nom de projet invalide : $p (minuscules, chiffres, _ ; commence par une lettre)"
    case "$p" in
        mysql | information_schema | performance_schema | sys) refuse "nom réservé : $p" ;;
    esac
}
# Mot de passe aléatoire pour un nouveau projet
mot_de_passe() { openssl rand -hex 24; }
# Mot de passe root : root.env d'une installation existante, sinon admin-password
root_password() {
    local mdp
    mdp="$(sed -n 's/^MYSQL_PASSWORD=//p' "$SECRETS/root.env" 2>/dev/null | tail -1 || true)"
    [ -z "$mdp" ] && [ -f "$SECRETS/admin-password" ] && mdp="$(cat "$SECRETS/admin-password" 2>/dev/null || true)"
    [ -n "$mdp" ] || refuse "mot de passe root MySQL introuvable (workspace/.mysql/root.env)"
    echo "$mdp"
}
# mysql en superutilisateur dans le pod ; le mot de passe n'est jamais affiché
mysql_admin() { k exec -i mysql-0 -c mysql -- mysql -uroot -p"$(root_password)" "$@"; }
# Nombre de bases hors bases système
nombre_bases() {
    local n
    n="$(mysql_admin -N -B -e "SHOW DATABASES" 2>/dev/null | grep -vE '^(information_schema|mysql|performance_schema|sys)$' | grep -c . || true)"
    echo "${n:-0}"
}
installer() {
    local CTX claim
    CTX="$(contexte)"
    if ! contexte_devzone_poser "$CTX"; then
        echo "devzone : catalogue mysql : impossible de poser le contexte devzone sur $CTX" >&2
        return 1
    fi
    echo "▶ MySQL sur le cluster $CTX (namespace $NS)…"
    if catalogue_argocd_active mysql; then
        mysql_installer_argocd "$CTX"
        return
    fi
    compte_namespace "$CTX" "$NS"
    namespace_isoler "$NS" >/dev/null
    if k get statefulset mysql >/dev/null 2>&1; then
        echo "devzone : catalogue mysql : installation existante dans $NS, adoptée (volume et root.env gardés)"
    else
        mysql_secret
        claim="$(mysql_claim_choisir "$NS")" || return 2
        mysql_appliquer_manifeste "$NS" "$claim"
        if ! k rollout status statefulset/mysql --timeout="${MYSQL_ATTENTE}s" >/dev/null; then
            echo "devzone : catalogue mysql : pas prêt après ${MYSQL_ATTENTE}s : kubectl --context $CTX -n $NS describe pod mysql-0" >&2
            return 1
        fi
    fi
    mysql_secret
    relais_lancer mysql "$CTX" "$NS" svc/mysql 3306:3306
    echo "✔ MySQL prêt : 127.0.0.1:$MYSQL_PORT dans le conteneur"
    regenerer_identifiants
}
# Supprime le namespace (donc les PVC), garde workspace/.mysql (#441) :
# confirmation en terminal [o/N], --oui obligatoire sinon (refus, code 2)
supprimer_donnees() {
    local CTX oui="" arg reponse
    for arg in "$@"; do
        case "$arg" in
            --oui) oui=1 ;;
            *) refuse "argument inconnu : $arg" ;;
        esac
    done
    if [ -z "$oui" ]; then
        cluster_interactif || refuse "confirmation impossible sans terminal : devzone mysql supprimer-donnees --oui"
        printf 'Supprimer le namespace %s et tous ses volumes ? [o/N] ' "$NS" >&2
        read -r reponse || reponse=""
        case "$reponse" in
            o | O | oui) ;;
            *) echo "Abandon : rien n'a été supprimé."; return 0 ;;
        esac
    fi
    CTX="$(cluster_lu)"
    [ -n "$CTX" ] || refuse "aucun cluster choisi : devzone activer mysql"
    installe || refuse "module inactif : devzone activer mysql"
    echo "▶ Suppression de MySQL et de ses volumes sur $CTX…"
    # L'Application part d'abord (#538) : sinon Argo CD recrée le namespace
    catalogue_argocd_delete mysql >/dev/null 2>&1 || true
    # RoleBinding retiré puis namespace supprimé par l'administrateur (#430)
    compte_retirer "$CTX" "$NS" >/dev/null 2>&1 || true
    compte_admin "$CTX" delete namespace "$NS" --wait=true >/dev/null
    relais_arreter mysql
    rm -f "$(fichier_echec)"
    echo "✔ namespace $NS et volume supprimés ; workspace/.mysql/root.env gardé"
    regenerer_identifiants
}
# État : désactivé, en échec, prêt, relais arrêté
etat() {
    local CTX
    CTX="$(cluster_lu)"
    if [ -z "$CTX" ] || ! installe; then
        echo "désactivé"
        return 0
    fi
    if [ "$(k get statefulset mysql -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)" != 1 ]; then
        echo "en échec sur $CTX : devzone appliquer"
        return 0
    fi
    if ! relais_actif mysql; then
        echo "prêt sur $CTX, relais arrêté : devzone appliquer"
        return 0
    fi
    echo "prêt sur $CTX : 127.0.0.1:$MYSQL_PORT, $(nombre_bases) base(s)"
}
# Crée l'utilisateur et la base d'un projet ; .env en 600, mot de passe gardé
creer() {
    local projet="${1:-}" nouveau="" fichier mdp arg
    valider_projet "$projet"
    for arg in "${@:2}"; do
        case "$arg" in
            --nouveau-mdp) nouveau=1 ;;
            *) refuse "argument inconnu : $arg" ;;
        esac
    done
    CTX="$(contexte)"
    installe || refuse "module inactif : devzone activer mysql"
    fichier="$SECRETS/$projet.env"
    if [ -z "$nouveau" ] && [ -s "$fichier" ]; then
        mdp="$(sed -n 's/^MYSQL_PASSWORD=//p' "$fichier" 2>/dev/null | tail -1)"
    else
        mdp="$(mot_de_passe)"
    fi
    mysql_admin <<SQL
CREATE USER IF NOT EXISTS '$projet'@'%' IDENTIFIED BY '$mdp';
ALTER USER '$projet'@'%' IDENTIFIED BY '$mdp';
CREATE DATABASE IF NOT EXISTS $projet;
GRANT ALL ON $projet.* TO '$projet'@'%';
SQL
    mkdir -p "$SECRETS"
    chmod 700 "$SECRETS"
    (
        umask 077
        cat >"$fichier" <<ENV
MYSQL_HOST=127.0.0.1
MYSQL_PORT=$MYSQL_PORT
MYSQL_USER=$projet
MYSQL_PASSWORD=$mdp
MYSQL_URL=jdbc:mysql://127.0.0.1:$MYSQL_PORT/$projet
ENV
    )
    echo "✔ base $projet prête ; identifiants : $fichier"
    regenerer_identifiants
}
# Liste les bases du serveur
liste() {
    local CTX
    CTX="$(contexte)"
    installe || refuse "module inactif : devzone activer mysql"
    mysql_admin -N -B -e "SHOW DATABASES" 2>/dev/null |
        grep -vE '^(information_schema|mysql|performance_schema|sys)$' |
        awk 'BEGIN { n = 0 } { printf "  %-30s\n", $1; n++ } END { if (n == 0) print "  (aucune base : devzone mysql creer <projet>)" }'
}
# Supprime la base et l'utilisateur d'un projet (confirmation sans --oui)
supprimer() {
    local projet="${1:-}" oui="" arg reponse
    valider_projet "$projet"
    for arg in "${@:2}"; do
        case "$arg" in
            --oui) oui=1 ;;
            *) refuse "argument inconnu : $arg" ;;
        esac
    done
    CTX="$(contexte)"
    installe || refuse "module inactif : devzone activer mysql"
    if [ -z "$oui" ]; then
        cluster_interactif || refuse "confirmation impossible sans terminal : devzone mysql supprimer $projet --oui"
        printf 'Supprimer la base %s et son utilisateur ? [o/N] ' "$projet" >&2
        read -r reponse || reponse=""
        case "$reponse" in
            o | O | oui) ;;
            *) echo "Abandon : rien n'a été supprimé."; return 0 ;;
        esac
    fi
    mysql_admin <<SQL
DROP DATABASE IF EXISTS $projet;
DROP USER IF EXISTS '$projet'@'%';
SQL
    rm -f "$SECRETS/$projet.env"
    echo "✔ base $projet supprimée"
    regenerer_identifiants
}
# Relance le relais 127.0.0.1:3306 si le namespace existe
relais() {
    local CTX
    CTX="$(cluster_lu)"
    [ -n "$CTX" ] && installe && relais_lancer mysql "$CTX" "$NS" svc/mysql 3306:3306
}
case "${1:-}" in
    installer) installer ;;
    supprimer-donnees) supprimer_donnees "${@:2}" ;;
    etat) etat ;;
    creer) creer "${@:2}" ;;
    liste) liste ;;
    supprimer) supprimer "${@:2}" ;;
    volume) mysql_volume "$NS" "${@:2}" ;;
    relais-lancer) relais ;;
    relais-arreter) relais_arreter mysql ;;
    *)
        echo "devzone : catalogue mysql : creer <projet> [--nouveau-mdp] | liste | supprimer <projet> [--oui] | volume [<nom>] [--supprimer <nom>] [--oui] | supprimer-donnees [--oui]" >&2
        exit 1
        ;;
esac
