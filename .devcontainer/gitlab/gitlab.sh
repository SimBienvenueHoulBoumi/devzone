#!/usr/bin/env bash
# GitLab module: test GitLab in the services cluster (#396).
# To enable it: devzone enable gitlab
# To disable it: devzone disable gitlab
# set -euo pipefail so that nothing fails silently.
set -euo pipefail

# Root of the devzone repository (two levels above the module); DEVZONE_RACINE for the tests
ICI="$(cd "$(dirname "$0")" && pwd)"
RACINE="${DEVZONE_RACINE:-$(dirname "$(dirname "$ICI")")}"
# shellcheck source=SCRIPTDIR/../cluster.sh
. "$ICI/../cluster.sh"
# shellcheck source=SCRIPTDIR/../password.sh
# shellcheck disable=SC1091
. "$ICI/../password.sh"
# Network isolation: namespace_isolate, set with the devzone-gitlab namespace
# shellcheck source=SCRIPTDIR/../isolation.sh
# shellcheck disable=SC1091
. "$ICI/../isolation.sh"

# ---- Delay variables (seconds) ----
# GITLAB_ATTENTE: global wait for the installation (default 1200)
GITLAB_ATTENTE="${GITLAB_ATTENTE:-1200}"

# ---- Secret paths ----
# Secrets stored in $RACINE/workspace/.gitlab/ (chmod 600), never shown.
GITLAB_SECRETS_DIR="$RACINE/workspace/.gitlab"

# Grouped view of the credentials: a failure never prevents the operation
regenerer_identifiants() {
    password_regenerate ||
        echo "devzone : gitlab : grouped credentials not updated (devzone passwords)" >&2
}

# ---- /etc/hosts of the container ----
# DEVZONE_HOSTS for the tests (never the real /etc/hosts)
HOSTS="${DEVZONE_HOSTS:-/etc/hosts}"
GITLAB_HOST_MARK="# devzone:gitlab"

# GitLab Rails secret (#347): kept in workspace/.gitlab, applied again
# before helm upgrade --install, and the password can be regenerated
# shellcheck source=SCRIPTDIR/secrets.sh
# shellcheck disable=SC1091
. "$ICI/secrets.sh"

# ---- Installation, migration and relay of the services cluster ----
# New logic outside this file (#396): devzone-gitlab namespace,
# allocatable memory, Helm with the devzone context, migration from kind-gitlab.
# shellcheck source=SCRIPTDIR/installation.sh
# shellcheck disable=SC1091
. "$ICI/installation.sh"
# Wrapper chart (direct helm, chart.sh), Argo CD (argocd.sh), seed (seed.sh) (#538)
# shellcheck source=SCRIPTDIR/chart.sh
# shellcheck disable=SC1091
. "$ICI/chart.sh"
# shellcheck source=SCRIPTDIR/argocd.sh
# shellcheck disable=SC1091
. "$ICI/argocd.sh"
# shellcheck source=SCRIPTDIR/seed.sh
# shellcheck disable=SC1091
. "$ICI/seed.sh"

# ---- host-set / host-remove: gitlab.localhost in /etc/hosts ----
# Why: ssh (clone ssh://git@gitlab.localhost:2224/…), glab and getent go through
# the system resolver. curl and git (libcurl) ignore /etc/hosts for the
# *.localhost names (RFC 6761) and go through the TCP relay above, which
# listens on 127.0.0.1. The name therefore points to 127.0.0.1 so that ssh and
# glab take the same path. /etc/hosts is a Docker mount that Docker regenerates
# when the container starts, hence the set again at each start (startup.sh) and
# at each activation. Never sed -i nor mv: the mount cannot be renamed (in-place
# write only); direct if the file is writable, otherwise sudo -n. A failure never
# fails: a warning on stderr and exit code 0, so that the installation does not
# fail for a host name.
gitlab_host_set() {
    local line tmp
    line="$(printf '127.0.0.1\tgitlab.localhost %s' "$GITLAB_HOST_MARK")"
    # Already the right line, once: nothing (idempotent)
    if [ "$(grep -c "$GITLAB_HOST_MARK" "$HOSTS" 2>/dev/null || true)" = 1 ] &&
        grep -qxF "$line" "$HOSTS" 2>/dev/null; then
        return 0
    fi
    if grep -q "$GITLAB_HOST_MARK" "$HOSTS" 2>/dev/null; then
        # Line marked with another address (IPv6 of #320) or duplicate:
        # it is replaced by the right one, keeping the rest of the file.
        tmp="$(mktemp)"
        grep -v "$GITLAB_HOST_MARK" "$HOSTS" >"$tmp" 2>/dev/null || true
        printf '%s\n' "$line" >>"$tmp"
        if [ -w "$HOSTS" ]; then
            cp "$tmp" "$HOSTS" 2>/dev/null ||
                echo "devzone : gitlab : gitlab.localhost name not set in $HOSTS (insufficient write rights)" >&2
        elif ! sudo -n cp "$tmp" "$HOSTS" >/dev/null 2>&1; then
            echo "devzone : gitlab : gitlab.localhost name not set in $HOSTS (sudo -n unavailable or refused)" >&2
        fi
        rm -f "$tmp"
        return 0
    fi
    if [ -w "$HOSTS" ]; then
        printf '%s\n' "$line" >>"$HOSTS" 2>/dev/null ||
            echo "devzone : gitlab : gitlab.localhost name not set in $HOSTS (insufficient write rights)" >&2
    elif ! printf '%s\n' "$line" | sudo -n tee -a "$HOSTS" >/dev/null 2>&1; then
        echo "devzone : gitlab : gitlab.localhost name not set in $HOSTS (sudo -n unavailable or refused)" >&2
    fi
    return 0
}

gitlab_host_remove() {
    # No line found: nothing (including an unreadable file)
    if ! grep -q "$GITLAB_HOST_MARK" "$HOSTS" 2>/dev/null; then
        return 0
    fi
    local tmp
    tmp="$(mktemp)"
    grep -v "$GITLAB_HOST_MARK" "$HOSTS" >"$tmp" 2>/dev/null || true
    if [ -w "$HOSTS" ]; then
        cp "$tmp" "$HOSTS" 2>/dev/null ||
            echo "devzone : gitlab : gitlab.localhost line not removed from $HOSTS (insufficient write rights)" >&2
    elif ! sudo -n cp "$tmp" "$HOSTS" >/dev/null 2>&1; then
        echo "devzone : gitlab : gitlab.localhost line not removed from $HOSTS (sudo -n unavailable or refused)" >&2
    fi
    rm -f "$tmp"
    return 0
}

# ---- status: check the state of GitLab ----
gitlab_status() {
    # Disabled if the devzone-gitlab namespace does not exist
    if ! gitlab_installed; then
        echo "désactivé"
        return 0
    fi

    # Check that GitLab answers the readiness probe
    if curl -sf http://gitlab.localhost:8929/-/readiness >/dev/null 2>&1 || curl -sf http://gitlab.localhost:8929/users/sign_in >/dev/null 2>&1; then
        # Check whether the runner is online or offline
        local runner_status="hors ligne"
        if [ -f "$GITLAB_SECRETS_DIR/root-token" ]; then
            local token count
            token="$(cat "$GITLAB_SECRETS_DIR/root-token")"
            count="$(curl -s --header "PRIVATE-TOKEN: $token" "http://gitlab.localhost:8929/api/v4/runners/all?status=online" 2>/dev/null | jq -r 'length' 2>/dev/null || true)"
            if [ "${count:-0}" -gt 0 ] 2>/dev/null; then
                runner_status="en ligne"
            fi
        fi
        echo "prêt : http://gitlab.localhost:8929, runner ${runner_status}"
    else
        echo "en échec : devzone apply"
    fi
    return 0
}

# Subcommand dispatch
case "${1:-}" in
    install)    gitlab_install ;;
    uninstall) gitlab_uninstall "${@:2}" ;;
    migrate)       shift; gitlab_migrate "$@" ;;
    installe)     gitlab_installed ;;
    status)         gitlab_status ;;
    seed)         gitlab_seed_command ;;
    new-password)  gitlab_new_password "${@:2}" ;;
    relay-start) gitlab_relay_start ;;
    relay-stop) gitlab_relay_stop ;;
    relay-status)  gitlab_relay_status ;;
    hote-poser)   gitlab_host_set ;;
    hote-retirer) gitlab_host_remove ;;
    *)            echo "devzone : unknown command : ${1:-} (devzone gitlab --help)" >&2
                  exit 1
                  ;;
esac
