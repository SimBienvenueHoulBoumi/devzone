#!/usr/bin/env bash
# Applications and services of the Kubernetes workspace on workstation localhost (#401).
# Sourced by manage/workspace.sh (ports_* functions); run directly with "loop" or
# "round", it is the workstation watcher: only one, mkdir lock and pid in
# .devzone.ports-workspace/. It relays with kubectl port-forward, on 127.0.0.1
# only, TCP ports >= 1024 listening in the pod, and devzone services of active
# modules in .devzone.modules. Guard: never under bats without
# DEVZONE_PORTS_WORKSPACE_REEL=oui.

PW_POD="devzone-workspace-0"
PW_NS="devzone-workspace"
# Internal pod ports, never relayed: kubedock and buildkit.
PW_INTERNAL=" 2475 1234 "
# pgAdmin service port: read from the service, without it nothing is relayed.
PW_JSONPATH='jsonpath={.spec.ports[0].port}'

# Watcher state folder: lock, pid, relays, reported ports, log.
pw_dir() { printf '%s' "${DEVZONE_PORTS_WORKSPACE_DIR:-$PWD/.devzone.ports-workspace}"; }

# kubectl context flag: devzone if it exists, otherwise current context.
pw_ctx() {
    if kubectl config get-contexts -o name 2>/dev/null | grep -qx 'devzone'; then
        printf -- '--context devzone'
    fi
}

# Watcher kubectl: devzone context if it exists, then given arguments.
pw_kubectl() {
    # shellcheck disable=SC2046
    kubectl $(pw_ctx) "$@"
}

# Guard: refuse under bats without DEVZONE_PORTS_WORKSPACE_REEL=oui (message if $1 empty).
pw_guard() {
    if [ -n "${BATS_TEST_TMPDIR:-}" ] && [ "${DEVZONE_PORTS_WORKSPACE_REEL:-}" != oui ]; then
        [ -n "${1:-}" ] || echo "✖ port watcher refused under bats (DEVZONE_PORTS_WORKSPACE_REEL=oui required)" >&2
        return 2
    fi
}

# Is process $1 alive?
pw_alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

# TCP ports >= 1024 listening in the pod (ss -ltnH), excluding internal ports, one per line.
pw_pod_ports() {
    local p
    pw_kubectl --namespace "$PW_NS" exec "$PW_POD" -c workspace -- ss -ltnH 2>/dev/null |
        awk '{n=split($4,a,":"); print a[n]}' | sort -un | while read -r p; do
        case "$p" in '' | *[!0-9]*) continue ;; esac
        [ "$p" -ge 1024 ] || continue
        case "$PW_INTERNAL" in *" $p "*) continue ;; esac
        echo "$p"
    done
}

# devzone services to relay, one "port|namespace|target" line per active module service:
# postgres (5432) and pgAdmin if present in namespace, mysql (3306).
pw_services() {
    if grep -qxE 'postgres=(on|true|oui)' .devzone.modules 2>/dev/null; then
        echo "5432|devzone-postgres|svc/postgres"
        local port
        port="$(pw_kubectl --namespace devzone-postgres get svc pgadmin -o "$PW_JSONPATH" 2>/dev/null || true)"
        case "$port" in '' | *[!0-9]*) ;; *) echo "$port|devzone-postgres|svc/pgadmin" ;; esac
    fi
    if grep -qxE 'mysql=(on|true|oui)' .devzone.modules 2>/dev/null; then
        echo "3306|devzone-mysql|svc/mysql"
    fi
}

# Is port $1 already in use on the workstation? (lsof, otherwise nc -z)
pw_taken() {
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
    else
        nc -z 127.0.0.1 "$1" >/dev/null 2>&1
    fi
}

# Starts relay of port $1 to target $3 in namespace $2, unless already alive;
# port taken on workstation: only one warning line per port.
pw_relay() {
    local port="$1" ns="$2" target="$3" d pid
    d="$(pw_dir)"
    pid="$(cat "$d/relais/$port" 2>/dev/null || true)"
    pw_alive "$pid" && return 0
    if pw_taken "$port"; then
        [ -e "$d/pris/$port" ] || { : >"$d/pris/$port"; echo "⚠ port $port already in use on the workstation, not relayed"; }
        return 0
    fi
    # shellcheck disable=SC2046
    kubectl $(pw_ctx) --namespace "$ns" port-forward --address 127.0.0.1 "$target" "$port:$port" </dev/null >/dev/null 2>&1 &
    echo $! >"$d/relais/$port"
    rm -f "$d/pris/$port"
    echo "→ port $port relayed on 127.0.0.1"
}

# Stops relay of port $1 and forgets its warning.
pw_remove() {
    local d pid
    d="$(pw_dir)"
    pid="$(cat "$d/relais/$1" 2>/dev/null || true)"
    if pw_alive "$pid"; then kill "$pid" 2>/dev/null || true; fi
    rm -f "$d/relais/$1" "$d/pris/$1"
}

# One watcher round: relay new ports, remove those that disappeared.
pw_round() {
    local d wanted="" p ns target l f
    d="$(pw_dir)"
    mkdir -p "$d/relais" "$d/pris"
    while IFS='|' read -r p ns target; do
        [ -n "$p" ] || continue
        wanted="$wanted $p "
        pw_relay "$p" "$ns" "$target"
    done <<<"$(pw_services)"
    for p in $(pw_pod_ports); do
        case "$wanted" in *" $p "*) continue ;; esac
        wanted="$wanted $p "
        pw_relay "$p" "$PW_NS" "pod/$PW_POD"
    done
    for f in "$d"/relais/* "$d"/pris/*; do
        [ -e "$f" ] || continue
        l="$(basename "$f")"
        case "$wanted" in *" $l "*) ;; *) pw_remove "$l" ;; esac
    done
}

# Removes all relays from the state folder.
pw_remove_all() {
    local f
    for f in "$(pw_dir)"/relais/*; do
        if [ -e "$f" ]; then pw_remove "$(basename "$f")"; fi
    done
}

# Watcher loop: one round every 3 s; on stop, removes its relays and lock.
pw_loop() {
    local d
    d="$(pw_dir)"
    trap 'pw_remove_all; rm -rf "$d/verrou" "$d/pid"; exit 0' TERM INT
    while :; do
        pw_round || true
        sleep "${DEVZONE_PORTS_WORKSPACE_PAS:-3}" &
        wait $!
    done
}

# Starts the watcher, only one: mkdir lock, pid recorded; $1=silence: no guard message.
# shellcheck disable=SC2120
ports_start() {
    pw_guard "${1:-}" || return 0
    local d pid
    d="$(pw_dir)"
    mkdir -p "$d"
    pid="$(cat "$d/pid" 2>/dev/null || true)"
    if pw_alive "$pid"; then
        echo "Workspace ports: watcher already running (pid $pid)"
        return 0
    fi
    rm -rf "$d/verrou"
    mkdir "$d/verrou" 2>/dev/null || return 0
    nohup bash "${BASH_SOURCE[0]}" loop >>"$d/journal.log" 2>&1 &
    echo $! >"$d/pid"
    disown 2>/dev/null || true
    echo "Workspace ports: watcher started, log $d/journal.log"
}

# Stops the watcher and all its port-forwards; without watcher, removes leftovers.
ports_stop() {
    local d pid
    d="$(pw_dir)"
    pid="$(cat "$d/pid" 2>/dev/null || true)"
    if pw_alive "$pid"; then
        kill "$pid" 2>/dev/null || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do pw_alive "$pid" || break; sleep 0.2; done
    fi
    pw_remove_all
    rm -rf "$d/verrou" "$d/pid"
}

# Shows status: watcher, relayed ports, reported taken ports.
ports_status() {
    local d pid f
    d="$(pw_dir)"
    pid="$(cat "$d/pid" 2>/dev/null || true)"
    if pw_alive "$pid"; then echo "Port watcher: running (pid $pid)"; else echo "Port watcher: stopped"; fi
    for f in "$d"/relais/*; do
        if [ -e "$f" ] && pw_alive "$(cat "$f")"; then echo "  127.0.0.1:$(basename "$f") relayed"; fi
    done
    for f in "$d"/pris/*; do
        if [ -e "$f" ]; then echo "  ⚠ port $(basename "$f") already in use on the workstation, not relayed"; fi
    done
    return 0
}

# Subcommand "devzone workspace ports [start|stop|status]" (default: status).
ports() {
    case "${1:-status}" in
        start | demarrer) ports_start ;;
        stop | arreter) ports_stop ;;
        status | etat) ports_status ;;
        *) echo "✖ devzone workspace ports start|stop|status" >&2; return 1 ;;
    esac
}

# compatibility aliases, removed with lot 4 (#509)
ports_demarrer() { ports_start "$@"; }
ports_arreter() { ports_stop "$@"; }
ports_etat() { ports_status "$@"; }

# Run directly: watcher loop, or a single round (tests).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    pw_guard quiet || exit 2
    case "${1:-}" in
        loop | boucle) pw_loop ;;
        round | tour) pw_round ;;
    esac
fi
