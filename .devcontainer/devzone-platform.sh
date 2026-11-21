#!/usr/bin/env bash
# shellcheck shell=bash
# devzone, platform: GitHub or GitLab.
# Sourced by .devcontainer/devzone (split of the 1 600 lines file, #722):
# functions only, shared variables are defined in devzone.


# ---- Plateforme : GitHub (défaut) ou GitLab (#240) ----
# Choix gardé dans le fichier d'état (plateforme=, gitlab_url=), propre à
# chaque instance ; la configuration d'un service n'existe que pendant qu'il
# est choisi (#242) : glab et l'URL disparaissent au retour à github.

# Plateforme courante : github en l'absence de ligne (défaut)
plateforme_lue() {
    local v
    v="$(grep -E '^plateforme=' "$ETAT" 2>/dev/null | tail -1 | cut -d= -f2 || true)"
    [ "$v" = gitlab ] && echo gitlab || echo github
}

# URL de l'instance GitLab, rien si absente
url_gitlab_lue() {
    grep -E '^gitlab_url=' "$ETAT" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Hôte d'une URL, sans son protocole (glab --hostname)
hote_de() {
    echo "$1" | sed -E 's#^[a-z]+://##; s#/$##'
}

# Retire glab et sa configuration (retour à github)
retirer_glab() {
    rm -f "$GLAB"
    rm -rf "$HOME/.config/glab-cli"
}

# Ligne de l'état pour la plateforme : github par défaut, ou l'instance GitLab
# avec son instance connectée (glab) sur la commande de connexion sinon
ligne_plateforme() {
    local url hote
    if [ "$(plateforme_lue)" = gitlab ]; then
        url="$(url_gitlab_lue)"
        hote="$(hote_de "$url")"
        if [ -x "$GLAB" ] && "$GLAB" auth status --hostname "$hote" >/dev/null 2>&1; then
            printf '  ✔ plateforme     gitlab : %s, glab connecté\n' "$url"
        else
            printf '  ⚠ plateforme     gitlab : %s, glab non connecté : glab auth login --hostname %s\n' "$url" "$hote"
        fi
    else
        echo "  ✔ plateforme     github"
    fi
}

# Affichage simple de la plateforme (devzone platform)
resume_plateforme() {
    local url hote
    if [ "$(plateforme_lue)" = gitlab ]; then
        url="$(url_gitlab_lue)"
        hote="$(hote_de "$url")"
        if [ -x "$GLAB" ] && "$GLAB" auth status --hostname "$hote" >/dev/null 2>&1; then
            echo "devzone : plateforme gitlab : $url, glab connecté"
        else
            echo "devzone : plateforme gitlab : $url, glab non connecté : glab auth login --hostname $hote"
        fi
    else
        echo "devzone : plateforme github (défaut)"
    fi
}

# Installe glab (release officielle, somme SHA-256 vérifiée), rien s'il est
# déjà là ; le binaire finit dans ~/.local/bin (retirer_glab l'enlève)
installer_glab() {
    local arch="" somme archive dossier glab_tmp
    if [ -x "$GLAB" ] && "$GLAB" --version >/dev/null 2>&1; then
        return 0
    fi
    case "$(uname -m)" in
        arm64 | aarch64) arch=arm64 somme="$GLAB_SOMME_ARM64" ;;
        *) arch=amd64 somme="$GLAB_SOMME_AMD64" ;;
    esac
    echo "devzone : téléchargement de glab $GLAB_VERSION (somme SHA-256 vérifiée)…"
    archive="$(mktemp)"
    if ! curl -fsSL -o "$archive" "https://gitlab.com/gitlab-org/cli/-/releases/$GLAB_VERSION/downloads/glab_${GLAB_VERSION#v}_linux_${arch}.tar.gz"; then
        rm -f "$archive"
        echo "devzone : téléchargement de glab impossible (release officielle de gitlab.com) ; réessayer : devzone platform gitlab --url URL" >&2
        return 1
    fi
    if [ "$(sha256sum "$archive" | cut -d' ' -f1)" != "$somme" ]; then
        rm -f "$archive"
        echo "devzone : somme SHA-256 de glab inattendue, abandon ; archive refusée" >&2
        return 1
    fi
    dossier="$(mktemp -d)"
    glab_tmp="$dossier/bin/glab"
    if ! tar -xzf "$archive" -C "$dossier" || [ ! -f "$glab_tmp" ]; then
        glab_tmp="$dossier/glab"
    fi
    if [ ! -f "$glab_tmp" ]; then
        rm -rf "$dossier" "$archive"
        echo "devzone : binaire glab absent de l'archive, abandon" >&2
        return 1
    fi
    mkdir -p "$HOME/.local/bin"
    mv "$glab_tmp" "$GLAB"
    chmod +x "$GLAB"
    rm -rf "$dossier" "$archive"
}

# Connexion à l'instance GitLab : instance du module gitlab → jeton root du
# module (protocole http, jamais affiché) ; autre instance → interactive, un
# navigateur demandant le code de connexion. Vérifie : code de sortie de
# l'auth login, puis auth status --hostname ; sans contrôle, pas « connecté ».
connexion_glab() {
    local hote="$1" url="$2" jeton
    if [ "$url" = "$GITLAB_URL_MODULE" ]; then
        if [ ! -f "$RACINE/workspace/.gitlab/root-token" ]; then
            echo "devzone : jeton root du module gitlab introuvable ($RACINE/workspace/.gitlab/root-token) : devzone enable gitlab, ou à la main : glab auth login --hostname $hote" >&2
            return 1
        fi
        jeton="$(cat "$RACINE/workspace/.gitlab/root-token")"
        if ! "$GLAB" auth login --hostname "$hote" --api-protocol http --git-protocol http --token "$jeton"; then
            echo "devzone : connexion à l'instance gitlab impossible : devzone enable gitlab, ou à la main : glab auth login --hostname $hote" >&2
            return 1
        fi
    elif ! "$GLAB" auth login --hostname "$hote"; then
        echo "devzone : connexion à l'instance gitlab impossible : glab auth login --hostname $hote" >&2
        return 1
    fi
    if ! "$GLAB" auth status --hostname "$hote" >/dev/null 2>&1; then
        echo "devzone : verification de la connexion impossible : glab auth status --hostname $hote" >&2
        return 1
    fi
}

# Change la plateforme : github (par défaut, comportement actuel) ou gitlab
changer_plateforme() {
    local cible="${1:-}" url="" attendre="" arg hote
    case "$cible" in
        github)
            # Retire le réglage credential du dernier hôte gitlab, s'il y en a un
            if [ -n "$(url_gitlab_lue)" ]; then
                git config --global --unset-all "credential.$(url_gitlab_lue).helper" 2>/dev/null || true
            fi
            retirer_glab
            retirer_cle plateforme
            retirer_cle gitlab_url
            echo "devzone : plateforme github (défaut) : contrôles gh ; glab et sa configuration retirés s'ils étaient installés"
            ;;
        gitlab)
            for arg in "${@:2}"; do
                if [ -n "$attendre" ]; then url="$arg"; attendre=""; continue; fi
                case "$arg" in
                    --url) attendre=1 ;;
                    *) echo "devzone : argument inconnu : $arg (devzone platform gitlab --url URL)" >&2; return 1 ;;
                esac
            done
            if [ -n "$attendre" ]; then
                echo "devzone : --url attend une URL" >&2
                return 1
            fi
            if [ -z "$url" ]; then
                if [ "$(valeur gitlab)" = on ]; then
                    url="$GITLAB_URL_MODULE"
                else
                    echo "devzone : URL manquante : devzone platform gitlab --url URL (ou un module gitlab actif pour l'instance locale)" >&2
                    return 1
                fi
            fi
            hote="$(hote_de "$url")"
            if ! installer_glab; then
                return 1
            fi
            if ! connexion_glab "$hote" "$url"; then
                echo "devzone : connexion à refaire : glab auth login --hostname $hote" >&2
                return 1
            fi
            if ! git config --global "credential.$url.helper" "!$GLAB auth git-credential"; then
                echo "devzone : réglage git credential impossible" >&2
                return 1
            fi
            ecrire plateforme gitlab
            ecrire gitlab_url "$url"
            echo "devzone : plateforme gitlab : $url, glab connecté"
            ;;
        *)
            echo "devzone : plateforme inconnue : ${cible:-(aucune)} ; choix : github (défaut) ou gitlab [--url URL]" >&2
            return 1
            ;;
    esac
}
