#!/usr/bin/env bash
# Cluster de devzone (#280) : le cluster où se déploient les modules qui
# fournissent un service (postgres ; gitlab avec #279). Un seul choix par
# instance, gardé dans l'état (ligne « cluster=<contexte kubectl> ») : les
# services d'une instance vivent au même endroit et se déplacent ensemble
# (devzone cluster CTX).
# Bibliothèque sourcée : l'appelant définit RACINE et ETAT.
#   cluster_lu                       contexte choisi, rien s'il n'y en a pas
#   cluster_ecrire CTX               garde le choix dans l'état
#   cluster_candidats                kind dédié, puis contextes de l'hôte joignables
#   cluster_choisir [CTX]            CTX validé, sinon choix gardé, sinon menu
#                                    (terminal seulement), sinon kind dédié
#   cluster_preparer CTX             crée le cluster kind dédié s'il manque
#   cluster_liberer CTX              supprime le kind dédié devenu vide
#   relais_lancer NOM CTX NS CIBLE PORTS…   port-forward gardé en vie
#   relais_actif NOM / relais_arreter NOM

# Clusters kind et de l'hôte, comme remoteEnv de devcontainer.json : un
# docker exec ou un script lancé hors du terminal du conteneur ne l'a pas,
# et le relais doit voir le cluster de l'hôte
: "${KUBECONFIG:=$HOME/.kube/config:$HOME/.kube/hote.config}"
export KUBECONFIG

# Cluster kind dédié, dans le Docker interne : toujours disponible, même sans
# cluster sur l'hôte (Codespaces, Linux avec Docker Engine)
CLUSTER_DEDIE=kind-devzone
# Étiquette posée sur tout namespace créé par devzone : un kind dédié sans
# namespace étiqueté n'a plus d'usage et peut être supprimé
CLUSTER_ETIQUETTE=app.kubernetes.io/managed-by=devzone

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
    [ "$1" = "$CLUSTER_DEDIE" ]
}

cluster_joignable() {
    kubectl --context "$1" --request-timeout=3s get --raw /readyz >/dev/null 2>&1
}

# Contextes de l'hôte : ceux de ~/.kube/hote.config, posé par kube-config.sh
# seulement quand le module kubernetes est actif. Joignables seulement : un
# cluster arrêté ne peut rien recevoir.
cluster_candidats() {
    local hote="${DEVZONE_KUBE_HOTE:-$HOME/.kube/hote.config}" c
    echo "$CLUSTER_DEDIE"
    [ -f "$hote" ] || return 0
    for c in $(KUBECONFIG="$hote" kubectl config get-contexts -o name 2>/dev/null); do
        cluster_est_dedie "$c" && continue
        cluster_joignable "$c" && echo "$c"
    done
    return 0
}

# Menu sur stderr (stdout porte la réponse) ; Entrée = kind dédié
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
        # Sans terminal (post-create, démarrage) : jamais de question
        echo "$CLUSTER_DEDIE"
    fi
}

cluster_preparer() {
    local ctx="$1"
    if cluster_est_dedie "$ctx"; then
        if ! kind get clusters 2>/dev/null | grep -qx devzone; then
            echo "▶ Création du cluster kind devzone (environ 1 min)…"
            kind create cluster --name devzone --wait 120s
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
    kind get clusters 2>/dev/null | grep -qx devzone || return 0
    reste="$(kubectl --context "$ctx" get namespaces -l "$CLUSTER_ETIQUETTE" -o name 2>/dev/null || true)"
    if [ -z "$reste" ]; then
        kind delete cluster --name devzone >/dev/null 2>&1 || true
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
