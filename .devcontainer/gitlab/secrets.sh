#!/usr/bin/env bash
# GitLab Rails secret (#347): kept in workspace/.gitlab, the gitlab-rails-secret
# secret of the devzone-gitlab namespace, source of the Rails secrets.
# At the first installation, the secret of the cluster is copied to
# workspace/.gitlab/rails-secret.yaml (600, ignored by git); at a reinstallation,
# if it exists, it is applied again before helm upgrade --install (the chart
# reuses it and the browser sessions stay valid, without 422). Otherwise, if the
# secrets were lost, the end of the installation and the summary warn.

# Name of the Rails secret and source file of the secrets of the module
GITLAB_RAILS_SECRET="gitlab-rails-secret"
GITLAB_RAILS_FILE="$GITLAB_SECRETS_DIR/rails-secret.yaml"

# jq filter: removes the fields specific to the cluster (identity, version,
# management, annotations of the last apply) and keeps a re-appliable JSON manifest.
GITLAB_RAILS_JQ='del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.managedFields, .metadata.ownerReferences, .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"])'

# Reads the Rails secret of the cluster and writes a real Secret manifest in JSON
# (first installation). Nothing is written if the read fails or if the secret is missing.
gitlab_secrets_copy() {
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
    mv -f "$tmp" "$GITLAB_RAILS_FILE"
}

# Applies the Rails secret again from the source file before a helm upgrade
# --install: the chart reuses the existing secret, the browser sessions stay
# valid after a reinstallation. A failure is shown and returned.
gitlab_secrets_apply() {
    if [ ! -f "$GITLAB_RAILS_FILE" ]; then
        return 0
    fi
    kubectl --context devzone -n "$GITLAB_NS" apply -f "$GITLAB_RAILS_FILE"
}

# Warns if the Rails secret could not be kept: the reinstallation generates a new
# secret and the browser sessions are invalidated (422).
gitlab_secrets_warn() {
    if [ ! -f "$GITLAB_RAILS_FILE" ]; then
        echo "GitLab reinstalled: if the browser shows 422, delete the site data of gitlab.localhost"
    fi
}

# Random password (root | dev): Ruby script passed on the standard input of
# gitlab-rails runner (never on the pod command line), then the source file and
# the grouped .password are updated if the runner confirms. Nothing is shown,
# only the path.
gitlab_new_password() {
    local user="${1:-}" pass pod script output file
    case "$user" in
        root | dev) ;;
        *)
            echo "devzone : gitlab : unknown user : ${user:-(missing)} (devzone gitlab new-password [root|dev])" >&2
            return 2
            ;;
    esac
    pass="$(openssl rand -hex 24)"
    pod="$(kubectl --context devzone get pod -n "$GITLAB_NS" -l app=toolbox -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [ -z "$pod" ]; then
        echo "devzone : gitlab : toolbox pod (label app=toolbox) not found, password not changed." >&2
        return 1
    fi
    script="u = User.find_by_username(\"$user\")
u.password = \"$pass\"
u.password_confirmation = \"$pass\"
u.save!
puts \"OK\""
    if ! output="$(printf '%s\n' "$script" | kubectl --context devzone exec -i -n "$GITLAB_NS" "$pod" -- gitlab-rails runner -)"; then
        echo "devzone : gitlab : password (gitlab-rails runner) not applied." >&2
        return 1
    fi
    if [[ "$output" != *OK* ]]; then
        echo "devzone : gitlab : password not confirmed by gitlab-rails runner." >&2
        return 1
    fi
    file="$GITLAB_SECRETS_DIR/$user-password"
    mkdir -p "$GITLAB_SECRETS_DIR" || return 1
    (umask 077 && printf '%s' "$pass" >"$file") || return 1
    chmod 600 "$file"
    password_regenerate ||
        echo "devzone : gitlab : grouped credentials not updated (devzone passwords)" >&2
    printf '%s\n' "$RACINE/.password"
}
