#!/usr/bin/env bash
# Docker socket relay (#293), run first by startup.sh.
#
# Why: the docker-outside-of-docker feature relays the host socket through
# « socat UNIX-LISTEN:/var/run/docker.sock,… UNIX-CONNECT:… » without the -t
# option (only under Docker Desktop, socket at gid 0; under Linux it goes
# through a group, without socat). As soon as the client closes its side (a
# « docker exec » without standard input), socat cuts the connection 0.5 s
# later: the output is truncated and docker exec still returns 0. kind runs
# kubeadm init this way, and believes it succeeded after 0.5 s (kind cluster and
# gitlab module impossible from devzone). The same socat with -t 86400 lets the
# daemon's answer through until it closes itself.
#
# What the script does: the feature's relay without -t is replaced by the same
# with -t 86400 (feature PID file updated, so docker-init.sh does not restart
# it); then a check that a long docker exec goes to the end. Without a socat
# relay (Linux), only the check is done. Idempotent.
#
# Safe by construction: paths and commands are adjustable (tests: everything
# under a temporary folder), and refusal to touch the real socket without
# DEVZONE_RELAIS_REEL=oui, which only startup.sh and devzone repair set.
# Code: 0 check succeeded, 1 check failed (mark written for the devzone
# summary), 2 refusal by the guard. Compatible with bash 3.2.
set -euo pipefail

SOCKET="${DEVZONE_RELAIS_SOCKET:-/var/run/docker.sock}"
SOURCE="${DEVZONE_RELAIS_SOURCE:-/var/run/docker-host.sock}"
# Feature files (/usr/local/share/docker-init.sh: SOCAT_PID, SOCAT_LOG)
PID_FILE="${DEVZONE_RELAIS_PID:-/tmp/vscr-docker-from-docker.pid}"
JOURNAL="${DEVZONE_RELAIS_LOG:-/tmp/vscr-docker-from-docker.log}"
RELAY_USER="${DEVZONE_RELAIS_UTILISATEUR:-vscode}"
DOCKER="${DEVZONE_RELAIS_DOCKER:-docker}"
# Failure mark read by the devzone summary (.devcontainer/devzone): specific to
# the container, erased at each restart with /tmp
MARK="${DEVZONE_RELAIS_MARQUE:-/tmp/devzone-relais-docker.echec}"
WAIT="${DEVZONE_RELAIS_ATTENTE:-10}"
# The feature's relay runs as root: sudo unless already root
if [ -n "${DEVZONE_RELAIS_SUDO+x}" ]; then
    SUDO="$DEVZONE_RELAIS_SUDO"
elif [ "$(id -u)" = 0 ]; then
    SUDO=""
else
    SUDO=sudo
fi

if [ -n "${BATS_TEST_TMPDIR:-}" ] && [ "$SOCKET" = /var/run/docker.sock ]; then
    echo "docker-relay : refused under bats (tests)" >&2
    exit 2
fi

if [ "$SOCKET" = /var/run/docker.sock ] && [ "${DEVZONE_RELAIS_REEL:-}" != oui ]; then
    echo "docker-relay : refused to touch the real socket ($SOCKET): run devzone repair instead" >&2
    exit 2
fi

# No socket (docker-hote=off option, #432): nothing to relay or check.
# Exit 0 so as not to hinder the startup; docker goes back to the workspace.
if [ ! -e "$SOCKET" ]; then
    rm -f "$MARK" 2>/dev/null || true
    echo "docker-relay : no host Docker socket (option docker-hote=off)"
    exit 0
fi

# $SUDO empty: command run by env, never as a builtin (kill is a bash builtin:
# env goes through PATH, like sudo; the tests put their fake tools there)
as_root() {
    if [ -n "$SUDO" ]; then
        "$SUDO" "$@"
    else
        env "$@"
    fi
}

fail() {
    echo "docker-relay : $1" >&2
    printf '%s\n' "$1" >"$MARK" 2>/dev/null || true
    exit 1
}

# « <pid> <a_t> » of the socat listening on $SOCKET (a_t: 1 if it has -t), nothing
# otherwise. Only the socat process itself counts (not a parent « sudo socat »),
# and only if it listens on this socket.
relay_find() {
    local pid args
    while read -r pid args; do
        case "$args" in
            "socat "*) ;;
            *) continue ;;
        esac
        case "$args" in
            *"UNIX-LISTEN:$SOCKET,"* | *"UNIX-LISTEN:$SOCKET "* | *"UNIX-LISTEN:$SOCKET") ;;
            *) continue ;;
        esac
        case " $args " in
            *" -t "*) echo "$pid 1" ;;
            *) echo "$pid 0" ;;
        esac
        return 0
    done < <(ps -eo pid=,args=)
}

replace() {
    local old="$1" new_pid i
    as_root kill "$old" 2>/dev/null || true
    i=0
    while [ "$i" -lt 20 ] && as_root kill -0 "$old" 2>/dev/null; do
        sleep 0.1
        i=$((i + 1))
    done
    as_root rm -f "$SOCKET"
    # setsid -f: socat detached, it survives the end of the startup; -lf: its
    # log (root file) is opened by socat itself
    as_root setsid -f socat -t 86400 -lf "$JOURNAL" \
        "UNIX-LISTEN:$SOCKET,fork,mode=660,user=$RELAY_USER,backlog=128" \
        "UNIX-CONNECT:$SOURCE" </dev/null >/dev/null 2>&1 ||
        fail "relay not restarted (socat -t 86400)"
    # PID of the new socat in the feature's file: docker-init.sh sees it alive
    # and does not restart the old relay
    i=0
    new_pid=""
    while [ "$i" -lt 20 ]; do
        new_pid="$(relay_find || true)"
        [ -n "$new_pid" ] && break
        sleep 0.1
        i=$((i + 1))
    done
    [ -n "$new_pid" ] || fail "restarted relay not found (ps)"
    printf '%s\n' "${new_pid%% *}" | as_root tee "$PID_FILE" >/dev/null
    echo "✔ Docker relay : socat -t 86400 (long docker exec not cut)"
}

found="$(relay_find || true)"
if [ -n "$found" ] && [ "${found##* }" = 0 ]; then
    replace "${found%% *}"
fi

i=0
until "$DOCKER" version >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -lt "$WAIT" ] || fail "the socket $SOCKET does not answer"
    sleep 1
done

# Check: 1 s exceeds the 0.5 s of socat without -t; « ok » proves that the
# output of a docker exec without standard input arrives in full
output="$("$DOCKER" exec "$(hostname)" sh -c 'sleep 1; echo ok' </dev/null 2>&1 || true)"
[ "$output" = ok ] || fail "long docker exec cut (output: ${output:-empty})"
rm -f "$MARK" 2>/dev/null || true
