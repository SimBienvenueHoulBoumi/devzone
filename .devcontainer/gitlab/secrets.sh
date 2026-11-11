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

# Filtre jq : retire les champs propres au cluster (identité, version, gestion,
# annotations du dernier apply) et garde un manifeste JSON réappliquable.
GITLAB_RAILS_JQ='del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.managedFields, .metadata.ownerReferences, .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"])'

# Lit le secret Rails du cluster et écrit un vrai manifeste Secret en JSON (première
# installation). Rien n'est écrit si la lecture échoue ou si le secret est absent.
gitlab_secrets_copier() {
    local secret tmp
    secret="$(kubectl --context devzone get secret -n "$GITLAB_NS" \
        "$GITLAB_RAILS_SECRET" -o json 2>/dev/null)" || return 0
    [ -n "$secret" ] || return 0
    mkdir -p "$GITLAB_SECRETS_DIR" || return 0
    tmp="$(umask 077; mktemp "$GITLAB_SECRETS_DIR/.rails-secret.XXXXXX")" || return 0
    if ! printf '%s\n' "$secret" | jq "$GITLAB_RAILS_JQ" >"$tmp" || [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        return 0
    fi
    chmod 600 "$tmp" || {
        rm -f "$tmp"
        return 0
    }
    mv -f "$tmp" "$GITLAB_RAILS_FICHIER"
}

# Réapplique le secret Rails depuis le fichier source avant un helm upgrade
# --install : le chart réutilise le secret existant, les sessions du navigateur
# restent valides après une réinstallation. L'échec est affiché et rendu.
gitlab_secrets_appliquer() {
    if [ ! -f "$GITLAB_RAILS_FICHIER" ]; then
        return 0
    fi
    kubectl --context devzone -n "$GITLAB_NS" apply -f "$GITLAB_RAILS_FICHIER"
}

# Avertit si le secret Rails n'a pas pu être conservé : la réinstallation régénère
# le secret et les sessions du navigateur sont invalidées (422).
gitlab_secrets_avertir() {
    if [ ! -f "$GITLAB_RAILS_FICHIER" ]; then
        echo "GitLab réinstallé : si le navigateur affiche 422, supprimez les données de site de gitlab.localhost"
    fi
}

# Mot de passe aléatoire (root | dev) : script Ruby passé sur l'entrée standard
# de gitlab-rails runner (jamais dans la ligne de commande du pod), puis le
# fichier source et le regroupé .password sont mis à jour si le runner confirme.
# Rien n'est affiché, seulement le chemin.
gitlab_nouveau_mdp() {
    local utilisateur="${1:-}" mdp pod script sortie fichier
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
    script="u = User.find_by_username(\"$utilisateur\")
u.password = \"$mdp\"
u.password_confirmation = \"$mdp\"
u.save!
puts \"OK\""
    if ! sortie="$(printf '%s\n' "$script" | kubectl --context devzone exec -i -n "$GITLAB_NS" "$pod" -- gitlab-rails runner -)"; then
        echo "devzone : gitlab : mot de passe (gitlab-rails runner) non appliqué." >&2
        return 1
    fi
    if [[ "$sortie" != *OK* ]]; then
        echo "devzone : gitlab : mot de passe non confirmé par gitlab-rails runner." >&2
        return 1
    fi
    fichier="$GITLAB_SECRETS_DIR/$utilisateur-password"
    mkdir -p "$GITLAB_SECRETS_DIR" || return 1
    (umask 077 && printf '%s' "$mdp" >"$fichier") || return 1
    chmod 600 "$fichier"
    password_regenerer ||
        echo "devzone : gitlab : identifiants regroupés non mis à jour (devzone mots-de-passe)" >&2
    printf '%s\n' "$RACINE/.password"
}
