#!/usr/bin/env bash
# Applications of the Kubernetes workspace relayed on workstation localhost (#611).
# Sourced by ports-workspace.sh, never run alone. One kubectl get svc -A per
# round: each TCP port of each Service gets a local port, kept stable in
# .devzone.ports-workspace/apps/<namespace>.<service>.<port> while the Service
# exists. Only Services with a ready endpoint are relayed (#638): the others keep
# their local port and show as "no ready pod" in status. Output lines:
# "portlocal|namespace|svc/name|remoteport", as pw_services.

PA_MAX=30
# Namespaces never relayed: system ones, and those of the devzone modules
# (relayed by pw_services, or without any interface).
PA_NS_SKIP=" kube-system kube-public kube-node-lease local-path-storage devzone-system devzone-workspace devzone-postgres devzone-mysql devzone-argocd devzone-gitlab devzone-llm "

# Services of the cluster, one "namespace|name|clusterIP|type|relay annotation|port/proto," line each.
pa_discover() {
    pw_kubectl get svc -A -o 'jsonpath={range .items[*]}{.metadata.namespace}|{.metadata.name}|{.spec.clusterIP}|{.spec.type}|{.metadata.annotations.devzone\.io/relay}|{range .spec.ports[*]}{.port}/{.protocol},{end}{"\n"}{end}' 2>/dev/null
}

# Services with a ready endpoint, as " namespace/name " items, from one kubectl get
# endpointslices call. A Service with several slices is ready if one of its slices has
# a ready endpoint. Exit 1 if the call fails: the caller then relays every Service.
pa_ready() {
    local out ns name conds set=" "
    out="$(pw_kubectl get endpointslices -A -o 'jsonpath={range .items[*]}{.metadata.namespace}|{.metadata.labels.kubernetes\.io/service-name}|{range .endpoints[*]}{.conditions.ready},{end}{"\n"}{end}' 2>/dev/null)" || return 1
    while IFS='|' read -r ns name conds; do
        [ -n "$ns" ] || continue
        [ -n "$name" ] || continue
        case "$conds" in *true*) set="$set$ns/$name " ;; esac
    done <<<"$out"
    echo "$set"
}

# Is the Service excluded? $1 namespace, $2 name, $3 clusterIP, $4 type, $5 relay annotation.
pa_excluded() {
    case "$PA_NS_SKIP" in *" $1 "*) return 0 ;; esac
    [ "$1/$2" != default/kubernetes ] || return 0
    [ "$5" != false ] || return 0
    case "$4" in ExternalName) return 0 ;; esac
    case "$3" in '' | None) return 0 ;; esac
    return 1
}

# Is local port $1 free for an application? Not in the list "$2" (" p p "), not taken on the workstation.
pa_free() {
    case "$2" in *" $1 "*) return 1 ;; esac
    ! pw_taken "$1"
}

# First free local port for Service port $1, given the ports in use "$2": the port itself
# when >= 1024, else $1 + 8000 (80 -> 8080), then incrementing; past 65000, from 20000.
pa_new() {
    local c=$(($1 + 8000)) i=0
    if [ "$1" -ge 1024 ] && pa_free "$1" "$2"; then
        echo "$1"
        return 0
    fi
    [ "$c" -le 65000 ] || c=20000
    while [ "$i" -lt 60000 ]; do
        if pa_free "$c" "$2"; then
            echo "$c"
            return 0
        fi
        c=$((c + 1))
        i=$((i + 1))
        [ "$c" -le 65000 ] || c=20000
    done
    return 1
}

# One round of applications, from the ports already wanted "$1" (services, pod).
# Prints the relay lines; writes apps/ (stable local port), plafond/ (cap marker) and
# no-ready-pod/ (Service without ready endpoint, not relayed nor counted), removes the
# state of Services gone, warns once per port over the cap of PA_MAX.
pa_round() {
    local d used excl ns name ip type annot ports pp port key stored loc n=0 seen="" f
    local ready="" ready_ok=1 unready
    d="$(pw_dir)"
    mkdir -p "$d/apps" "$d/plafond"
    excl="$(grep -E '^ports_exclus=' .devzone.modules 2>/dev/null | tail -1 | cut -d= -f2- | tr ',' ' ')"
    used=" $1 $excl "
    # One kubectl call per round. If it fails, every Service is relayed, warned once.
    if ready="$(pa_ready)"; then
        rm -f "$d/endpoints-unreadable"
    else
        ready_ok=0
        if [ ! -e "$d/endpoints-unreadable" ]; then
            : >"$d/endpoints-unreadable"
            echo "⚠ endpointslices unreadable, ready pods not checked" >&2
        fi
    fi
    while IFS='|' read -r ns name ip type annot ports; do
        [ -n "$ns" ] || continue
        pa_excluded "$ns" "$name" "$ip" "$type" "$annot" && continue
        for pp in ${ports//,/ }; do
            case "$pp" in */TCP) ;; *) continue ;; esac
            port="${pp%/*}"
            case "$port" in '' | *[!0-9]*) continue ;; esac
            key="$ns.$name.$port"
            seen="$seen $key "
            stored="$(cat "$d/apps/$key" 2>/dev/null || true)"
            loc=""
            case "$stored" in '' | *[!0-9]*) ;; *) case "$used" in *" $stored "*) ;; *) loc="$stored" ;; esac ;; esac
            if [ -z "$loc" ]; then
                loc="$(pa_new "$port" "$used")" || { echo "⚠ no free local port for $ns/$name:$port" >&2; continue; }
            fi
            used="$used $loc "
            [ "$loc" = "$stored" ] || printf '%s' "$loc" >"$d/apps/$key"
            unready=0
            if [ "$ready_ok" -eq 1 ]; then
                case "$ready" in *" $ns/$name "*) ;; *) unready=1 ;; esac
            fi
            if [ "$unready" -eq 1 ]; then
                mkdir -p "$d/no-ready-pod"
                : >"$d/no-ready-pod/$key"
                continue
            fi
            rm -f "$d/no-ready-pod/$key"
            if [ "$n" -lt "$PA_MAX" ]; then
                n=$((n + 1))
                rm -f "$d/plafond/$key"
                echo "$loc|$ns|svc/$name|$port"
            elif [ ! -e "$d/plafond/$key" ]; then
                : >"$d/plafond/$key"
                echo "⚠ cap of $PA_MAX application relays reached, $ns/$name:$port not relayed" >&2
            fi
        done
    done <<<"$(pa_discover)"
    for f in "$d"/apps/* "$d"/plafond/* "$d"/no-ready-pod/*; do
        [ -e "$f" ] || continue
        case "$seen" in *" $(basename "$f") "*) ;; *) rm -f "$f" ;; esac
    done
}

# Status lines of relayed applications: local URL, then namespace/service:port.
# Then the Services without ready pod, with the local URL they would get.
pa_status() {
    local d f key rest loc
    d="$(pw_dir)"
    for f in "$d"/apps/*; do
        [ -e "$f" ] || continue
        loc="$(cat "$f")"
        pw_alive "$(cat "$d/relais/$loc" 2>/dev/null)" || continue
        key="$(basename "$f")"
        rest="${key#*.}"
        echo "  http://127.0.0.1:$loc  ${key%%.*}/${rest%%.*}:${rest#*.}"
    done
    for f in "$d"/no-ready-pod/*; do
        [ -e "$f" ] || continue
        key="$(basename "$f")"
        loc="$(cat "$d/apps/$key" 2>/dev/null || true)"
        [ -n "$loc" ] || continue
        rest="${key#*.}"
        echo "  http://127.0.0.1:$loc  ${key%%.*}/${rest%%.*}:${rest#*.}  no ready pod"
    done
}
