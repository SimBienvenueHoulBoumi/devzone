#!/usr/bin/env bash
# Memory check of the services cluster (#608, #612): a module refuses its
# installation when the allocatable memory of the nodes is below its minimum.
# Sourced by the modules (gitlab, llm) and by the tests; bash 3.2 (macOS).
#   quantity_ki <quantity>                   Kubernetes quantity in Ki
#   memory_cluster_ki                        allocatable memory of the cluster, in Ki
#   check_module_memory <module> <minimum_gi> [hint]
# Messages in English. Return 0 when the memory is enough, 2 when it is not or
# when the cluster is unreachable.

# Globals written by memory_cluster_ki (#612) and read by
# check_module_memory, which calls the function directly: a call written
# memory="$(memory_cluster_ki)" would run it in a subshell and lose them.
# Callers that only need the number keep using $(memory_cluster_ki): the
# value is still printed on stdout (argocd, gitlab, llm are unaffected).
#   MEMORY_KI      same value as on stdout, in Ki
#   MEMORY_RULE    "maximum" when every node is a kind node (the nodes share
#                  one VM), "sum" otherwise
MEMORY_KI=""
MEMORY_RULE=""

# Converts a Kubernetes memory quantity (Ki, Mi, Gi, Ti, K, M, G, bytes)
# into Ki, to total the allocatable memory of the nodes.
quantity_ki() {
    local q="${1:-}" number
    case "$q" in
        *Ki) number="${q%Ki}"; echo $((number)) ;;
        *Mi) number="${q%Mi}"; echo $((number * 1024)) ;;
        *Gi) number="${q%Gi}"; echo $((number * 1024 * 1024)) ;;
        *Ti) number="${q%Ti}"; echo $((number * 1024 * 1024 * 1024)) ;;
        *K | *k) number="${q%[Kk]}"; echo $((number * 1000 / 1024)) ;;
        *M) number="${q%M}"; echo $((number * 1000 * 1000 / 1024)) ;;
        *G) number="${q%G}"; echo $((number * 1000 * 1000 * 1000 / 1024)) ;;
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
# memory is returned (MEMORY_RULE=maximum); as soon as one node has no such
# prefix or an empty providerID the sum is returned (MEMORY_RULE=sum), as
# before. Known limit, documented: k3d and minikube in Docker mode share a VM
# too but are not kind, they stay on the sum. A line without the separator
# carries the memory alone, so it is a node without providerID (sum).
memory_cluster_ki() {
    local output line providerID memory node total=0 max=0 n=0 all_kind=1
    MEMORY_KI=""
    MEMORY_RULE=""
    output="$(account_admin "$(account_context)" get nodes \
        -o jsonpath='{range .items[*]}{.spec.providerID}{"|"}{.status.allocatable.memory}{"\n"}{end}' 2>/dev/null)" || return 1
    [ -n "$output" ] || return 1
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in
            *'|'*)
                providerID="${line%%|*}"
                memory="${line#*|}"
                ;;
            *)
                providerID=""
                memory="$line"
                ;;
        esac
        node="$(quantity_ki "$memory")"
        total=$((total + node))
        if [ "$node" -gt "$max" ]; then max="$node"; fi
        case "$providerID" in
            kind://*) ;;
            *) all_kind=0 ;;
        esac
        n=$((n + 1))
    done <<<"$output"
    if [ "$n" -gt 0 ] && [ "$all_kind" -eq 1 ]; then
        MEMORY_RULE="maximum"
        MEMORY_KI="$max"
    else
        MEMORY_RULE="sum"
        MEMORY_KI="$total"
    fi
    echo "$MEMORY_KI"
}

# Refuses the installation of <module> under <minimum_gi> GiB of allocatable
# memory. The message says the minimum, the available memory and how to enlarge
# the cluster; [hint] adds an optional hint (for example --preset light).
# On a kind cluster (#612) the available memory is the one of a single node
# and the message says so. Return 0 when the memory is enough, 2 when it is
# not or the cluster is unreachable.
check_module_memory() {
    local module_name="$1" minimum_gi="$2" hint="${3:-}" memory precision=""
    if ! memory_cluster_ki >/dev/null; then
        echo "devzone : ${module_name} : services cluster unreachable: devzone cluster" >&2
        return 2
    fi
    memory="$MEMORY_KI"
    if [ "$MEMORY_RULE" = "maximum" ]; then
        precision=" (memory of a single node: kind cluster, shared VM)"
    fi
    if [ "$memory" -lt "$((minimum_gi * 1048576))" ]; then
        echo "devzone : ${module_name} : at least ${minimum_gi} GiB of allocatable memory is needed in the cluster (available: $((memory / 1048576)) GiB)${precision} ; enlarge the cluster (Docker Desktop → Settings → Resources) then retry: devzone enable ${module_name}${hint:+ ; hint: ${hint}}" >&2
        return 2
    fi
    return 0
}
