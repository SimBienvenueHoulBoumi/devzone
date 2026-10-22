#!/usr/bin/env bash
# Étapes qui ne peuvent pas être dans l'image (Dockerfile) :
# - volumes montés au démarrage seulement
# - npm fourni par la feature node, ajoutée après le Dockerfile
set -euo pipefail
# Jamais de question : le CLI devcontainer lance cette étape sous terminal,
# sortie envoyée dans .devzone.log par make, donc invisible ; une question
# (repowarden install propose « repowarden bots » dans un dépôt GitHub dont
# gh est administrateur) attendrait indéfiniment. Entrée vide : chaque outil
# passe en mode non interactif (bots : « plus tard, repowarden bots »)
exec </dev/null

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
# Réglages de la machine dans ~/.gitconfig du conteneur (recréé à chaque
# rebuild) : sans ce fichier, git config --global (et repowarden install)
# écriraient dans ~/.config/git/config, le volume de l'identité, où ils
# s'accumuleraient d'un rebuild à l'autre
touch "$HOME/.gitconfig"
# Volume touché par une version antérieure : seuls ces réglages en sont
# retirés, l'identité et tout autre réglage sont conservés
volume="$HOME/.config/git/config"
if [ -f "$volume" ]; then
    retirer() { git config --file "$volume" --unset-all "$@" 2>/dev/null || true; }
    retirer safe.directory '^/workspaces/devzone'
    retirer credential.https://github.com.helper
    retirer url.https://github.com/.insteadOf
    retirer core.hooksPath 'repowarden'
    retirer alias.cc 'repowarden'
    retirer repowarden.lang
fi
git config --global --add safe.directory /workspaces/devzone
git config --global --add safe.directory '/workspaces/devzone/workspace/*'
git config --global --replace-all credential.https://github.com.helper ''
git config --global --add credential.https://github.com.helper '!gh auth git-credential'
git config --global url.https://github.com/.insteadOf git@github.com:

# repowarden, version figée (il installe des hooks git globaux) ; mettre à jour
# en changeant la version ici, puis Rebuild Container
npm install -g repowarden@4.11.1
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
