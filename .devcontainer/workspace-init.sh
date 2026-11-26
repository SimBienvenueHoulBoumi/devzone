#!/usr/bin/env bash
# Why: this script installs the devzone tools in the workspace pod (#503).
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
    elif npm install -g "repowarden@${REPOWARDEN_VERSION:-}" 2>&1; then
        log "repowarden ${REPOWARDEN_VERSION:-} installed"
    else
        log "repowarden: npm install failed"
    fi
    if repowarden install --global --lang fr 2>&1; then
        log "repowarden global hooks installed"
    else
        log "repowarden: install --global failed"
    fi
}

init_modules() {
    if devzone apply 2>&1; then
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
    # Blocks written before the Go prompt sourced a shell library that no longer
    # exists: drop them, the new block below takes over (migration, idempotent)
    if grep -qE 'invite-kube\.sh|kube-prompt\.sh' "$bashrc" 2>/dev/null; then
        sed -i -e '/invite-kube\.sh/d' -e '/kube-prompt\.sh/d' \
            -e '/devzone_invite_kube/d' -e '/devzone_kube_prompt/d' "$bashrc"
        log "prompt block migrated to the Go command"
    fi
    if grep -qF "$PROMPT_START" "$bashrc" 2>/dev/null; then
        log "prompt block already present"
        return 0
    fi
    cat >>"$bashrc" <<'PROMPT'
# >>> devzone prompt >>>
PS1='$(devzone kube prompt) '"$PS1"
# <<< devzone prompt <<<
PROMPT
    log "prompt block added to $bashrc"
}

init_safe_directory
init_repowarden
init_modules
init_prompt
log "done"
