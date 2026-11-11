#!/usr/bin/env bash
# Module postgres (#280) : PostgreSQL partagé dans le cluster de devzone
# (cluster.sh), une base et un utilisateur par projet.
#   postgres.sh installer | desinstaller | etat | relais-lancer | relais-arreter
#   postgres.sh creer <projet> [--nouveau-mdp]   base, rôle, workspace/.postgres/<projet>.env
#   postgres.sh liste                            bases et propriétaires
#   postgres.sh psql [<projet>]                  console dans le pod
#   postgres.sh supprimer <projet> [--oui]       base, rôle et fichier .env
# Secrets dans workspace/.postgres/ (600, ignorés par git), jamais affichés.
set -euo pipefail

ICI="$(cd "$(dirname "$0")" && pwd)"
RACINE="${DEVZONE_RACINE:-$(dirname "$(dirname "$ICI")")}"
# shellcheck disable=SC2034 # lu par cluster.sh (bibliothèque sourcée)
ETAT="${DEVZONE_ETAT:-$RACINE/.devzone.modules}"
# shellcheck source=SCRIPTDIR/../cluster.sh
. "$ICI/../cluster.sh"
# shellcheck source=SCRIPTDIR/../password.sh
# shellcheck disable=SC1091
. "$ICI/../password.sh"
# Isolation réseau : namespace_isoler, d'où viennent les NetworkPolicies
# shellcheck source=SCRIPTDIR/../isolement.sh
# shellcheck disable=SC1091
. "$ICI/../isolement.sh"

NS=devzone-postgres
SECRETS="$RACINE/workspace/.postgres"
# Port du conteneur où le relais rend PostgreSQL joignable
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_ATTENTE="${POSTGRES_ATTENTE:-300}"
POSTGRES_TAILLE="${POSTGRES_TAILLE:-5Gi}"

refuse() { echo "devzone : postgres : $*" >&2; exit 2; }

# Vue regroupée des identifiants : un échec n'empêche jamais l'opération
regenerer_identifiants() {
    password_regenerer ||
        echo "devzone : postgres : identifiants regroupés non mis à jour (devzone mots-de-passe)" >&2
}

# Contexte du module : celui du cluster de devzone ; sans choix, rien n'est
# installé (devzone activer postgres le fixe)
contexte() {
    local c
    c="$(cluster_lu)"
    [ -n "$c" ] || refuse "aucun cluster choisi : devzone activer postgres"
    echo "$c"
}

k() {
    kubectl --context devzone -n "$NS" "$@"
}

# Namespace présent dans le cluster des services : lecture des namespaces
# réservée à l'administrateur (#430)
installe() {
    compte_admin "$(compte_ctx)" get namespace "$NS" >/dev/null 2>&1
}

# psql en superutilisateur dans le pod : connexion locale (socket), sans mot
# de passe ; le script SQL passe par stdin, jamais en argument visible
psql_admin() {
    k exec -i postgres-0 -c postgres -- psql -v ON_ERROR_STOP=1 -X -q -U postgres "$@"
}

# Nom de projet = nom du rôle et de la base : identifiant SQL simple, jamais
# à échapper, et pas un nom réservé
valider_projet() {
    local p="${1:-}"
    [ -n "$p" ] || refuse "nom de projet manquant"
    [[ "$p" =~ ^[a-z][a-z0-9_]{0,62}$ ]] || refuse "nom de projet invalide : $p (minuscules, chiffres, _ ; commence par une lettre)"
    case "$p" in
        postgres | template0 | template1) refuse "nom réservé : $p" ;;
    esac
}

mot_de_passe() {
    openssl rand -hex 24
}

# Mot de passe du superutilisateur : celui du secret s'il existe déjà dans le
# cluster (jamais régénéré : la base garde le sien), sinon le fichier local,
# sinon un nouveau
secret_admin() {
    local fichier="$SECRETS/admin-password" mdp
    mkdir -p "$SECRETS"
    chmod 700 "$SECRETS"
    if k get secret postgres-admin >/dev/null 2>&1; then
        mdp="$(k get secret postgres-admin -o jsonpath='{.data.password}' | base64 -d)"
        (umask 077 && printf '%s' "$mdp" >"$fichier")
        return 0
    fi
    if [ ! -s "$fichier" ]; then
        (umask 077 && mot_de_passe | tr -d '\n' >"$fichier")
    fi
    k create secret generic postgres-admin --from-file=password="$fichier" >/dev/null
}

installer() {
    CTX="$(contexte)"
    cluster_preparer "$CTX"
    # Sur une machine neuve, le contexte devzone doit viser le cluster choisi
    # avant toute pose de ressource (#396) ; sinon, tout s'arrête : message et code
    if ! contexte_devzone_poser "$CTX"; then
        echo "devzone : postgres : impossible de poser le contexte devzone sur $CTX" >&2
        return 1
    fi
    echo "▶ PostgreSQL sur le cluster $CTX (namespace $NS)…"
    # Namespace créé et étiqueté par l'administrateur (#430) : le compte limité
    # n'a pas le droit de créer d'objets hors des namespaces devzone-*
    compte_admin "$CTX" create namespace "$NS" --dry-run=client -o yaml |
        compte_admin "$CTX" apply -f - >/dev/null
    compte_admin "$CTX" label namespace "$NS" "$CLUSTER_ETIQUETTE" --overwrite >/dev/null
    # Compte limité autorisé dans le namespace : RoleBinding vers edit
    compte_autoriser "$CTX" "$NS"
    secret_admin
    sed "s/__TAILLE__/$POSTGRES_TAILLE/" "$ICI/postgres.yaml" |
        kubectl --context devzone apply -f - >/dev/null
    echo "▶ Attente de PostgreSQL (timeout ${POSTGRES_ATTENTE}s)…"
    if ! k rollout status statefulset/postgres --timeout="${POSTGRES_ATTENTE}s" >/dev/null; then
        echo "devzone : postgres : pas prêt après ${POSTGRES_ATTENTE}s : kubectl --context $CTX -n $NS describe pod postgres-0" >&2
        return 1
    fi
    relais_arreter postgres
    relais_lancer postgres "$CTX" "$NS" svc/postgres "$POSTGRES_PORT:5432"
    echo "✔ PostgreSQL prêt : 127.0.0.1:$POSTGRES_PORT dans le conteneur"
    echo "  Base d'un projet : devzone postgres creer <projet>"
    regenerer_identifiants
}

desinstaller() {
    CTX="$(cluster_lu)"
    relais_arreter postgres
    # Désinstallation sur une machine neuve : le contexte devzone est reposé sur
    # le cluster choisi (sinon il vise l'ancien) ; sans lui, seulement le
    # nettoyage local a lieu
    if [ -n "$CTX" ]; then
        contexte_devzone_poser "$CTX" ||
            echo "devzone : postgres : contexte devzone non posé sur $CTX ; nettoyage local seulement" >&2
    fi
    if [ -n "$CTX" ] && installe; then
        echo "▶ Suppression de PostgreSQL et de toutes ses bases sur $CTX…"
        # RoleBinding retiré puis namespace supprimé par l'administrateur (#430)
        compte_retirer "$CTX" "$NS" >/dev/null 2>&1 || true
        compte_admin "$CTX" delete namespace "$NS" --wait=true >/dev/null
        cluster_liberer "$CTX"
    fi
    rm -rf "$SECRETS"
    echo "✔ PostgreSQL désinstallé."
    regenerer_identifiants
}

nombre_bases() {
    psql_admin -At -c "SELECT count(*) FROM pg_database WHERE datname NOT IN ('postgres','template0','template1')" 2>/dev/null || echo "?"
}

etat() {
    CTX="$(cluster_lu)"
    if [ -z "$CTX" ] || ! installe; then
        echo "désactivé"
        return 0
    fi
    if [ "$(k get statefulset postgres -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)" != 1 ]; then
        echo "en échec sur $CTX : devzone appliquer"
    elif ! relais_actif postgres; then
        echo "prêt sur $CTX, relais arrêté : devzone appliquer"
    else
        echo "prêt sur $CTX : 127.0.0.1:$POSTGRES_PORT, $(nombre_bases) base(s)"
    fi
}

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
    installe || refuse "module inactif : devzone activer postgres"
    fichier="$SECRETS/$projet.env"
    # Mot de passe gardé : une application déjà configurée continue de marcher
    mdp="$(sed -n 's/^DB_PASSWORD=//p' "$fichier" 2>/dev/null || true)"
    if [ -z "$mdp" ] || [ -n "$nouveau" ]; then
        mdp="$(mot_de_passe)"
    fi
    # REVOKE … FROM PUBLIC : un projet ne se connecte pas à la base d'un autre
    psql_admin <<SQL
SELECT 'CREATE ROLE $projet LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$projet')\gexec
ALTER ROLE $projet PASSWORD '$mdp';
SELECT 'CREATE DATABASE $projet OWNER $projet' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$projet')\gexec
REVOKE CONNECT ON DATABASE $projet FROM PUBLIC;
GRANT CONNECT ON DATABASE $projet TO $projet;
SQL
    mkdir -p "$SECRETS"
    chmod 700 "$SECRETS"
    (
        umask 077
        cat >"$fichier" <<ENV
DB_HOST=127.0.0.1
DB_PORT=$POSTGRES_PORT
DB_NAME=$projet
DB_USER=$projet
DB_PASSWORD=$mdp
DB_URL=jdbc:postgresql://127.0.0.1:$POSTGRES_PORT/$projet
ENV
    )
    echo "✔ base $projet prête ; identifiants : $fichier"
    regenerer_identifiants
}

liste() {
    CTX="$(contexte)"
    installe || refuse "module inactif : devzone activer postgres"
    psql_admin -At -F ' ' -c "SELECT datname, pg_get_userbyid(datdba) FROM pg_database WHERE datname NOT IN ('postgres','template0','template1') ORDER BY 1" |
        awk 'BEGIN { n = 0 } { printf "  %-30s propriétaire %s\n", $1, $2; n++ } END { if (n == 0) print "  (aucune base : devzone postgres creer <projet>)" }'
}

console() {
    local projet="${1:-}" tty=()
    CTX="$(contexte)"
    installe || refuse "module inactif : devzone activer postgres"
    [ -t 0 ] && tty=(-t)
    if [ -n "$projet" ]; then
        valider_projet "$projet"
        k exec -i ${tty[@]+"${tty[@]}"} postgres-0 -c postgres -- psql -U "$projet" -d "$projet"
    else
        k exec -i ${tty[@]+"${tty[@]}"} postgres-0 -c postgres -- psql -U postgres
    fi
}

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
    installe || refuse "module inactif : devzone activer postgres"
    if [ -z "$oui" ]; then
        cluster_interactif || refuse "confirmation impossible sans terminal : devzone postgres supprimer $projet --oui"
        printf 'Supprimer la base %s et toutes ses données ? [o/N] ' "$projet" >&2
        read -r reponse || reponse=""
        case "$reponse" in
            o | O | oui) ;;
            *) echo "Abandon : rien n'a été supprimé."; return 0 ;;
        esac
    fi
    psql_admin <<SQL
DROP DATABASE IF EXISTS $projet WITH (FORCE);
DROP ROLE IF EXISTS $projet;
SQL
    rm -f "$SECRETS/$projet.env"
    echo "✔ base $projet supprimée"
    regenerer_identifiants
}

relais() {
    CTX="$(cluster_lu)"
    if [ -n "$CTX" ] && installe; then
        relais_lancer postgres "$CTX" "$NS" svc/postgres "$POSTGRES_PORT:5432"
    fi
}

autoriser() {
    local ns="${1:-}"
    [ -n "$ns" ] || { echo "devzone postgres : namespace manquant" >&2; return 2; }
    namespace_isoler "$ns"
    echo "devzone postgres : accès autorisé depuis $ns vers le service PostgreSQL"
}

interdire() {
    local ns="${1:-}" patch sortie
    [ -n "$ns" ] || { echo "devzone postgres : namespace manquant" >&2; return 2; }
    # JSON construit par jq, jamais assemblé à la main (le JSON invalide était
    # rejeté en silence) ; l'échec du patch est affiché et rend un code (#396)
    patch="$(jq -nc '{"spec":{"ingress":[{"from":[{"podSelector":{}}]}]}}')"
    if ! sortie="$(kubectl --context devzone -n "$NS" patch networkpolicy devzone-meme-namespace \
        -p "$patch" 2>&1)"; then
        echo "devzone : postgres : impossible de retirer la règle d'accès de $ns : $sortie" >&2
        return 1
    fi
    echo "devzone postgres : accès interdit depuis $ns vers le service PostgreSQL"
}

case "${1:-}" in
    installer) installer ;;
    desinstaller) desinstaller ;;
    etat) etat ;;
    creer) creer "${@:2}" ;;
    liste) liste ;;
    psql) console "${@:2}" ;;
    supprimer) supprimer "${@:2}" ;;
    relais-lancer) relais ;;
    relais-arreter) relais_arreter postgres ;;
    autoriser) autoriser "${@:2}" ;;
    interdire) interdire "${@:2}" ;;
    *)
        echo "devzone postgres : creer <projet> [--nouveau-mdp] | liste | psql [<projet>] | supprimer <projet> [--oui]" >&2
        exit 1
        ;;
esac
