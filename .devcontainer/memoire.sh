#!/usr/bin/env bash
# Memory check of the services cluster (#608): a module refuses its
# installation when the allocatable memory of the nodes is below its minimum.
# Sourced by the modules (gitlab, llm) and by the tests; bash 3.2 (macOS).
#   quantite_ki <quantite>              Kubernetes quantity in Ki
#   memoire_cluster_ki                  sum of the allocatable memory, in Ki
#   verifier_memoire_module <module> <minimum_go> [astuce]
# Messages in French. Return 0 when the memory is enough, 2 when it is not or
# when the cluster is unreachable.

# Converts a Kubernetes memory quantity (Ki, Mi, Gi, Ti, K, M, G, bytes)
# into Ki, to add the allocatable memory of the nodes.
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

# Sum of the allocatable memory of the services cluster nodes, in Ki.
# Reading the nodes is reserved to the administrator (#430).
memoire_cluster_ki() {
    local sortie valeur total=0
    sortie="$(compte_admin "$(compte_ctx)" get nodes \
        -o jsonpath='{range .items[*]}{.status.allocatable.memory}{"\n"}{end}' 2>/dev/null)" || return 1
    [ -n "$sortie" ] || return 1
    while IFS= read -r valeur; do
        [ -n "$valeur" ] || continue
        total=$((total + $(quantite_ki "$valeur")))
    done <<<"$sortie"
    echo "$total"
}

# Refuses the installation of <module> under <minimum_go> GiB of allocatable
# memory. The message says the minimum, the available memory and how to enlarge
# the cluster; [astuce] adds an optional hint (for example --preset light).
# Return 0 when the memory is enough, 2 when it is not or the cluster is
# unreachable.
verifier_memoire_module() {
    local nom_module="$1" minimum_go="$2" astuce="${3:-}" memoire
    if ! memoire="$(memoire_cluster_ki)"; then
        echo "devzone : ${nom_module} : cluster des services injoignable : devzone cluster" >&2
        return 2
    fi
    if [ "$memoire" -lt "$((minimum_go * 1048576))" ]; then
        echo "devzone : ${nom_module} : il faut au moins ${minimum_go} Go de mémoire allouable dans le cluster (disponible : $((memoire / 1048576)) Go) ; agrandir le cluster (Docker Desktop → Settings → Resources) puis relancer : devzone enable ${nom_module}${astuce:+ ; astuce : ${astuce}}" >&2
        return 2
    fi
    return 0
}
