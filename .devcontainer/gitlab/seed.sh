#!/usr/bin/env bash
# Seed of the GitLab of devzone (#396, #538): the data a fresh instance needs,
# group devzone, demo project, dev user, runner. Sourced by gitlab.sh. The
# installer starts the relays and waits for GitLab before the seed; the seed
# command (devzone gitlab seed, run in the pod by services-admin.sh when Argo
# CD holds the chart) does it itself (gitlab_seed_command).
#   gitlab_wait_ready           waits for the readiness of GitLab (GITLAB_ATTENTE)
#   gitlab_seed                 group, project, user, runner token and its Secret
#   gitlab_seed_command         devzone gitlab seed: relays, readiness, seed

# ---- Helper: wait until GitLab is ready ----
gitlab_wait_ready() {
    local start
    start=$(date +%s)
    echo "▶ Waiting for GitLab to be ready (timeout ${GITLAB_ATTENTE}s)…"
    while [ $(( $(date +%s) - start )) -lt "$GITLAB_ATTENTE" ]; do
        if curl -sf http://gitlab.localhost:8929/-/readiness >/dev/null 2>&1 || curl -sf http://gitlab.localhost:8929/users/sign_in >/dev/null 2>&1; then
            echo "▶ GitLab ready."
            return 0
        fi
        sleep 5
    done
    echo "devzone : timeout waiting for GitLab." >&2
    return 1
}

# ---- seed: fill GitLab with the base data ----
gitlab_seed() {
    echo "▶ Seeding GitLab…"

    mkdir -p "$GITLAB_SECRETS_DIR"

    # Root password read from the gitlab-gitlab-initial-root-password secret
    local password
    password="$(kubectl --context devzone get secret -n "$GITLAB_NS" gitlab-gitlab-initial-root-password -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
    if [ -z "$password" ]; then
        echo "devzone : seed GitLab : root secret (gitlab-gitlab-initial-root-password) not found, seed stopped." >&2
        return 1
    fi
    printf '%s' "$password" > "$GITLAB_SECRETS_DIR/root-password"
    chmod 600 "$GITLAB_SECRETS_DIR/root-password"

    # Root access token created by kubectl exec in the toolbox pod with gitlab-rails runner
    local toolbox_pod root_token
    toolbox_pod="$(kubectl --context devzone get pod -n "$GITLAB_NS" -l app=toolbox -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [ -z "$toolbox_pod" ]; then
        echo "devzone : seed GitLab : toolbox pod (label app=toolbox) not found, seed stopped." >&2
        return 1
    fi
    root_token="$(kubectl --context devzone exec -n "$GITLAB_NS" "$toolbox_pod" -- gitlab-rails runner 'puts User.find_by_username("root").personal_access_tokens.create(name: "devzone", scopes: ["api", "write_repository"], expires_at: 30.days.from_now).token' 2>/dev/null | tail -n 1 || true)"
    if [ -z "$root_token" ]; then
        echo "devzone : seed GitLab : creation of the root token (gitlab-rails runner) failed, seed stopped." >&2
        return 1
    fi
    printf '%s' "$root_token" > "$GITLAB_SECRETS_DIR/root-token"
    chmod 600 "$GITLAB_SECRETS_DIR/root-token"

    # Through the curl API with the token (never shown in clear)
    local token group_id
    token="$(cat "$GITLAB_SECRETS_DIR/root-token")"

    # Group devzone (tested before creation)
    if ! curl -sf --header "PRIVATE-TOKEN: $token" "http://gitlab.localhost:8929/api/v4/groups/devzone" >/dev/null 2>&1; then
        if ! curl -sf --header "PRIVATE-TOKEN: $token" --request POST "http://gitlab.localhost:8929/api/v4/groups" --data "name=devzone&path=devzone&visibility=private" >/dev/null 2>&1; then
            echo "devzone : seed GitLab : creation of the devzone group failed, seed stopped." >&2
            return 1
        fi
    fi
    group_id="$(curl -s --header "PRIVATE-TOKEN: $token" "http://gitlab.localhost:8929/api/v4/groups/devzone" | jq -r '.id // empty')"
    if [ -z "$group_id" ]; then
        echo "devzone : seed GitLab : reading the numeric id of the devzone group failed, seed stopped." >&2
        return 1
    fi

    # Project devzone/demo (tested before creation, namespace_id = numeric ID of the group)
    if ! curl -sf --header "PRIVATE-TOKEN: $token" "http://gitlab.localhost:8929/api/v4/projects/devzone%2Fdemo" >/dev/null 2>&1; then
        if ! curl -sf --header "PRIVATE-TOKEN: $token" --request POST "http://gitlab.localhost:8929/api/v4/projects" --data "name=demo&namespace_id=$group_id" >/dev/null 2>&1; then
            echo "devzone : seed GitLab : creation of the devzone/demo project failed, seed stopped." >&2
            return 1
        fi
    fi

    # Dev user (tested before creation, password generated at random):
    # an existing dev-password is reused only if the dev user still exists
    # (checked through the API); otherwise it is created again with a new user.
    local users_json dev_password
    users_json="$(curl -s --header "PRIVATE-TOKEN: $token" "http://gitlab.localhost:8929/api/v4/users?username=dev")"
    if [ "$(jq length <<<"$users_json")" -eq 0 ]; then
        dev_password="$(openssl rand -base64 18 | tr -d '\n')"
        if ! curl -sf --header "PRIVATE-TOKEN: $token" --request POST "http://gitlab.localhost:8929/api/v4/users" --data "email=dev@gitlab.localhost&username=dev&name=dev&skip_confirmation=true" --data-urlencode "password=$dev_password" >/dev/null 2>&1; then
            echo "devzone : seed GitLab : creation of the dev user failed, seed stopped." >&2
            return 1
        fi
        printf '%s' "$dev_password" > "$GITLAB_SECRETS_DIR/dev-password"
        chmod 600 "$GITLAB_SECRETS_DIR/dev-password"
    fi

    # Runner token: checked through POST /api/v4/runners/verify; a valid token
    # is kept, a refused token (403/404) is created again, GitLab unreachable stops the seed.
    local runner_saved runner_code runner_token
    if [ -f "$GITLAB_SECRETS_DIR/runner-token" ]; then
        runner_saved="$(cat "$GITLAB_SECRETS_DIR/runner-token")"
        runner_code="$(curl -s -o /dev/null -w '%{http_code}' --header "PRIVATE-TOKEN: $token" --request POST "http://gitlab.localhost:8929/api/v4/runners/verify" --data "token=${runner_saved}" || true)"
        if [ "$runner_code" = "200" ]; then
            echo "✔ Runner token valid: kept."
        elif [ "$runner_code" = "403" ] || [ "$runner_code" = "404" ]; then
            echo "devzone : runner token of a previous installation refused: recreated."
            runner_token="$(curl -s --header "PRIVATE-TOKEN: $token" --request POST "http://gitlab.localhost:8929/api/v4/user/runners" --data "runner_type=instance_type" 2>/dev/null | jq -r '.token // empty' || true)"
            if [ -z "$runner_token" ]; then
                echo "devzone : seed GitLab : creation of the runner token (POST /api/v4/user/runners) failed, seed stopped." >&2
                return 1
            fi
            printf '%s' "$runner_token" > "$GITLAB_SECRETS_DIR/runner-token"
            chmod 600 "$GITLAB_SECRETS_DIR/runner-token"
        else
            echo "devzone : seed GitLab : runner token check impossible (code ${runner_code}), seed stopped." >&2
            return 1
        fi
    else
        runner_token="$(curl -s --header "PRIVATE-TOKEN: $token" --request POST "http://gitlab.localhost:8929/api/v4/user/runners" --data "runner_type=instance_type" 2>/dev/null | jq -r '.token // empty' || true)"
        if [ -z "$runner_token" ]; then
            echo "devzone : seed GitLab : creation of the runner token (POST /api/v4/user/runners) failed, seed stopped." >&2
            return 1
        fi
        printf '%s' "$runner_token" > "$GITLAB_SECRETS_DIR/runner-token"
        chmod 600 "$GITLAB_SECRETS_DIR/runner-token"
    fi

    # Secret of the runner of the chart (runners.secret, #538): created apart, out
    # of Git; the token is read from its file, never on a command line
    if ! kubectl --context devzone -n "$GITLAB_NS" create secret generic gitlab-runner-secret \
        --from-file=runner-token="$GITLAB_SECRETS_DIR/runner-token" \
        --from-literal=runner-registration-token= \
        --dry-run=client -o yaml |
        kubectl --context devzone -n "$GITLAB_NS" apply -f - >/dev/null 2>&1; then
        echo "devzone : seed GitLab : secret gitlab-runner-secret not created, seed stopped." >&2
        return 1
    fi
    # A runner already running may hold the previous token: restarted on the
    # one just written (no runner yet: nothing to restart)
    kubectl --context devzone -n "$GITLAB_NS" rollout restart deployment \
        --selector=app=gitlab-gitlab-runner >/dev/null 2>&1 || true

    # Push of the content of demo/ to devzone/demo (temporary git repository, http remote with the token in the URL, never shown; branch main)
    # The push uses the root token (write_repository): the runner token cannot push.
    local push_token=""
    push_token="$(cat "$GITLAB_SECRETS_DIR/root-token")"
    if [ -z "$push_token" ]; then
        echo "devzone : seed GitLab : root token not found, seed stopped." >&2
        return 1
    fi
    # Already pushed (installation run again): nothing to do
    if curl -sf --header "PRIVATE-TOKEN: $push_token" "http://gitlab.localhost:8929/api/v4/projects/devzone%2Fdemo/repository/branches/main" >/dev/null 2>&1; then
        echo "✔ GitLab seed complete (demo project already pushed)."
        regenerer_identifiants
        return 0
    fi
    if [ -d "$ICI/demo" ]; then
        local tmpdir
        tmpdir="$(mktemp -d)"
        cp -r "$ICI/demo/." "$tmpdir/"
        if (
            cd "$tmpdir"
            # Throwaway repository of the script: the global git hooks (repowarden)
            # have nothing to check here and would refuse the commit
            export GIT_CONFIG_PARAMETERS="'core.hooksPath=/dev/null'"
            git init -q -b main
            git add -A
            git -c user.email=dev@gitlab.localhost -c user.name=dev commit -q -m "chore: projet de démonstration"
            # gitlab.localhost is not always resolved by git: local address,
            # and the host expected by the ingress passed as a header
            git remote add origin "http://oauth2:${push_token}@127.0.0.1:8929/devzone/demo.git"
            git -c http.extraHeader="Host: gitlab.localhost" push -q -u origin main >/dev/null 2>&1
        ); then
            # Checks the push: the main branch exists on the project
            if ! curl -sf --header "PRIVATE-TOKEN: $push_token" "http://gitlab.localhost:8929/api/v4/projects/devzone%2Fdemo/repository/branches/main" >/dev/null 2>&1; then
                echo "devzone : seed GitLab : push of the demo project to /devzone/demo.git succeeded but branch main is missing, seed stopped." >&2
                rm -rf "$tmpdir"
                return 1
            fi
        else
            echo "devzone : seed GitLab : push of the demo project to /devzone/demo.git failed, seed stopped." >&2
            rm -rf "$tmpdir"
            return 1
        fi
        rm -rf "$tmpdir"
    fi

    echo "✔ GitLab seed complete."
    regenerer_identifiants
}

# devzone gitlab seed: the seed alone, when Argo CD holds the chart (the
# workstation runs it in the pod, services-admin.sh seed gitlab). The API and
# the push go through the relays: they start, GitLab is awaited, then the seed.
# The Rails secret of the pod is mirrored when it is not kept yet.
gitlab_seed_command() {
    gitlab_relay_start || return 1
    gitlab_wait_ready || return 1
    gitlab_seed || return 1
    if [ ! -f "$GITLAB_RAILS_FILE" ]; then
        gitlab_secrets_copy
    fi
}
