#!/usr/bin/env bash
# Why: post-create.sh and demarrage.sh never run in the Kubernetes workspace
# pod (#503). This script installs the devzone tools when the container starts.
# Each step logs one "devzone init:" line, and a failure never stops the next
# step. No Docker socket is used and no kubeconfig is fabricated.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSIONS_ENV="$HERE/versions.env"
PROMPT_START="# >>> devzone prompt >>>"

log() {
    echo "devzone init: $*"
}

init_safe_directory() {
    local current
    current="$(git config --global --get-all safe.directory 2>/dev/null || true)"
    if printf '%s\n' "$current" | grep -qxF '/workspaces/projets/*'; then
        log "safe.directory /workspaces/projets/* already set"
        return 0
    fi
    if git config --global --add safe.directory '/workspaces/projets/*' 2>/dev/null; then
        log "safe.directory /workspaces/projets/* added"
    else
        log "safe.directory: failed"
    fi
}

init_repowarden() {
    local installed
    if [ ! -f "$VERSIONS_ENV" ]; then
        log "repowarden: $VERSIONS_ENV missing"
        return 0
    fi
    # shellcheck source=SCRIPTDIR/versions.env
    . "$VERSIONS_ENV"
    installed="$(repowarden --version 2>/dev/null || true)"
    if [ "$installed" = "${REPOWARDEN_VERSION:-}" ]; then
        log "repowarden $installed already installed"
    elif npm install -g "repowarden@${REPOWARDEN_VERSION:-}" >/dev/null 2>&1; then
        log "repowarden ${REPOWARDEN_VERSION:-} installed"
    else
        log "repowarden: npm install failed"
    fi
    if repowarden install --global --lang fr >/dev/null 2>&1; then
        log "repowarden global hooks installed"
    else
        log "repowarden: install --global failed"
    fi
}

init_modules() {
    if devzone appliquer >/dev/null 2>&1; then
        log "modules applied"
    else
        log "modules incomplete"
    fi
}

init_prompt() {
    local bashrc="$HOME/.bashrc"
    if ! touch "$bashrc" 2>/dev/null; then
        log "prompt: cannot write $bashrc"
        return 0
    fi
    if grep -qF "$PROMPT_START" "$bashrc" 2>/dev/null; then
        log "prompt block already present"
        return 0
    fi
    cat >>"$bashrc" <<'PROMPT'
# >>> devzone prompt >>>
# shellcheck source=/dev/null
. /usr/local/share/devzone/.devcontainer/invite-kube.sh
PS1='$(devzone_invite_kube) '"$PS1"
# <<< devzone prompt <<<
PROMPT
    log "prompt block added to $bashrc"
}

init_safe_directory
init_repowarden
init_modules
init_prompt
log "done"
