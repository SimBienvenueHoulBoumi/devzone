#!/usr/bin/env bash
# Identité git, à chaque démarrage tant qu'elle manque : déduite du compte gh
# (propre à chaque utilisateur, connexion gardée dans son volume) et écrite dans
# ~/.config/git/config (volume devzone-git, survit aux rebuilds).
# Une identité déjà définie (à la main, ou recopiée par VS Code dans
# ~/.gitconfig) n'est jamais remplacée. Email noreply de GitHub : les commits
# sont rattachés au compte sans exposer l'email personnel.
set -euo pipefail

CONFIG="$HOME/.config/git/config"
nom_git="$(git config --get user.name || true)"
email_git="$(git config --get user.email || true)"

[ -n "$nom_git" ] && [ -n "$email_git" ] && exit 0

if ! gh auth status >/dev/null 2>&1; then
    echo "git-identite : identité git absente (nécessaire pour commiter) : avec GitHub, gh auth login -s workflow puis bash .devcontainer/git-identite.sh ; sans GitHub, git config --file ~/.config/git/config user.name \"<nom>\" et user.email \"<email>\""
    exit 0
fi

id="" login="" nom=""
IFS=$'\t' read -r id login nom < <(gh api user --jq '[.id, .login, (.name // "")] | @tsv' 2>/dev/null || true)
if [ -z "$id" ] || [ -z "$login" ]; then
    echo "git-identite : compte GitHub illisible (réseau ?) ; relancer : bash .devcontainer/git-identite.sh"
    exit 0
fi

[ -n "$nom_git" ] || git config --file "$CONFIG" user.name "${nom:-$login}"
[ -n "$email_git" ] || git config --file "$CONFIG" user.email "${id}+${login}@users.noreply.github.com"
echo "git-identite : $(git config --get user.name) <$(git config --get user.email)>"
