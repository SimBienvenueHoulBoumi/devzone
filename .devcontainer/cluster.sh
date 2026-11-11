#!/usr/bin/env bash
# Cluster de devzone (#280) : le cluster où se déploient les modules qui
# fournissent un service (postgres ; gitlab avec #279). Un seul choix par
# instance, gardé dans l'état (ligne « cluster=<contexte kubectl> ») : les
# services d'une instance vivent au même endroit et se déplacent ensemble
# (devzone cluster CTX).
# Bibliothèque sourcée : l'appelant définit RACINE et ETAT.
#   cluster_lu                       contexte choisi, rien s'il n'y en a pas
#   cluster_ecrire CTX               garde le choix dans l'état
#   cluster_est_local CTX            0 si cluster local (config, sans réseau)
#   cluster_candidats                locaux, puis kind dédié, puis distants
#   cluster_choisir [CTX] [--confirmer CTX]
#                                    CTX validé (distant : confirmation),
#                                    sinon choix gardé, sinon menu
#                                    (terminal seulement), sinon défaut local
#   cluster_preparer CTX             crée le cluster kind dédié s'il manque
#   cluster_liberer CTX              supprime le kind dédié devenu vide
#   kube_joignable_depuis_conteneur FICHIER   réécrit 127.0.0.1/localhost
#   relais_lancer NOM CTX NS CIBLE PORTS…   port-forward gardé en vie
#   relais_actif NOM / relais_arreter NOM
#   compte_* (kube-compte.sh #430)    compte limité et contexte administrateur

# Clusters kind et de l'hôte, comme remoteEnv de devcontainer.json : un
# docker exec ou un script lancé hors du terminal du conteneur ne l'a pas,
# et le relais doit voir le cluster de l'hôte
: "${KUBECONFIG:=$HOME/.kube/config:$HOME/.kube/hote.config}"
export KUBECONFIG

# État des modules : défini par l'appelant ; valeur par défaut pour les tests
: "${ETAT:=${DEVZONE_ETAT:-$HOME/.devzone.modules}}"

# Écriture sûre de l'état (#417) : verrou, temporaire dans le dossier de
# l'état, copie de secours .prec — partagée par devzone, ports et ports-auto
# shellcheck source=SCRIPTDIR/etat.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/etat.sh"

# Nom d'instance : vide ou « devzone » = instance par défaut (pas de suffixe)
: "${DEVZONE_INSTANCE:=}"
INSTANCE_SUFFIX=""
if [ -n "$DEVZONE_INSTANCE" ] && [ "$DEVZONE_INSTANCE" != "devzone" ]; then
    INSTANCE_SUFFIX="-${DEVZONE_INSTANCE}"
fi

# Cluster kind dédié, créé sur le Docker de l'hôte ; nom suffixé par instance
CLUSTER_DEDIE=kind-devzone${INSTANCE_SUFFIX}
# Étiquette posée sur tout namespace créé par devzone : un kind dédié sans
# namespace étiqueté n'a plus d'usage et peut être supprimé
CLUSTER_ETIQUETTE=app.kubernetes.io/managed-by=devzone

# Réécriture 127.0.0.1 → host.docker.internal (#291) : partagée avec
# l'enveloppe kind, qui l'applique aussi aux clusters créés à la main
# shellcheck source=SCRIPTDIR/kube-joignable.sh
. "$(dirname "${BASH_SOURCE[0]}")/kube-joignable.sh"

# Compte Kubernetes limité (#430) : compte_poser, compte_autoriser,
# compte_retirer, compte_jeton, compte_admin (contexte administrateur) ;
# les installeurs l'utilisent, cluster_liberer aussi
# shellcheck source=SCRIPTDIR/kube-compte.sh
. "$(dirname "${BASH_SOURCE[0]}")/kube-compte.sh"

cluster_lu() {
    grep -E '^cluster=' "$ETAT" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

cluster_ecrire() {
    etat_ecrire cluster "$1"
}

cluster_est_dedie() {
    [ "$1" = "${CLUSTER_DEDIE}" ]
}

# Cluster local : lu dans la configuration KUBECONFIG, sans appel réseau.
# Le kind dédié est toujours local ; un cluster de l'hôte l'est si son
# serveur écoute sur une adresse de boucle (127.0.0.1, localhost, ::1,
# host.docker.internal).
cluster_est_local() {
    local ctx="$1" cluster serveur hote
    cluster_est_dedie "$ctx" && return 0
    cluster="$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$ctx\")].context.cluster}" 2>/dev/null || true)"
    [ -n "$cluster" ] || return 1
    serveur="$(kubectl config view -o jsonpath="{.clusters[?(@.name==\"$cluster\")].cluster.server}" 2>/dev/null || true)"
    [ -n "$serveur" ] || return 1
    # Règle par le nom (ancienne règle de metrics-server.sh)
    case "$ctx" in
        kind-* | docker-desktop | rancher-desktop | orbstack | minikube) return 0 ;;
    esac
    # Extraction de l'hôte (adresses IPv6 entre crochets gérées)
    hote="${serveur#*://}"
    hote="${hote%%/*}"
    if [[ "$hote" == \[* ]]; then
        hote="${hote#[}"
        hote="${hote%%]*}"
    else
        hote="${hote%%:*}"
    fi
    case "$hote" in
        127.0.0.1 | localhost | ::1 | host.docker.internal) return 0 ;;
        *-control-plane) return 0 ;;
    esac
    return 1
}

# Pose le contexte « devzone » (cluster + user) sur le contexte donné (défaut :
# le courant) : après une installation sur une machine neuve, --context devzone
# vise d'emblée le cluster des services choisi (#396)
contexte_devzone_poser() {
    local ctx cluster user
    ctx="${1:-$(kubectl config current-context 2>/dev/null || true)}"
    if [ -z "$ctx" ]; then
        return 1
    fi
    cluster="$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$ctx\")].context.cluster}" 2>/dev/null || true)"
    user="$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$ctx\")].context.user}" 2>/dev/null || true)"
    if [ -n "$cluster" ]; then
        kubectl config set-context devzone --cluster="$cluster" --user="$user" >/dev/null 2>&1
    else
        return 1
    fi
}

cluster_joignable() {
    kubectl --context "$1" --request-timeout=3s get --raw /readyz >/dev/null 2>&1
}

# Contextes de l'hôte : locaux d'abord, puis le kind dédié, enfin les distants
cluster_candidats() {
    local hote="${DEVZONE_KUBE_HOTE:-$HOME/.kube/hote.config}" c
    if [ -f "$hote" ]; then
        # 1. Clusters locaux de l'hôte (serveur sur une adresse de boucle)
        for c in $(KUBECONFIG="$hote" kubectl config get-contexts -o name 2>/dev/null); do
            cluster_est_dedie "$c" && continue
            if cluster_est_local "$c" && cluster_joignable "$c"; then
                echo "$c"
            fi
        done
    fi
    # 2. Cluster kind dédié
    echo "$CLUSTER_DEDIE"
    if [ -f "$hote" ]; then
        # 3. Clusters distants de l'hôte
        for c in $(KUBECONFIG="$hote" kubectl config get-contexts -o name 2>/dev/null); do
            cluster_est_dedie "$c" && continue
            if ! cluster_est_local "$c" && cluster_joignable "$c"; then
                echo "$c"
            fi
        done
    fi
    return 0
}

# Menu sur stderr (stdout porte la réponse) ; Entrée = premier candidat
cluster_menu() {
    local candidats=() c i=1 reponse
    while IFS= read -r c; do candidats+=("$c"); done < <(cluster_candidats)
{
        echo "devzone : sur quel cluster installer les services de devzone ?"
        for c in "${candidats[@]}"; do
            if cluster_est_dedie "$c"; then
                echo "  $i) $c   cluster kind dédié, dans le conteneur (défaut)"
            elif cluster_est_local "$c"; then
                echo "  $i) $c   cluster local"
            else
                echo "  $i) $c   cluster distant"
            fi
            i=$((i + 1))
        done
        [ -f "${DEVZONE_KUBE_HOTE:-$HOME/.kube/hote.config}" ] ||
            echo "  (clusters de l'hôte invisibles : devzone activer kubernetes)"
    } >&2
    printf 'Numéro [1] : ' >&2
    read -r reponse || reponse=""
    reponse="${reponse:-1}"
    case "$reponse" in
        *[!0-9]* | 0) echo "devzone : choix invalide : $reponse" >&2; return 2 ;;
    esac
    if [ "$reponse" -gt "${#candidats[@]}" ]; then
        echo "devzone : choix invalide : $reponse" >&2
        return 2
    fi
    echo "${candidats[$((reponse - 1))]}"
}

# Terminal interactif ; DEVZONE_INTERACTIF=1 pour les tests (stdin redirigé)
cluster_interactif() {
    [ "${DEVZONE_INTERACTIF:-}" = 1 ] || [ -t 0 ]
}

cluster_choisir() {
    local voulu="" confirmer="" c reponse arg
    while [ "$#" -gt 0 ]; do
        arg="$1"
        shift
        case "$arg" in
            --confirmer)
                if [ "$#" -eq 0 ]; then
                    echo "devzone : --confirmer attend un contexte" >&2
                    return 2
                fi
                confirmer="$1"
                shift
                ;;
            --confirmer=*) confirmer="${arg#*=}" ;;
            -*)
                echo "devzone : argument inconnu : $arg (cluster_choisir [CTX] [--confirmer CTX])" >&2
                return 2
                ;;
            *)
                if [ -n "$voulu" ]; then
                    echo "devzone : argument inconnu : $arg (cluster_choisir [CTX] [--confirmer CTX])" >&2
                    return 2
                fi
                voulu="$arg"
                ;;
        esac
    done
    if [ -n "$voulu" ]; then
        while IFS= read -r c; do
            [ "$c" = "$voulu" ] && break
        done < <(cluster_candidats)
        if [ "$c" != "$voulu" ]; then
            echo "devzone : cluster inconnu ou injoignable : $voulu ; possibles : $(cluster_candidats | tr '\n' ' ')" >&2
            return 2
        fi
        # Distant : confirmation requise. --confirmer ne vaut que s'il est
        # exactement le contexte demandé ; DEVZONE_CLUSTER_DISTANT reste
        # accepté pour les tests et la CI.
        if ! cluster_est_local "$voulu"; then
            if [ -n "$confirmer" ]; then
                if [ "$confirmer" != "$voulu" ]; then
                    echo "devzone : cluster distant refusé : $voulu (--confirmer $voulu)" >&2
                    return 2
                fi
            elif [ -n "${DEVZONE_CLUSTER_DISTANT:-}" ]; then
                if [ "${DEVZONE_CLUSTER_DISTANT}" != "$voulu" ]; then
                    echo "devzone : cluster distant refusé : $voulu (DEVZONE_CLUSTER_DISTANT doit valoir exactement $voulu)" >&2
                    return 2
                fi
            elif cluster_interactif; then
                printf 'cluster distant : %s ; tape son nom pour confirmer : ' "$voulu" >&2
                read -r reponse || reponse=""
                if [ "$reponse" != "$voulu" ]; then
                    echo "devzone : cluster distant refusé : $voulu (--confirmer $voulu)" >&2
                    return 2
                fi
            else
                echo "devzone : cluster distant refusé : $voulu (--confirmer $voulu)" >&2
                return 2
            fi
        fi
        echo "$voulu"
        return 0
    fi
    c="$(cluster_lu)"
    if [ -n "$c" ]; then
        echo "$c"
    elif cluster_interactif; then
        cluster_menu
    else
        # Défaut : local seulement (jamais distant par défaut)
        local hote_choix=""
        if [ -f "${DEVZONE_KUBE_HOTE:-$HOME/.kube/hote.config}" ]; then
            hote_choix="$(KUBECONFIG="${DEVZONE_KUBE_HOTE:-$HOME/.kube/hote.config}" kubectl config current-context 2>/dev/null || true)"
        fi
        if [ -n "$hote_choix" ] && cluster_est_local "$hote_choix" && cluster_joignable "$hote_choix"; then
            echo "$hote_choix"
        else
            echo "$CLUSTER_DEDIE"
        fi
    fi
}

# Lance kind sans basculer le contexte courant de kubectl (#366) : le contexte
# d'avant est remis, ou retiré s'il n'y en avait pas. Le code de kind est rendu
# meme sous set -e : la restauration a lieu avant.
kind_sans_basculer() {
    local precedent code=0
    precedent="$(kubectl config current-context 2>/dev/null || true)"
    kind "$@" || code=$?
    if [ -n "$precedent" ]; then
        kubectl config use-context "$precedent" >/dev/null 2>&1 || true
    else
        KUBECONFIG="$HOME/.kube/config" kubectl config unset current-context >/dev/null 2>&1 || true
    fi
    return "$code"
}

# Cree un cluster kind sans basculer le contexte courant de kubectl.
kind_creer_sans_basculer() {
    kind_sans_basculer create cluster "$@"
}

cluster_preparer() {
    local ctx="$1"
    if [ "$ctx" = "$CLUSTER_DEDIE" ]; then
        if ! kind get clusters 2>/dev/null | grep -qx "devzone${INSTANCE_SUFFIX}"; then
            echo "▶ Création du cluster kind devzone (environ 1 min)…"
            # Sur le Docker de l'hôte, l'API écoute sur 127.0.0.1 du poste :
            # kube_joignable_depuis_conteneur la rend joignable du conteneur
            # (host.docker.internal), sans l'exposer sur le réseau local.
            # Docker de l'hôte chargé (son Kubernetes, d'autres clusters) : l'API du
            # nœud peut redémarrer pendant l'initialisation et kind abandonne à
            # quelques secondes près. Une seconde tentative, sur un cluster neuf.
            if ! kind_creer_sans_basculer --name "devzone${INSTANCE_SUFFIX}" --wait 120s; then
                echo "▶ Nouvelle tentative de création du cluster kind…"
                kind delete cluster --name "devzone${INSTANCE_SUFFIX}" >/dev/null 2>&1 || true
                kind_creer_sans_basculer --name "devzone${INSTANCE_SUFFIX}" --wait 120s || return 1
            fi
            kube_joignable_depuis_conteneur "$HOME/.kube/config"
        fi
    elif ! cluster_joignable "$ctx"; then
        echo "devzone : cluster $ctx injoignable (module kubernetes actif ? cluster démarré ?)" >&2
        return 1
    fi
    # S'il vient d'être créé, le cluster des services doit tout de suite porter
    # le contexte devzone, sans quoi l'installation vise l'ancien cluster (#396)
    contexte_devzone_poser "$ctx" || echo "devzone : contexte devzone non posé sur $ctx" >&2
}

# Kind dédié sans plus aucun namespace de devzone : supprimé (il n'occupe
# que de la mémoire). Jamais un cluster de l'hôte.
cluster_liberer() {
    local ctx="$1" reste
    cluster_est_dedie "$ctx" || return 0
    kind get clusters 2>/dev/null | grep -qx "devzone${INSTANCE_SUFFIX}" || return 0
    # Lecture des namespaces étiquetés par l'administrateur (#430) : la liste
    # des namespaces est refusée au compte limité
    reste="$(compte_admin "$ctx" get namespaces -l "$CLUSTER_ETIQUETTE" -o name 2>/dev/null || true)"
    if [ -z "$reste" ]; then
        kind delete cluster --name "devzone${INSTANCE_SUFFIX}" >/dev/null 2>&1 || true
        echo "▶ Cluster kind devzone supprimé (plus aucun service)."
    fi
}

# ---- Relais : port d'un service du cluster sur 127.0.0.1 du conteneur ----
# kubectl port-forward marche sur tout cluster dont l'API répond (kind dédié
# comme cluster de l'hôte), sans exposer de port sur les nœuds. Il s'arrête
# quand le pod redémarre : la boucle le relance. PID et journal dans
# workspace/.<nom>/ (dossier du module, ignoré par git).
relais_dossier() {
    echo "$RACINE/workspace/.$1"
}

relais_actif() {
    local pid
    pid="$(cat "$(relais_dossier "$1")/relais.pid" 2>/dev/null || true)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

relais_lancer() {
    local nom="$1" ctx="$2" ns="$3" cible="$4" dossier
    shift 4
    dossier="$(relais_dossier "$nom")"
    mkdir -p "$dossier"
    relais_actif "$nom" && return 0
    # setsid : session à part, le relais survit à la fin du script qui l'a
    # lancé (postStartCommand, make shell) ; absent sur macOS (tests bash 3.2)
    local detache=()
    command -v setsid >/dev/null 2>&1 && detache=(setsid)
    # port-forward vise un pod précis et ne voit sa disparition qu'à la
    # connexion suivante, qui échoue. Pour un service, la boucle suit donc le
    # pod prêt derrière lui (UID dans ses endpoints) : attend qu'il y en ait
    # un, puis relance port-forward dès qu'il change (pod redémarré).
    # shellcheck disable=SC2016 # variables développées par le bash du relais
    ${detache[@]+"${detache[@]}"} nohup bash -c '
        pod() {
            case "$2" in
                svc/*) kubectl --context "$0" -n "$1" get endpoints "${2#svc/}" -o jsonpath="{.subsets[*].addresses[*].targetRef.uid}" 2>/dev/null ;;
                *) echo fixe ;;
            esac
        }
        while :; do
            until [ -n "$(pod "$@")" ]; do sleep 2; done
            actuel="$(pod "$@")"
            kubectl --context "$0" -n "$1" port-forward --address 127.0.0.1 "$2" "${@:3}" &
            pf=$!
            while kill -0 "$pf" 2>/dev/null; do
                sleep 5
                [ "$(pod "$@")" = "$actuel" ] || { kill "$pf" 2>/dev/null; break; }
            done
            wait "$pf" 2>/dev/null
            sleep 1
        done' \
        "$ctx" "$ns" "$cible" "$@" >"$dossier/relais.log" 2>&1 &
    echo "$!" >"$dossier/relais.pid"
}

relais_arreter() {
    local fichier pid enfants
    fichier="$(relais_dossier "$1")/relais.pid"
    pid="$(cat "$fichier" 2>/dev/null || true)"
    if [ -n "$pid" ]; then
        # Enfants (port-forward) relevés avant : une fois la boucle tuée, ils
        # sont rattachés à init et pgrep -P ne les voit plus. La boucle
        # d'abord, sinon elle relancerait le port-forward.
        enfants="$(pgrep -P "$pid" 2>/dev/null || true)"
        kill "$pid" 2>/dev/null || true
        # shellcheck disable=SC2086 # liste de PID
        [ -z "$enfants" ] || kill $enfants 2>/dev/null || true
    fi
    rm -f "$fichier"
}
