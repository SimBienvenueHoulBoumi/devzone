#!/usr/bin/env bash
# Git identity, at each startup as long as it is missing: deduced from the gh
# account (specific to each user, connection kept in their volume) and written
# into ~/.config/git/config (devzone-git volume, survives rebuilds).
# An identity already set (by hand, or copied by VS Code into ~/.gitconfig) is
# never replaced. GitHub noreply email: commits are attached to the account
# without exposing the personal email.
set -euo pipefail

CONFIG="$HOME/.config/git/config"
name_git="$(git config --get user.name || true)"
email_git="$(git config --get user.email || true)"

[ -n "$name_git" ] && [ -n "$email_git" ] && exit 0

# Without gh: nothing to deduce; the devzone summary reports it
gh auth status >/dev/null 2>&1 || exit 0

id="" login="" name=""
IFS=$'\t' read -r id login name < <(gh api user --jq '[.id, .login, (.name // "")] | @tsv' 2>/dev/null || true)
if [ -z "$id" ] || [ -z "$login" ]; then
    echo "git-identity : GitHub account unreadable (network?); run again: bash .devcontainer/git-identity.sh"
    exit 0
fi

[ -n "$name_git" ] || git config --file "$CONFIG" user.name "${name:-$login}"
[ -n "$email_git" ] || git config --file "$CONFIG" user.email "${id}+${login}@users.noreply.github.com"
echo "git-identity : $(git config --get user.name) <$(git config --get user.email)>"
