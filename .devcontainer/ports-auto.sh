#!/usr/bin/env bash
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ports.sh
# shellcheck disable=SC1091
. "$HERE/ports.sh"
PORTS_AUTO_DIR="${DEVZONE_PORTS_AUTO_DIR:-/tmp/devzone-ports-auto}"
BASE="$PORTS_AUTO_DIR/${INSTANCE:-devzone}"
BRIDGES="$BASE/bridges"
# State file names on disk (verrou, occupes, actifs, courant) are kept: tests and the watcher use them
LOCK="$BASE/verrou"; BUSY="$BASE/occupes"; ACTIVE="$BASE/actifs"
PENDING="$BASE/pending"; CURRENT="$BASE/courant"
JSON_APP_BUSY=$'occup\303\251 sur le poste' # JSON value, contract (see ports.sh)
mkdir -p "$BASE" "$BRIDGES"

# Automatic watcher state: off as soon as ports_auto= is off (« non » kept as a stored value)
auto_enabled() { local v; v="$(grep -E '^ports_auto=' "$ETAT" 2>/dev/null | tail -1 | cut -d= -f2- || true)"; case "$v" in off|false|0|non|no) echo off ;; *) echo on ;; esac; }
# List of the ports excluded by the user (ports_exclus=, comma-separated)
excluded_read() { grep -E '^ports_exclus=' "$ETAT" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
# Writes a key=value line in the state, like write_ports does for ports=
write_key() { state_write "$1" "${2:-}" || { echo "devzone : port : state not saved : $ETAT" >&2; return 1; }; }
# A port is excluded when it is listed in ports_exclus=.
port_excluded() { case ",$(excluded_read)," in *",$1,"*) return 0 ;; esac; return 1; }
# Name of the automatic relay of a port: devzone-<instance>-auto-<port>.
auto_relay_name() { echo "devzone-$INSTANCE-auto-$1"; }
# Is the automatic relay of <port> already alive on the host's Docker?
auto_relay_active() { local name; name="$(auto_relay_name "$1")"; command -v docker >/dev/null 2>&1 || return 1; [ -n "$(docker ps --filter "name=^$name$" --format '{{.Names}}' 2>/dev/null | grep -Fx "$name" || true)" ]; }
# Delay after a port disappears before removing its bridge and relay.
disappearance_delay() { local v; for v in DEVZONE_PORTS_AUTO_DISAPPEARANCE_DELAY DEVZONE_PORTS_AUTO_DELAY DEVZONE_PORTS_AUTO_LATE PORTS_AUTO_DELAI PORTS_AUTO_RETARD; do [ -n "${!v:-}" ] && { echo "${!v}"; return 0; }; done; echo 10; }

# Guard: the loop and demarrer never run under bats,
# and outside the container only if the real context is set.
guard_watcher() {
    if [ -n "${BATS_TEST_TMPDIR:-}" ]; then
        echo "devzone : port : automatic watcher refused under bats (tests)" >&2
        return 2
    fi
    [ "${DEVZONE_PORTS_AUTO_REAL:-}" = yes ] && return 0
    echo "devzone : port : automatic watcher refused here: run devzone repair instead" >&2
    return 2
}

# Launches the automatic relay; on failure, a message and code 1 (busy port marked).
launch_auto() {
    local port="$1" network="$2" ip="$3" name output
    name="$(auto_relay_name "$port")"
    if output="$(docker run -d --restart unless-stopped --name "$name" --label "devzone.instance=$INSTANCE" --label "devzone.port=$port" --label "devzone.auto=true" --network "$network" -p "127.0.0.1:$port:$port" "$SOCAT_IMAGE" "tcp-listen:$port,fork,reuseaddr" "tcp-connect:$ip:$port" 2>&1)"; then return 0; fi
    case "$output" in *"port is already allocated"*|*"address already in use"*) echo "devzone : port : port already in use on the workstation : $port" >&2 ;; *) echo "devzone : port : relay on port $port failed : $output" >&2 ;; esac
    return 1
}
# Starts the internal bridge: socat on the container IP, toward the 127.0.0.1 of the port.
start_bridge() { local port="$1" ip="$2"; local pidfile="$BRIDGES/$port.pid"; if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then return 0; fi; socat "TCP-LISTEN:$port,bind=$ip,fork,reuseaddr" "TCP:127.0.0.1:$port" >/dev/null 2>&1 & echo "$!" >"$pidfile"; }
# Stops the internal bridge (pid in $BRIDGES).
stop_bridge() { local port="$1"; local pidfile="$BRIDGES/$port.pid"; local pid; if [ -f "$pidfile" ]; then pid="$(cat "$pidfile" 2>/dev/null || true)"; if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi; wait "$pid" 2>/dev/null || true; rm -f "$pidfile"; fi; }
# Removes the automatic relay and its bridge.
close_auto() { local port="$1"; docker rm -f "$(auto_relay_name "$port")" >/dev/null 2>&1 || true; stop_bridge "$port"; }

# Removes all the automatic relays and their bridges, then empties the states.
clean_auto_all() {
    local port; [ -f "$ACTIVE" ] && while IFS= read -r port; do [ -n "$port" ] && close_auto "$port"; done <"$ACTIVE"
    [ -f "$BUSY" ] && while IFS= read -r port; do [ -n "$port" ] && stop_bridge "$port"; done <"$BUSY"
    : >"$ACTIVE" 2>/dev/null || true; : >"$BUSY" 2>/dev/null || true; : >"$PENDING" 2>/dev/null || true; rm -f "$BRIDGES"/*.pid 2>/dev/null || true
}
# Removes the automatic relays of a previous session.
clean_previous() { docker ps -a --filter "name=devzone-$INSTANCE-auto-" --format '{{.Names}}' 2>/dev/null | while IFS= read -r name; do case "$name" in devzone-"$INSTANCE"-auto-*) docker rm -f "$name" >/dev/null 2>&1 || true ;; esac; done; rm -f "$BRIDGES"/*.pid 2>/dev/null || true; }

# Exclusive lock (mkdir) with a pid: a single watcher instance.
lock_take() {
    local start now age pid
    start="$(date +%s)"
    while true; do
        if mkdir "$LOCK" 2>/dev/null; then echo "$$" >"$LOCK/pid"; return 0; fi
        now="$(date +%s)"; age=""; [ -d "$LOCK" ] && age="$(stat -c %Y "$LOCK" 2>/dev/null || stat -f %m "$LOCK" 2>/dev/null || true)"
        pid="$(cat "$LOCK/pid" 2>/dev/null || true)"
        if [ -n "$age" ] && [ "$(( now - age ))" -gt 30 ]; then rm -rf "$LOCK"; continue; fi
        if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then rm -rf "$LOCK"; continue; fi
        [ "$(( now - start ))" -ge 5 ] && return 1
        sleep 1
    done
}

# Marks the lock as alive: recent date and pid of the holder up to date,
# otherwise another instance takes the lock as stale.
lock_refresh() { touch "$LOCK" 2>/dev/null || true; echo "$$" >"$LOCK/pid" 2>/dev/null || true; }

# One watcher pass: relays the listening ports, removes the vanished ones.
auto_pass() {
    local port now delay output
    # State restored or rebuilt: nothing for 60 s (#417, step 4)
    state_recovery_wait && return 0
    if [ "$(auto_enabled)" = off ]; then
        # Never uninstall on an unconfirmed state (#417, step 4)
        state_recovery_pending || clean_auto_all
        return 0
    fi
    if ! network_ip; then echo "devzone : ports-auto : devzone container not found" >&2; return 1; fi
    : >"$CURRENT"
    ss -ltnH 2>/dev/null | awk '{ if (NF >= 4) print $4; else if (NF >= 1) print $1 }' | while IFS= read -r listen; do
        [ -n "$listen" ] || continue
        p="${listen##*:}"; a="${listen%:*}"; a="${a#[}"; a="${a%]}"
        case "$p" in ''|*[!0-9]*) continue ;; esac
        [ "$a" = "127.0.0.11" ] && continue
        [ "$p" -lt 1024 ] 2>/dev/null && continue
        case "$p" in 5432|8929|2224) continue ;; esac
        case ",$(read_ports)," in *",$p,"*) continue ;; esac
        port_excluded "$p" && continue
        [ "$a" = "$IP" ] && continue
        printf '%s %s\n' "$a" "$p" >>"$CURRENT"
    done
    awk '{print $2}' "$CURRENT" 2>/dev/null | sort -n -u >"$BASE/actuels"
    awk '$1=="0.0.0.0" || $1=="::" || $1=="*" || $1==":::" {print $2}' "$CURRENT" 2>/dev/null | sort -n -u >"$BASE/allif"
    : >"$BASE/managed"
    [ -f "$ACTIVE" ] && cat "$ACTIVE" >>"$BASE/managed"
    for f in "$BRIDGES"/*.pid; do [ -e "$f" ] || continue; basename "${f%.pid}" >>"$BASE/managed"; done
    [ -f "$BUSY" ] && cat "$BUSY" >>"$BASE/managed"
    sort -n -u "$BASE/managed" -o "$BASE/managed" 2>/dev/null || true

    now="$(date +%s)"; delay="$(disappearance_delay)"
    while IFS= read -r port; do
        [ -n "$port" ] || continue
        grep -qxF "$port" "$BUSY" 2>/dev/null && continue
        grep -qxF "$port" "$ACTIVE" 2>/dev/null && continue
        grep -qxF "$port" "$BASE/allif" || start_bridge "$port" "$IP"
        # shellcheck disable=SC2153
        if output="$(launch_auto "$port" "$NETWORK" "$IP" 2>&1)"; then
            grep -qxF "$port" "$ACTIVE" 2>/dev/null || echo "$port" >>"$ACTIVE"
        else
            printf '%s\n' "$output" >&2
            grep -qxF "$port" "$BASE/allif" || stop_bridge "$port"
            case "$output" in *"already in use"*|*"already allocated"*) echo "$port" >>"$BUSY" ;; esac
        fi
    done <"$BASE/actuels"

    while IFS= read -r port; do
        [ -n "$port" ] || continue
        grep -qxF "$port" "$BASE/actuels" 2>/dev/null && continue
        if grep -qxF "$port" "$BUSY" 2>/dev/null; then
            grep -vxF "$port" "$BUSY" >"$BUSY.tmp" 2>/dev/null || true; mv "$BUSY.tmp" "$BUSY" 2>/dev/null || true
            stop_bridge "$port"; continue
        fi
        if grep -q "^$port " "$PENDING" 2>/dev/null; then
            old="$(grep "^$port " "$PENDING" | head -1 | cut -d' ' -f2)"
            # Nothing is removed on an unconfirmed restored state (#417)
            if state_recovery_pending; then continue; fi
            if [ -n "$old" ] && [ "$(( now - old ))" -ge "$delay" ]; then
                close_auto "$port"
                grep -v "^$port " "$PENDING" >"$PENDING.tmp" 2>/dev/null || true; mv "$PENDING.tmp" "$PENDING" 2>/dev/null || true
                grep -vxF "$port" "$ACTIVE" >"$ACTIVE.tmp" 2>/dev/null || true; mv "$ACTIVE.tmp" "$ACTIVE" 2>/dev/null || true
            fi
        else
            echo "$port $now" >>"$PENDING"
        fi
    done <"$BASE/managed"

    while IFS= read -r port; do
        [ -n "$port" ] || continue
        grep -v "^$port " "$PENDING" >"$PENDING.tmp" 2>/dev/null || true; mv "$PENDING.tmp" "$PENDING" 2>/dev/null || true
    done <"$BASE/actuels"
}

# Stops the watcher and cleans its relays.
stop_watcher() { local pid; pid="$(cat "$LOCK/pid" 2>/dev/null || true)"; if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi; clean_auto_all; rm -rf "$LOCK"; }

# Loop: one pass every DEVZONE_PORTS_AUTO_STEP seconds.
auto_loop() {
    if ! lock_take; then return 0; fi
    clean_previous
    trap 'clean_auto_all; rm -rf "$LOCK"' EXIT INT TERM
    while true; do
        # State restored or rebuilt: nothing for 60 s (#417, step 4)
        if state_recovery_wait; then
            lock_refresh
            sleep "${DEVZONE_PORTS_AUTO_STEP:-2}"
            continue
        fi
        # State folder gone: the container has left, the watcher stops.
        if [ ! -f "$ETAT" ]; then clean_auto_all; break; fi
        lock_refresh
        if [ "$(auto_enabled)" = off ]; then
            # Never uninstall on an unconfirmed state (#417)
            state_recovery_pending || clean_auto_all
            break
        fi
        auto_pass || true
        sleep "${DEVZONE_PORTS_AUTO_STEP:-2}"
    done
}

# Excludes a port from the automatic list (writes ports_exclus=).
auto_exclude() { validate_port "${1:-}"; local current; current="$(excluded_read)"; case ",$current," in *",$1,"*) echo "port $1 already excluded"; return 0 ;; esac; write_key ports_exclus "$(sort_ports "$current,$1")"; echo "✔ port $1 excluded"; }
# Puts a port back in the automatic list (removes it from ports_exclus=).
auto_include() { validate_port "${1:-}"; local current rest p; current="$(excluded_read)"; rest=""; for p in $(printf '%s' "$current" | tr ',' ' '); do [ "$p" = "$1" ] || rest="$rest${rest:+,}$p"; done; write_key ports_exclus "$(sort_ports "$rest")"; echo "✔ port $1 included"; }

# Lists the automatic relays alive (or busy on the workstation).
auto_list() {
    local port mark app
    if [ -f "$ACTIVE" ]; then
        while IFS= read -r port; do
            [ -n "$port" ] || continue
            if grep -qxF "$port" "$BUSY" 2>/dev/null; then printf '  %-5s %s  auto\n' "$port" "busy on the workstation"; continue; fi
            if auto_relay_active "$port"; then mark="● active"; else mark="○ stopped"; fi
            if app_responds "$port"; then app="$APP_RESPONDS"; else app="$APP_NONE"; fi
            printf '  %-5s %s  auto  %s\n' "$port" "$mark" "$app"
        done <"$ACTIVE"
    fi
    if [ -f "$BUSY" ]; then
        while IFS= read -r port; do
            [ -n "$port" ] || continue
            grep -qxF "$port" "$ACTIVE" 2>/dev/null && continue
            printf '  %-5s %s  auto\n' "$port" "busy on the workstation"
        done <"$BUSY"
    fi
}

# Machine output (jq) of the automatic relays.
auto_list_json() {
    local port active app json='[]' ports=""
    [ -f "$ACTIVE" ] && ports="$(cat "$ACTIVE")"
    [ -f "$BUSY" ] && ports="$ports"$'\n'"$(cat "$BUSY")"
    ports="$(printf '%s\n' "$ports" | awk 'NF' | sort -n -u)"
    while IFS= read -r port; do
        [ -n "$port" ] || continue
        if grep -qxF "$port" "$BUSY" 2>/dev/null; then
            json="$(jq -c --argjson port "$port" --arg busy "$JSON_APP_BUSY" '. + [{port:$port,active:false,application:$busy,auto:true}]' <<<"$json")"; continue
        fi
        if auto_relay_active "$port"; then active=true; else active=false; fi
        if app_responds "$port"; then app="$JSON_APP_RESPONDS"; else app="$JSON_APP_NONE"; fi
        json="$(jq -c --argjson port "$port" --argjson active "$active" --arg app "$app" '. + [{port:$port,active:$active,application:$app,auto:true}]' <<<"$json")"
    done <<<"$ports"
    printf '%s\n' "$json"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
case "${1:-}" in
    ''|boucle|loop) if ! guard_watcher; then exit 2; fi; auto_loop ;;
    tour|one|un-tour) auto_pass ;;
    demarrer|start|lancer) if [ "${DEVZONE_WORKSPACE:-}" = kubernetes ]; then echo "ports: Kubernetes workspace, ports go through devzone workspace ports"; exit 0; fi; if ! guard_watcher; then exit 2; fi; if kill -0 "$(cat "$LOCK/pid" 2>/dev/null)" 2>/dev/null; then echo "already running"; else DEVZONE_PORTS_AUTO_REAL=yes bash "$0" boucle >/dev/null 2>&1 & echo "started"; fi ;;
    arreter|stop) stop_watcher; echo "stopped" ;;
    nettoyer|clean) clean_auto_all ;;
    auto) case "${2:-}" in on) write_key ports_auto on; echo "✔ automatic ports enabled" ;; off) write_key ports_auto off; stop_watcher; echo "✔ automatic ports disabled" ;; *) echo "devzone : port : auto on|off" >&2; exit 2 ;; esac ;;
    exclude|exclure) auto_exclude "${2:-}" ;;
    include|inclure) auto_include "${2:-}" ;;
    list_auto) auto_list ;;
    list_json_auto) auto_list_json ;;
    -h|--help|aide) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) echo "devzone : ports-auto : unknown command : ${1:-}" >&2; exit 2 ;;
esac
fi
