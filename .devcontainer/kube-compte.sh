#!/usr/bin/env bash
# Compte Kubernetes limité (#430) : le contexte devzone (projets, relais,
# agents) ne peut agir que dans les namespaces devzone-*. Le compte est le
# ServiceAccount devzone-agent du namespace devzone-system, lié au ClusterRole
# edit (ni RBAC ni quotas) dans chaque namespace de devzone par un RoleBinding,
# avec un jeton TokenRequest de 24 h renouvelé au démarrage (demarrage.sh) et
# par « devzone reparer ». Les installeurs utilisent seuls le contexte
# administrateur (contexte de l hôte dans ~/.kube/hote.config, cluster kind
# dans ~/.kube/config) ; les shells et les agents n'ont que ~/.kube/config.
# Bibliothèque sourcée par cluster.sh ; exécutable pour le jeton :
#   kube-compte.sh jeton

COMPTES_NS=devzone-system
COMPTES_SA=devzone-agent
COMPTES_DUREE=24h
COMPTES_CONFIG="${DEVZONE_KUBE_CONFIG:-$HOME/.kube/config}"

# Fichier kubeconfig qui porte le contexte administrateur ctx : hote.config
# s'il y figure (clusters de l'hôte), sinon ~/.kube/config (clusters kind du
# conteneur).
compte_config_admin() {
    local ctx="$1" hote="${DEVZONE_KUBE_HOTE:-$HOME/.kube/hote.config}"
    if [ -n "$ctx" ] && [ -f "$hote" ]; then
        if KUBECONFIG="$hote" kubectl config get-contexts -o name 2>/dev/null | grep -qx -- "$ctx"; then
            echo "$hote"
            return 0
        fi
    fi
    echo "$COMPTES_CONFIG"
}

# kubectl sur le contexte administrateur : kubeconfig explicite qui porte ce
# contexte, jamais le KUBECONFIG combiné (l'administrateur ne passe jamais par
# le compte limité). Sans contexte connu : celui de kubectl.
compte_admin() {
    local ctx="$1" conf
    shift
    if [ -z "$ctx" ]; then
        ctx="$(kubectl config current-context 2>/dev/null || true)"
    fi
    conf="$(compte_config_admin "$ctx")"
    if [ -n "$ctx" ]; then
        kubectl --kubeconfig="$conf" --context "$ctx" "$@"
    else
        kubectl --kubeconfig="$conf" "$@"
    fi
}

# Contexte administrateur d'une installation : le cluster des services choisi
# (cluster_lu de cluster.sh), sinon le contexte courant de kubectl.
compte_ctx() {
    local ctx
    ctx="$(cluster_lu 2>/dev/null || true)"
    if [ -n "$ctx" ]; then
        echo "$ctx"
        return 0
    fi
    kubectl config current-context 2>/dev/null || true
}

# Pose le compte limité avec le contexte administrateur : namespace
# devzone-system et ServiceAccount devzone-agent (idempotent, repris au
# démarrage et à chaque installation).
compte_poser() {
    local ctx="$1"
    compte_admin "$ctx" create namespace "$COMPTES_NS" --dry-run=client -o yaml |
        compte_admin "$ctx" apply -f - >/dev/null || return 1
    compte_admin "$ctx" -n "$COMPTES_NS" create serviceaccount "$COMPTES_SA" \
        --dry-run=client -o yaml | compte_admin "$ctx" apply -f - >/dev/null || return 1
}

# Autorise le compte dans le namespace ns : RoleBinding devzone-agent vers le
# ClusterRole edit (lecture, écriture, secrets, NetworkPolicies — ni RBAC ni
# quotas), posé avec le contexte administrateur après la création du namespace.
# Le compte est posé d'abord s'il manque : une installation sur un cluster
# encore vierge rend le compte utilisable au prochain renouvellement de jeton.
compte_autoriser() {
    local ctx="$1" ns="$2"
    compte_poser "$ctx" || return 1
    compte_admin "$ctx" -n "$ns" create rolebinding "$COMPTES_SA" \
        --clusterrole=edit --serviceaccount="$COMPTES_NS:$COMPTES_SA" \
        --dry-run=client -o yaml | compte_admin "$ctx" apply -f - >/dev/null || return 1
}

# Retire l'autorisation du compte dans le namespace ns (désinstallation) :
# RoleBinding supprimé avec le contexte administrateur.
compte_retirer() {
    local ctx="$1" ns="$2"
    compte_admin "$ctx" -n "$ns" delete rolebinding "$COMPTES_SA" \
        --ignore-not-found >/dev/null || return 1
}

# Renouvelle le jeton du compte (TokenRequest de 24 h) et l'écrit dans le
# contexte devzone de ~/.kube/config : user devzone-agent, même cluster que le
# contexte administrateur (entrée cluster copiée : server, autorité de
# certificat et tls-server-name du contexte de l'hôte).
compte_jeton() {
    local ctx="$1" conf jeton cluster serveur tls ca_donnees ca_fichier
    local entree=()
    conf="$(compte_config_admin "$ctx")"
    jeton="$(compte_admin "$ctx" create token "$COMPTES_SA" -n "$COMPTES_NS" \
        --duration="$COMPTES_DUREE")" || return 1
    if [ -z "$jeton" ]; then
        echo "devzone : jeton du compte limité vide" >&2
        return 1
    fi
    cluster="$(KUBECONFIG="$conf" kubectl config view \
        -o jsonpath="{.contexts[?(@.name==\"$ctx\")].context.cluster}" 2>/dev/null || true)"
    if [ -z "$cluster" ]; then
        echo "devzone : cluster du contexte $ctx introuvable dans $conf" >&2
        return 1
    fi
    serveur="$(KUBECONFIG="$conf" kubectl config view \
        -o jsonpath="{.clusters[?(@.name==\"$cluster\")].cluster.server}" 2>/dev/null || true)"
    if [ -z "$serveur" ]; then
        echo "devzone : serveur du cluster $cluster introuvable dans $conf" >&2
        return 1
    fi
    ca_donnees="$(KUBECONFIG="$conf" kubectl config view \
        -o jsonpath="{.clusters[?(@.name==\"$cluster\")].cluster.certificate-authority-data}" 2>/dev/null || true)"
    ca_fichier="$(KUBECONFIG="$conf" kubectl config view \
        -o jsonpath="{.clusters[?(@.name==\"$cluster\")].cluster.certificate-authority}" 2>/dev/null || true)"
    entree=(--server="$serveur")
    if [ -n "$ca_donnees" ]; then
        entree+=(--certificate-authority-data="$ca_donnees")
    elif [ -n "$ca_fichier" ]; then
        entree+=(--certificate-authority="$ca_fichier" --embed-certs=true)
    fi
    tls="$(KUBECONFIG="$conf" kubectl config view \
        -o jsonpath="{.clusters[?(@.name==\"$cluster\")].cluster.tls-server-name}" 2>/dev/null || true)"
    if [ -n "$tls" ]; then
        entree+=(--tls-server-name="$tls")
    fi
    KUBECONFIG="$COMPTES_CONFIG" kubectl config set-cluster "$cluster" \
        ${entree[@]+"${entree[@]}"} >/dev/null
    KUBECONFIG="$COMPTES_CONFIG" kubectl config set-credentials "$COMPTES_SA" \
        --token="$jeton" >/dev/null
    KUBECONFIG="$COMPTES_CONFIG" kubectl config set-context devzone \
        --cluster="$cluster" --user="$COMPTES_SA" >/dev/null
}

# Exécution directe : jeton du compte renouvelé au démarrage (demarrage.sh) et
# par « devzone reparer ». Sans cluster des services choisi : rien à faire.
# Quand le fichier est sourcé, $0 diffère de BASH_SOURCE : rien ne s'exécute.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    if [ "${1:-}" != jeton ]; then
        echo "devzone : kube-compte : jeton" >&2
        exit 1
    fi
    ICI="$(cd "$(dirname "$0")" && pwd)"
    RACINE="${DEVZONE_RACINE:-$(dirname "$ICI")}"
    ETAT="${DEVZONE_ETAT:-$RACINE/.devzone.modules}"
    ctx="$(grep -E '^cluster=' "$ETAT" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
    if [ -z "$ctx" ]; then
        exit 0
    fi
    compte_poser "$ctx" || exit 1
    compte_jeton "$ctx" || exit 1
fi
