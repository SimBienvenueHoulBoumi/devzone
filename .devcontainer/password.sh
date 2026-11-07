#!/usr/bin/env bash
# Identifiants regroupés des comptes créés par devzone (#332).
#   password.sh regenerer   lit les fichiers des modules, écrit $RACINE/.password
#   password.sh chemin      affiche le chemin de $RACINE/.password
# Les fichiers des modules restent la source : .password est une vue régénérée.
# Secrets en clair : jamais affichés, jamais commités (.gitignore), droits 600.
set -euo pipefail

PASSWORD_ICI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASSWORD_RACINE="${DEVZONE_RACINE:-$(dirname "$PASSWORD_ICI")}"
PASSWORD_CIBLE="$PASSWORD_RACINE/.password"

# Régénère $RACINE/.password à partir de workspace/.gitlab et
# workspace/.postgres. Silencieux en cas de succès ; sans aucun compte, le
# fichier est supprimé.
password_regenerer() (
    umask 077
    local cible="$PASSWORD_CIBLE" racine="$PASSWORD_RACINE"
    local gl="$racine/workspace/.gitlab" pg="$racine/workspace/.postgres"
    local ar="$racine/workspace/.argocd"
    local tab entrees tmp fichier nom service adresse utilisateur mdp
    tab="$(printf '\t')"
    entrees="$(mktemp "$racine/.password.entrees.XXXXXX")" || return 1
    tmp=""

    if [ -s "$gl/root-password" ]; then
        mdp="$(cat "$gl/root-password")"
        if [ -n "$mdp" ]; then
            printf 'gitlab\t%s\troot\t%s\n' "http://gitlab.localhost:8929" "$mdp" >>"$entrees"
        fi
    fi
    if [ -s "$gl/dev-password" ]; then
        mdp="$(cat "$gl/dev-password")"
        if [ -n "$mdp" ]; then
            printf 'gitlab\t%s\tdev\t%s\n' "http://gitlab.localhost:8929" "$mdp" >>"$entrees"
        fi
    fi
    if [ -s "$pg/admin-password" ]; then
        mdp="$(cat "$pg/admin-password")"
        if [ -n "$mdp" ]; then
            printf 'postgres\t%s\tpostgres\t%s\n' "127.0.0.1:5432" "$mdp" >>"$entrees"
        fi
    fi
    if [ -s "$ar/admin.env" ]; then
        utilisateur="$(sed -n 's/^ARGOCD_USER=//p' "$ar/admin.env" 2>/dev/null | tail -1 || true)"
        mdp="$(sed -n 's/^ARGOCD_PASSWORD=//p' "$ar/admin.env" 2>/dev/null | tail -1 || true)"
        if [ -n "$utilisateur" ] && [ -n "$mdp" ]; then
            printf 'argocd\t%s\t%s\t%s\n' "https://127.0.0.1:8443" "$utilisateur" "$mdp" >>"$entrees"
        fi
    fi
    for fichier in "$pg"/*.env; do
        [ -f "$fichier" ] || continue
        nom="${fichier##*/}"
        nom="${nom%.env}"
        service="postgres:$nom"
        utilisateur="$(sed -n 's/^DB_USER=//p' "$fichier" 2>/dev/null | tail -1 || true)"
        mdp="$(sed -n 's/^DB_PASSWORD=//p' "$fichier" 2>/dev/null | tail -1 || true)"
        adresse="$(sed -n 's/^DB_NAME=//p' "$fichier" 2>/dev/null | tail -1 || true)"
        if [ -z "$utilisateur" ] || [ -z "$mdp" ]; then
            continue
        fi
        adresse="127.0.0.1:5432/${adresse:-$nom}"
        printf '%s\t%s\t%s\t%s\n' "$service" "$adresse" "$utilisateur" "$mdp" >>"$entrees"
    done

    if [ ! -s "$entrees" ]; then
        rm -f "$entrees" "$cible"
        return 0
    fi

    tmp="$(mktemp "$racine/.password.XXXXXX")" || {
        rm -f "$entrees"
        return 1
    }
    {
        printf '%s\n' \
            '# devzone : identifiants des comptes créés par devzone. Secrets en clair :' \
            '# ne jamais commiter, copier ni coller dans un ticket. Régénéré par devzone.' \
            "# service${tab}adresse${tab}utilisateur${tab}mot de passe"
        LC_ALL=C sort -t "$tab" -k1,1 -k3,3 "$entrees"
    } >"$tmp" || {
        rm -f "$entrees" "$tmp"
        return 1
    }
    chmod 600 "$tmp" || {
        rm -f "$entrees" "$tmp"
        return 1
    }
    mv "$tmp" "$cible" || {
        rm -f "$entrees" "$tmp"
        return 1
    }
    chmod 600 "$cible" || {
        rm -f "$entrees"
        return 1
    }
    rm -f "$entrees"
)

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        regenerer) password_regenerer ;;
        chemin) printf '%s\n' "$PASSWORD_CIBLE" ;;
        *)
            echo "devzone : password.sh : regenerer | chemin" >&2
            exit 1
            ;;
    esac
fi
