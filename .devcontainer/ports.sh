#!/usr/bin/env bash
# Port relays (#290): applications of the devzone container reachable from
# 127.0.0.1 of the workstation, one alpine/socat container per port.
#   ports.sh open <n>       opens the relay of port <n>
#   ports.sh list            relays of the state: port, active, application
#   ports.sh close <n>       removes the relay and the port from the state
#   ports.sh restart         recreates the relays of the state toward the current IP
#   ports.sh resume          one-line summary for the devzone recap
# The state is the line "ports=8080,3000" of DEVZONE_ETAT (sorted, no duplicate).
# ROOT: a single dirname from HERE (.devcontainer) = root of the devzone repository.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then set -euo pipefail; fi

SOCAT_IMAGE=alpine/socat:1.8.0.3

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${DEVZONE_RACINE:-$(dirname "$HERE")}"
ETAT="${DEVZONE_ETAT:-$ROOT/.devzone.modules}"
INSTANCE="${DEVZONE_INSTANCE:-devzone}"

# Safe state write (#417): lock, temporary file in the state folder, backup copy
# shellcheck source=SCRIPTDIR/state.sh
# shellcheck disable=SC1091
. "$HERE/state.sh"

refuse() { echo "devzone : port : $*" >&2; exit 1; }

# Application labels: the list shows them in English. The JSON output keeps its
# French values (read by the tools, #557): a contract, UTF-8 written as byte escapes.
APP_RESPONDS="application responds"
APP_NONE="no application"
JSON_APP_RESPONDS=$'application r\303\251pond'
JSON_APP_NONE="aucune application"

relay_name() { echo "devzone-$INSTANCE-port-$1"; }

port_valid() { case "${1:-}" in '' | *[!0-9]*) return 1 ;; esac; [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null; }

validate_port() { port_valid "${1:-}" || refuse "invalid port : ${1:-(none)} (1-65535)"; }

read_ports() { grep -E '^ports=' "$ETAT" 2>/dev/null | tail -1 | cut -d= -f2- || true; }

sort_ports() {
    printf '%s\n' "${1:-}" | tr ',' '\n' | awk 'NF && $0 ~ /^[0-9]+$/ { print }' | sort -n -u | paste -sd, -
}

# Writes the ports= line of the state (#417: never mv outside state.sh)
write_ports() {
    state_write ports "${1:-}" || { echo "devzone : port : state not saved : $ETAT" >&2; exit 1; }
}

add_port() {
    local port="$1"
    write_ports "$(sort_ports "$(read_ports),$port")"
}

remove_port() {
    local port="$1" rest="" p
    # shellcheck disable=SC2046 # list of ports separated by commas
    for p in $(printf '%s' "$(read_ports)" | tr ',' ' '); do
        [ "$p" = "$port" ] || rest="$rest${rest:+,}$p"
    done
    write_ports "$(sort_ports "$rest")"
}

# Network and address of the devzone container, read on the host's Docker: the
# relay runs there and must reach the container by its IP.
network_ip() {
    local line
    command -v docker >/dev/null 2>&1 || return 1
    line="$(docker inspect "$(hostname)" \
        --format '{{range $nom, $r := .NetworkSettings.Networks}}{{$nom}} {{$r.IPAddress}}{{"\n"}}{{end}}' 2>/dev/null |
        awk 'NF >= 2 && $2 != "" { print; exit }')" || return 1
    [ -n "$line" ] || return 1
    NETWORK="${line%% *}"
    IP="${line#* }"
    [ -n "$NETWORK" ] && [ -n "$IP" ]
}

relay_exists() {
    local name
    name="$(relay_name "$1")"
    command -v docker >/dev/null 2>&1 || return 1
    [ -n "$(docker ps -a --filter "name=^$name$" --format '{{.Names}}' 2>/dev/null |
        grep -Fx "$name" || true)" ]
}

relay_active() {
    local name
    name="$(relay_name "$1")"
    command -v docker >/dev/null 2>&1 || return 1
    [ -n "$(docker ps --filter "name=^$name$" --format '{{.Names}}' 2>/dev/null |
        grep -Fx "$name" || true)" ]
}

# Launches the relay; on failure, a clear message and code 1 (this function does
# not change the state)
launch() {
    local port="$1" network="$2" ip="$3" name output
    name="$(relay_name "$port")"
    if output="$(docker run -d --restart unless-stopped \
        --name "$name" \
        --label "devzone.instance=$INSTANCE" \
        --label "devzone.port=$port" \
        --network "$network" \
        -p "127.0.0.1:$port:$port" \
        "$SOCAT_IMAGE" \
        "tcp-listen:$port,fork,reuseaddr" "tcp-connect:$ip:$port" 2>&1)"; then
        return 0
    fi
    case "$output" in
        *"port is already allocated"* | *"address already in use"*)
            echo "devzone : port : port already in use on the workstation : $port" >&2
            ;;
        *)
            echo "devzone : port : relay on port $port failed : $output" >&2
            ;;
    esac
    return 1
}

open_port() {
    local port="${1:-}"
    validate_port "$port"
    if relay_active "$port"; then
        add_port "$port"
        echo "✔ relay already open: 127.0.0.1:$port on the workstation → $port in the container"
        return 0
    fi
    network_ip || refuse "devzone container not found: host Docker unreachable?"
    docker rm -f "$(relay_name "$port")" >/dev/null 2>&1 || true
    launch "$port" "$NETWORK" "$IP" || exit 1
    add_port "$port"
    echo "✔ 127.0.0.1:$port on the workstation → $port in the container (relay $(relay_name "$port"))"
}

close_port() {
    local port="${1:-}"
    validate_port "$port"
    docker rm -f "$(relay_name "$port")" >/dev/null 2>&1 || true
    remove_port "$port"
    echo "✔ relay closed: $port"
}

app_responds() { curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$1" >/dev/null 2>&1; }

list_ports() {
    local ports port mark app
    ports="$(sort_ports "$(read_ports)")"
    if [ -z "$ports" ]; then
        echo "no relay (devzone port <n>)"
        return 0
    fi
    # shellcheck disable=SC2046 # list of ports separated by commas
    for port in $(printf '%s' "$ports" | tr ',' ' '); do
        if relay_active "$port"; then
            mark="● active"
        else
            mark="○ stopped"
        fi
        if app_responds "$port"; then
            app="$APP_RESPONDS"
        else
            app="$APP_NONE"
        fi
        printf '  %-5s %s  %s\n' "$port" "$mark" "$app"
    done
    bash "$HERE/ports-auto.sh" list_auto 2>/dev/null || true
}

summary() {
    local ports port output=""
    ports="$(sort_ports "$(read_ports)")"
    if [ -z "$ports" ]; then
        echo "none (devzone port <n>)"
        return 0
    fi
    # shellcheck disable=SC2046 # list of ports separated by commas
    for port in $(printf '%s' "$ports" | tr ',' ' '); do
        if relay_active "$port"; then
            output="$output${output:+, }$port ●"
        else
            output="$output${output:+, }$port ○"
        fi
    done
    echo "$output"
}

restart_relays() {
    local ports port rc=0
    ports="$(sort_ports "$(read_ports)")"
    [ -n "$ports" ] || return 0
    if ! network_ip; then
        echo "devzone : port : relays not restarted: devzone container not found (host Docker unreachable?)" >&2
        return 1
    fi
    # shellcheck disable=SC2046 # list of ports separated by commas
    for port in $(printf '%s' "$ports" | tr ',' ' '); do
        if ! port_valid "$port"; then
            echo "devzone : port : invalid port in the state, ignored: $port" >&2
            rc=1
            continue
        fi
        # The container IP changes at each start: the relay is recreated
        docker rm -f "$(relay_name "$port")" >/dev/null 2>&1 || true
        launch "$port" "$NETWORK" "$IP" || rc=1
    done
    return "$rc"
}

# Machine-readable output of list: a JSON array [{port,actif,application,auto}], jq only.
# shellcheck source=SCRIPTDIR/ports-json.sh
# shellcheck disable=SC1091
. "$HERE/ports-json.sh"
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
case "${1:-}" in
    '' | list)
        if [ "${2:-}" = "--json" ]; then list_json; else list_ports; fi
        ;;
    open) open_port "${2:-}" ;;
    close | --close) close_port "${2:-}" ;;
    restart) restart_relays ;;
    resume) summary ;;
    auto) bash "$HERE/ports-auto.sh" auto "${2:-}" "${3:-}" ;;
    exclude) bash "$HERE/ports-auto.sh" exclude "${2:-}" ;;
    include) bash "$HERE/ports-auto.sh" include "${2:-}" ;;
    -h | --help | aide) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) open_port "$1" ;;
esac
fi
