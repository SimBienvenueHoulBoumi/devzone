#!/usr/bin/env bash
# Étapes qui ne peuvent pas être dans l'image (Dockerfile) :
# - volumes montés au démarrage seulement
# - npm fourni par la feature node, ajoutée après le Dockerfile
set -euo pipefail

# Volumes nommés créés en root → rendre au user vscode
# (et ~/.config, créé par Docker pour monter ~/.config/opencode)
sudo chown -R vscode:vscode /home/vscode/.m2 /home/vscode/.local /home/vscode/.claude \
    /home/vscode/.config/opencode
sudo chown vscode:vscode /home/vscode/.config

# repowarden, version figée (il installe des hooks git globaux) ; mettre à jour
# en changeant la version ici, puis Rebuild Container
npm install -g repowarden@4.7.1
repowarden install --global --lang fr

# Assistants IA en ligne de commande, versions figées ; mettre à jour en
# changeant la version ici, puis Rebuild Container (connexion conservée :
# volumes de devcontainer.json)
npm install -g @anthropic-ai/claude-code@2.1.286 opencode-ai@1.18.34

echo "devzone prêt : java $(java -version 2>&1 | head -1 | cut -d'"' -f2), node $(node -v), python $(python3 --version | cut -d' ' -f2), repowarden $(repowarden --version), claude $(claude --version | cut -d' ' -f1), opencode $(opencode --version)"
