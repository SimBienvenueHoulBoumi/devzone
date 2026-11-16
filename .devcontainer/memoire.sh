#!/usr/bin/env bash
# Memory check of the services cluster (#608, #612): a module refuses its
# installation when the allocatable memory of the nodes is below its minimum.
# Sourced by the modules (gitlab, llm) and by the tests; bash 3.2 (macOS).
#   quantite_ki <quantite>              Kubernetes quantity in Ki
#   memoire_cluster_ki                  allocatable memory of the cluster, in Ki
#   verifier_memoire_module <module> <minimum_go> [astuce]
# Messages in French. Return 0 when the memory is enough, 2 when it is not or
# when the cluster is unreachable.

# Globals written by memoire_cluster_ki (#612) and read by
# verifier_memoire_module, which calls the function directly: a call written
# memoire="$(memoire_cluster_ki)" would run it in a subshell and lose them.
# Callers that only need the number keep using $(memoire_cluster_ki): the
# value is still printed on stdout (argocd, gitlab, llm are unaffected).
#   MEMOIRE_KI      same value as on stdout, in Ki
#   MEMOIRE_REGLE   "maximum" when every node is a kind node (the nodes share
#                   one VM), "somme" otherwise
MEMOIRE_KI=""
MEMOIRE_REGLE=""

# Converts a Kubernetes memory quantity (Ki, Mi, Gi, Ti, K, M, G, bytes)
# into Ki, to total the allocatable memory of the nodes.
quantite_ki() {
    local q="${1:-}" nombre
    case "$q" in
        *Ki) nombre="${q%Ki}"; echo $((nombre)) ;;
        *Mi) nombre="${q%Mi}"; echo $((nombre * 1024)) ;;
        *Gi) nombre="${q%Gi}"; echo $((nombre * 1024 * 1024)) ;;
        *Ti) nombre="${q%Ti}"; echo $((nombre * 1024 * 1024 * 1024)) ;;
        *K | *k) nombre="${q%[Kk]}"; echo $((nombre * 1000 / 1024)) ;;
        *M) nombre="${q%M}"; echo $((nombre * 1000 * 1000 / 1024)) ;;
        *G) nombre="${q%G}"; echo $((nombre * 1000 * 1000 * 1000 / 1024)) ;;
        *)
            case "$q" in
                '' | *[!0-9]*) echo 0 ;;
                *) echo $((q / 1024)) ;;
            esac
            ;;
    esac
}

# Allocatable memory of the services cluster nodes, in Ki. Reading the nodes
# is reserved to the administrator (#430). One kubectl call gives, per node,
# its providerID and its allocatable memory on one "<providerID>|<memory>"
# line (#612). A kind cluster runs on a single Docker daemon: its nodes share
# the memory of one VM and each of them declares the whole VM, so adding them
# up lies. When every providerID starts with "kind://" the greatest node
# memory is returned (MEMOIRE_REGLE=maximum); as soon as one node has no such
# prefix or an empty providerID the sum is returned (MEMOIRE_REGLE=somme), as
# before. Known limit, documented: k3d and minikube in Docker mode share a VM
# too but are not kind, they stay on the sum. A line without the separator
# carries the memory alone, so it is a node without providerID (sum).
memoire_cluster_ki() {
    local sortie ligne providerID memoire noeud total=0 max=0 n=0 tous_kind=1
    MEMOIRE_KI=""
    MEMOIRE_REGLE=""
    sortie="$(compte_admin "$(compte_ctx)" get nodes \
        -o jsonpath='{range .items[*]}{.spec.providerID}{"|"}{.status.allocatable.memory}{"\n"}{end}' 2>/dev/null)" || return 1
    [ -n "$sortie" ] || return 1
    while IFS= read -r ligne; do
        [ -n "$ligne" ] || continue
        case "$ligne" in
            *'|'*)
                providerID="${ligne%%|*}"
                memoire="${ligne#*|}"
                ;;
            *)
                providerID=""
                memoire="$ligne"
                ;;
        esac
        noeud="$(quantite_ki "$memoire")"
        total=$((total + noeud))
        if [ "$noeud" -gt "$max" ]; then max="$noeud"; fi
        case "$providerID" in
            kind://*) ;;
            *) tous_kind=0 ;;
        esac
        n=$((n + 1))
    done <<<"$sortie"
    if [ "$n" -gt 0 ] && [ "$tous_kind" -eq 1 ]; then
        MEMOIRE_REGLE="maximum"
        MEMOIRE_KI="$max"
    else
        MEMOIRE_REGLE="somme"
        MEMOIRE_KI="$total"
    fi
    echo "$MEMOIRE_KI"
}

# Refuses the installation of <module> under <minimum_go> GiB of allocatable
# memory. The message says the minimum, the available memory and how to enlarge
# the cluster; [astuce] adds an optional hint (for example --preset light).
# On a kind cluster (#612) the available memory is the one of a single node
# and the message says so. Return 0 when the memory is enough, 2 when it is
# not or the cluster is unreachable.
verifier_memoire_module() {
    local nom_module="$1" minimum_go="$2" astuce="${3:-}" memoire precision=""
    if ! memoire_cluster_ki >/dev/null; then
        echo "devzone : ${nom_module} : cluster des services injoignable : devzone cluster" >&2
        return 2
    fi
    memoire="$MEMOIRE_KI"
    if [ "$MEMOIRE_REGLE" = "maximum" ]; then
        precision=" (mémoire d'un seul nœud : cluster kind, VM partagée)"
    fi
    if [ "$memoire" -lt "$((minimum_go * 1048576))" ]; then
        echo "devzone : ${nom_module} : il faut au moins ${minimum_go} Go de mémoire allouable dans le cluster (disponible : $((memoire / 1048576)) Go)${precision} ; agrandir le cluster (Docker Desktop → Settings → Resources) puis relancer : devzone enable ${nom_module}${astuce:+ ; astuce : ${astuce}}" >&2
        return 2
    fi
    return 0
}
