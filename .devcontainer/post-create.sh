#!/usr/bin/env bash
# Étapes qui ne peuvent pas être dans l'image (Dockerfile) :
# - volumes montés au démarrage seulement
# - npm fourni par la feature node, ajoutée après le Dockerfile
set -euo pipefail

# Volumes nommés créés en root → rendre au user vscode
# (et ~/.config, créé par Docker pour monter ~/.config/opencode)
sudo chown -R vscode:vscode /home/vscode/.m2 /home/vscode/.local /home/vscode/.claude \
    /home/vscode/.config/opencode /home/vscode/.config/gh /home/vscode/.config/git
sudo chown vscode:vscode /home/vscode/.config

# Git : dépôts du conteneur déclarés sûrs (leur propriétaire peut différer de
# l'utilisateur qui lance git : volumes, Docker Desktop, outils lancés à part),
# et accès à GitHub par le jeton de gh, conservé dans son volume (https, même
# pour les remotes en git@github.com:, sans clé ssh à recopier)
git config --global --add safe.directory /workspaces/devzone
git config --global --add safe.directory '/workspaces/devzone/workspace/*'
git config --global credential.https://github.com.helper ''
git config --global --add credential.https://github.com.helper '!gh auth git-credential'
git config --global url.https://github.com/.insteadOf git@github.com:

# repowarden, version figée (il installe des hooks git globaux) ; mettre à jour
# en changeant la version ici, puis Rebuild Container
npm install -g repowarden@4.8.3
repowarden install --global --lang fr

# Assistants IA en ligne de commande, versions figées ; mettre à jour en
# changeant la version ici, puis Rebuild Container (connexion conservée :
# volumes de devcontainer.json)
npm install -g @anthropic-ai/claude-code@2.1.286 opencode-ai@1.18.34

# Identité git : déduite du compte gh au démarrage (git-identite.sh)
gh auth status >/dev/null 2>&1 || echo "GitHub à connecter une fois : gh auth login (donne aussi l'identité git)"

echo "devzone prêt : java $(java -version 2>&1 | head -1 | cut -d'"' -f2), node $(node -v), python $(python3 --version | cut -d' ' -f2), repowarden $(repowarden --version), claude $(claude --version | cut -d' ' -f1), opencode $(opencode --version)"
