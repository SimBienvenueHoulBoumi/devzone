#!/usr/bin/env bash
# Port relays of the workstation (#290): applications reachable from
# 127.0.0.1 of the workstation, kept in the state of devzone.
#   ports.sh list            relays of the state: port, active, application
#   ports.sh close <n>       removes the relay and the port from the state
#   ports.sh resume          one-line summary for the devzone recap
# The state is the line "ports=8080,3000" of DEVZONE_STATE (sorted, no duplicate).
# ROOT: a single dirname from HERE (.devcontainer) = root of the devzone repository.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then set -euo pipefail; fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${DEVZONE_ROOT:-$(dirname "$HERE")}"
ETAT="${DEVZONE_STATE:-$ROOT/.devzone.modules}"
INSTANCE="${DEVZONE_INSTANCE:-devzone}"

# Safe state write (#417): lock, temporary file in the state folder, backup copy

refuse() { echo "devzone : port : $*" >&2; exit 1; }

# Application labels: the list shows them in English. The JSON output keeps its
# French values (read by the tools, #557): a contract, UTF-8 written as byte escapes.
APP_RESPONDS="application responds"
APP_NONE="no application"
# shellcheck disable=SC2034 # read by ports-json.sh (sourced)
JSON_APP_RESPONDS=$'application r\303\251pond'
# shellcheck disable=SC2034 # read by ports-json.sh (sourced)
JSON_APP_NONE="aucune application"

relay_name() { echo "devzone-$INSTANCE-port-$1"; }

port_valid() { case "${1:-}" in '' | *[!0-9]*) return 1 ;; esac; [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null; }

validate_port() { port_valid "${1:-}" || refuse "invalid port : ${1:-(none)} (1-65535)"; }

read_ports() { grep -E '^ports=' "$ETAT" 2>/dev/null | tail -1 | cut -d= -f2- || true; }

sort_ports() {
    printf '%s\n' "${1:-}" | tr ',' '\n' | awk 'NF && $0 ~ /^[0-9]+$/ { print }' | sort -n -u | paste -sd, -
}

# Writes the ports= line of the state (#417: never mv outside Go state command)
write_ports() {
    DEVZONE_STATE="$ETAT" bash "$HERE/devzone" state write ports "${1:-}" || { echo "devzone : port : state not saved : $ETAT" >&2; exit 1; }
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

relay_active() {
    local name
    name="$(relay_name "$1")"
    command -v docker >/dev/null 2>&1 || return 1
    [ -n "$(docker ps --filter "name=^$name$" --format '{{.Names}}' 2>/dev/null |
        grep -Fx "$name" || true)" ]
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
        echo "no relay"
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
}

summary() {
    local ports port output=""
    ports="$(sort_ports "$(read_ports)")"
    if [ -z "$ports" ]; then
        echo "none"
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

# Machine-readable output of list: a JSON array [{port,active,application,auto}], jq only.
# shellcheck source=SCRIPTDIR/ports-json.sh
# shellcheck disable=SC1091
. "$HERE/ports-json.sh"
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
case "${1:-}" in
    '' | list)
        if [ "${2:-}" = "--json" ]; then list_json; else list_ports; fi
        ;;
    close | --close) close_port "${2:-}" ;;
    resume) summary ;;
    -h | --help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
fi
