#!/usr/bin/env bash
# Étapes qui ne peuvent pas être dans l'image (Dockerfile) :
# - volumes montés au démarrage seulement
# - npm fourni par la feature node, ajoutée après le Dockerfile
set -euo pipefail

# Volumes nommés créés en root → rendre au user vscode
# (et ~/.config, créé par Docker pour monter ~/.config/opencode)
sudo chown -R vscode:vscode /home/vscode/.m2 /home/vscode/.local /home/vscode/.claude \
    /home/vscode/.config/opencode /home/vscode/.config/gh /home/vscode/.config/git \
    /home/vscode/.config/devzone
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

# Modules facultatifs (assistants IA, Kubernetes) : commande devzone, état
# gardé dans le volume devzone-config ; installe ce qui est actif
sudo ln -sf /workspaces/devzone/.devcontainer/devzone /usr/local/bin/devzone
devzone appliquer

# Ce qui reste à faire (identité git, GitHub, modules) : récapitulatif de
# devzone, affiché à chaque démarrage (demarrage.sh)

recap="java $(java -version 2>&1 | head -1 | cut -d'"' -f2), node $(node -v), python $(python3 --version | cut -d' ' -f2), repowarden $(repowarden --version)"
! command -v claude >/dev/null || recap+=", claude $(claude --version | cut -d' ' -f1)"
! command -v opencode >/dev/null || recap+=", opencode $(opencode --version)"
echo "devzone prêt : $recap"
