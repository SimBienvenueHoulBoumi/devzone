#!/usr/bin/env bash
# Secret Rails GitLab (#347) : conservation dans workspace/.gitlab du secret
# gitlab-rails-secret du namespace devzone-gitlab, source des secrets Rails.
# À la première installation, le secret du cluster est copié dans
# workspace/.gitlab/rails-secret.yaml (600, ignoré par git) ; à une réinstallation,
# s'il existe, il est réappliqué avant helm upgrade --install (le chart le réutilise
# et les sessions du navigateur restent valides, sans 422). À défaut, si les secrets
# ont été perdus, la fin d'installation et le récapitulatif préviennent.

# Nom du secret Rails et fichier source des secrets du module
GITLAB_RAILS_SECRET="gitlab-rails-secret"
GITLAB_RAILS_FICHIER="$GITLAB_SECRETS_DIR/rails-secret.yaml"

# Lit le secret Rails du cluster et écrit le fichier source (première installation).
gitlab_secrets_copier() {
    mkdir -p "$GITLAB_SECRETS_DIR"
    kubectl --context devzone get secret -n "$GITLAB_NS" "$GITLAB_RAILS_SECRET" \
        -o jsonpath='{.data.secrets\.yml}' 2>/dev/null | base64 -d >"$GITLAB_RAILS_FICHIER"
    chmod 600 "$GITLAB_RAILS_FICHIER"
}

# Réapplique le secret Rails depuis le fichier source avant un helm upgrade
# --install : le chart réutilise le secret existant, les sessions du navigateur
# restent valides après une réinstallation.
gitlab_secrets_appliquer() {
    if [ ! -f "$GITLAB_RAILS_FICHIER" ]; then
        return 0
    fi
    kubectl --context devzone apply -f "$GITLAB_RAILS_FICHIER" >/dev/null 2>&1
}

# Avertit si le secret Rails n'a pas pu être conservé : la réinstallation régénère
# le secret et les sessions du navigateur sont invalidées (422).
gitlab_secrets_avertir() {
    if [ ! -f "$GITLAB_RAILS_FICHIER" ]; then
        echo "GitLab réinstallé : si le navigateur affiche 422, supprimez les données de site de gitlab.localhost"
    fi
}

# Mot de passe aléatoire (root | dev) : appliqué par gitlab-rails runner dans le
# pod toolbox, puis le fichier source et le regroupé .password sont mis à jour.
# Rien n'est affiché, seulement le chemin.
gitlab_nouveau_mdp() {
    local utilisateur="${1:-}" mdp pod script
    case "$utilisateur" in
        root | dev) ;;
        *)
            echo "devzone : gitlab : utilisateur inconnu : ${utilisateur:-(absent)} (devzone gitlab nouveau-mdp [root|dev])" >&2
            return 2
            ;;
    esac
    mdp="$(openssl rand -hex 24)"
    pod="$(kubectl --context devzone get pod -n "$GITLAB_NS" -l app=toolbox -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [ -z "$pod" ]; then
        echo "devzone : gitlab : pod toolbox (label app=toolbox) introuvable, mot de passe non changé." >&2
        return 1
    fi
    script="u = User.find_by_username(\"$utilisateur\"); u.password = \"${mdp}\"; u.password_confirmation = \"${mdp}\"; u.save; puts u.persisted?"
    if ! kubectl --context devzone exec -n "$GITLAB_NS" "$pod" -- gitlab-rails runner "$script" >/dev/null 2>&1; then
        echo "devzone : gitlab : mot de passe (gitlab-rails runner) non appliqué." >&2
        return 1
    fi
    printf '%s' "$mdp" >"$GITLAB_SECRETS_DIR/$utilisateur-password"
    chmod 600 "$GITLAB_SECRETS_DIR/$utilisateur-password"
    password_regenerer ||
        echo "devzone : gitlab : identifiants regroupés non mis à jour (devzone mots-de-passe)" >&2
    printf '%s\n' "$RACINE/.password"
}
