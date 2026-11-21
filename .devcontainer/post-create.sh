#!/usr/bin/env bash
# Steps that cannot be in the image (Dockerfile):
# - volumes mounted at startup only
# - npm provided by the node feature, added after the Dockerfile
set -euo pipefail
# Never a question: the devcontainer CLI runs this step under a terminal, output
# sent to .devzone.log by make, so invisible; a question (repowarden install
# proposes « repowarden bots » in a GitHub repository whose gh is administrator)
# would wait forever. Empty input: each tool switches to non-interactive mode
# (bots: « later, repowarden bots »)
exec </dev/null

# Named volumes created as root → give back to the vscode user
# (and ~/.config, created by Docker to mount ~/.config/opencode)
sudo chown -R vscode:vscode /home/vscode/.m2 /home/vscode/.gradle /home/vscode/.local /home/vscode/.claude \
    /home/vscode/.config/opencode /home/vscode/.config/gh /home/vscode/.config/git \
    /home/vscode/.config/devzone /home/vscode/.local/state/oc-lancer
sudo chown vscode:vscode /home/vscode/.config

# Git: the container's repositories declared safe (their owner may differ from
# the user running git: volumes, Docker Desktop, tools run separately), and
# GitHub access by the gh token, kept in its volume (https, even for the
# git@github.com: remotes, without an ssh key to copy)
# Machine settings in the container's ~/.gitconfig (recreated at each rebuild):
# without this file, git config --global (and repowarden install) would write
# into ~/.config/git/config, the identity volume, where they would pile up from
# one rebuild to the next
touch "$HOME/.gitconfig"
# Volume touched by a previous version: only these settings are removed from it,
# the identity and any other setting are kept
volume="$HOME/.config/git/config"
if [ -f "$volume" ]; then
    remove() { git config --file "$volume" --unset-all "$@" 2>/dev/null || true; }
    remove safe.directory '^/workspaces/devzone'
    remove credential.https://github.com.helper
    remove url.https://github.com/.insteadOf
    remove core.hooksPath 'repowarden'
    remove alias.cc 'repowarden'
    remove repowarden.lang
fi
git config --global --add safe.directory /workspaces/devzone
git config --global --add safe.directory '/workspaces/devzone/workspace/*'
git config --global --replace-all credential.https://github.com.helper ''
git config --global --add credential.https://github.com.helper '!gh auth git-credential'
git config --global url.https://github.com/.insteadOf git@github.com:

# repowarden, pinned version (it installs global git hooks); update
# .devcontainer/versions.env, then Rebuild Container
echo "devzone : installing repowarden…"
# shellcheck source=SCRIPTDIR/versions.env
. "$(dirname "${BASH_SOURCE[0]}")/versions.env"
npm install -g "repowarden@$REPOWARDEN_VERSION"
repowarden install --global --lang fr

# Optional modules (AI assistants, Kubernetes): devzone command, state kept in
# the instance folder ($RACINE/.devzone.modules); installs what is enabled. A
# failing module does not stop the creation: the container stays usable and the
# state (devzone, at each startup) shows it as « in failure »
sudo ln -sf /workspaces/devzone/.devcontainer/devzone /usr/local/bin/devzone
# Access to the workstation cluster (hote.config) before the modules that depend
# on it (#370); a failure does not stop the creation, the startup runs it again
bash /workspaces/devzone/.devcontainer/kube-config.sh || echo "devzone : kube configuration incomplete, retry: devzone start" >&2
# Former names (state key ia=) renamed before the first read of the state (#774)
bash /workspaces/devzone/.devcontainer/rename-legacy-files.sh || echo "devzone : legacy names not renamed, retry: devzone repair" >&2
devzone apply || echo "devzone : modules incomplete (details above), retry: devzone apply" >&2
# Guarded system packages (#351): reinstalled at each creation; a failure does not stop the creation
devzone packages apply || echo "devzone : packages failed, retry: devzone packages" >&2

# Kubernetes prompt of the shell (#337): prefixes PS1, only once. The check also
# accepts the block written before the rename to kube-prompt.sh (invite-kube.sh)
if grep -qE 'invite-kube\.sh|devzone_invite_kube' "$HOME/.bashrc" 2>/dev/null; then
    sed -i -e 's#/\.devcontainer/invite-kube\.sh#/.devcontainer/kube-prompt.sh#' \
        -e 's#devzone_invite_kube#devzone_kube_prompt#' "$HOME/.bashrc"
fi
if ! grep -qE 'kube-prompt.sh|invite-kube.sh' "$HOME/.bashrc" 2>/dev/null; then
    cat >>"$HOME/.bashrc" <<'PROMPT'
# >>> devzone invite >>>
# shellcheck source=/dev/null
. /workspaces/devzone/.devcontainer/kube-prompt.sh
PS1='$(devzone_kube_prompt) '"$PS1"
# <<< devzone invite <<<
PROMPT
fi

# What remains to be done (git identity, GitHub, modules): devzone summary,
# displayed at each startup (startup.sh)

recap="java $(java -version 2>&1 | head -1 | cut -d'"' -f2), node $(node -v), python $(python3 --version | cut -d' ' -f2), repowarden $(repowarden --version)"
! command -v claude >/dev/null || recap+=", claude $(claude --version | cut -d' ' -f1)"
! command -v opencode >/dev/null || recap+=", opencode $(opencode --version)"
echo "devzone up : $recap"
