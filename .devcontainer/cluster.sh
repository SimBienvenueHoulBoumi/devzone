#!/usr/bin/env bash
# Cluster de devzone (#280) : le cluster où se déploient les modules qui
# fournissent un service (postgres ; gitlab avec #279). Un seul choix par
# instance, gardé dans l'état (ligne « cluster=<contexte kubectl> ») : les
# services d'une instance vivent au même endroit et se déplacent ensemble
# (devzone cluster CTX).
# Bibliothèque sourcée : l'appelant définit RACINE et ETAT.
#   cluster_lu                       contexte choisi, rien s'il n'y en a pas
#   cluster_ecrire CTX               garde le choix dans l'état
#   cluster_candidats                clusters de l'hôte joignables, puis kind dédié
#   cluster_choisir [CTX]            CTX validé, sinon choix gardé, sinon menu
#                                    (terminal seulement), sinon défaut
#   cluster_preparer CTX             crée le cluster kind dédié s'il manque
#   cluster_liberer CTX              supprime le kind dédié devenu vide
#   kube_joignable_depuis_conteneur FICHIER   réécrit 127.0.0.1/localhost
#   relais_lancer NOM CTX NS CIBLE PORTS…   port-forward gardé en vie
#   relais_actif NOM / relais_arreter NOM

# Clusters kind et de l'hôte, comme remoteEnv de devcontainer.json : un
# docker exec ou un script lancé hors du terminal du conteneur ne l'a pas,
# et le relais doit voir le cluster de l'hôte
: "${KUBECONFIG:=$HOME/.kube/config:$HOME/.kube/hote.config}"
export KUBECONFIG

# État des modules : défini par l'appelant ; valeur par défaut pour les tests
: "${ETAT:=${DEVZONE_ETAT:-$HOME/.devzone.modules}}"

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

cluster_lu() {
    grep -E '^cluster=' "$ETAT" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

cluster_ecrire() {
    local tmp
    mkdir -p "$(dirname "$ETAT")"
    tmp="$(mktemp)"
    grep -vE '^cluster=' "$ETAT" 2>/dev/null >"$tmp" || true
    echo "cluster=$1" >>"$tmp"
    mv "$tmp" "$ETAT"
}

cluster_est_dedie() {
    [ "$1" = "${CLUSTER_DEDIE}" ]
}

cluster_joignable() {
    kubectl --context "$1" --request-timeout=3s get --raw /readyz >/dev/null 2>&1
}

# Contextes de l'hôte d'abord (joignables), puis le kind dédié en dernier
cluster_candidats() {
    local hote="${DEVZONE_KUBE_HOTE:-$HOME/.kube/hote.config}" c
    if [ -f "$hote" ]; then
        for c in $(KUBECONFIG="$hote" kubectl config get-contexts -o name 2>/dev/null); do
            cluster_est_dedie "$c" && continue
            cluster_joignable "$c" && echo "$c"
        done
    fi
    echo "$CLUSTER_DEDIE"
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
            else
                echo "  $i) $c   cluster de l'hôte"
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
    local voulu="${1:-}" c
    if [ -n "$voulu" ]; then
        while IFS= read -r c; do
            [ "$c" = "$voulu" ] && { echo "$voulu"; return 0; }
        done < <(cluster_candidats)
        echo "devzone : cluster inconnu ou injoignable : $voulu ; possibles : $(cluster_candidats | tr '\n' ' ')" >&2
        return 2
    fi
    c="$(cluster_lu)"
    if [ -n "$c" ]; then
        echo "$c"
    elif cluster_interactif; then
        cluster_menu
    else
        # Défaut : cluster de l'hôte s'il répond, sinon kind dédié
        local hote_choix=""
        if [ -f "${DEVZONE_KUBE_HOTE:-$HOME/.kube/hote.config}" ]; then
            hote_choix="$(KUBECONFIG="${DEVZONE_KUBE_HOTE:-$HOME/.kube/hote.config}" kubectl config current-context 2>/dev/null || true)"
        fi
        if [ -n "$hote_choix" ] && cluster_joignable "$hote_choix"; then
            echo "$hote_choix"
        else
            echo "$CLUSTER_DEDIE"
        fi
    fi
}

cluster_preparer() {
    local ctx="$1"
    if [ "$ctx" = "$CLUSTER_DEDIE" ]; then
        if ! kind get clusters 2>/dev/null | grep -qx "devzone${INSTANCE_SUFFIX}"; then
            echo "▶ Création du cluster kind devzone (environ 1 min)…"
            # Sur le Docker de l'hôte, l'API écoute sur 127.0.0.1 du poste :
            # kube_joignable_depuis_conteneur la rend joignable du conteneur
            # (host.docker.internal), sans l'exposer sur le réseau local.
            kind create cluster --name "devzone${INSTANCE_SUFFIX}" --wait 120s
            kube_joignable_depuis_conteneur "$HOME/.kube/config"
        fi
    elif ! cluster_joignable "$ctx"; then
        echo "devzone : cluster $ctx injoignable (module kubernetes actif ? cluster démarré ?)" >&2
        return 1
    fi
}

# Kind dédié sans plus aucun namespace de devzone : supprimé (il n'occupe
# que de la mémoire). Jamais un cluster de l'hôte.
cluster_liberer() {
    local ctx="$1" reste
    cluster_est_dedie "$ctx" || return 0
    kind get clusters 2>/dev/null | grep -qx "devzone${INSTANCE_SUFFIX}" || return 0
    reste="$(kubectl --context "$ctx" get namespaces -l "$CLUSTER_ETIQUETTE" -o name 2>/dev/null || true)"
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
