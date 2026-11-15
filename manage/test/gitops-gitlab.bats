#!/usr/bin/env bats
# GitLab as the GitOps repository (#559, step 6): the project and the files go
# through the GitLab API with a fake curl; the root token is read from a file,
# sent through a curl config file and never on the command line. No GitLab is
# reached.

setup() {
    RACINE="$BATS_TEST_TMPDIR/racine"
    LOG="$BATS_TEST_TMPDIR/curl.log"
    HEADER_LOG="$BATS_TEST_TMPDIR/entete.log"
    export RACINE LOG HEADER_LOG
    mkdir -p "$RACINE/workspace/.gitlab" "$BATS_TEST_TMPDIR/bin"
    printf 's3cr3t-root-token' >"$RACINE/workspace/.gitlab/root-token"
    : >"$LOG"
    : >"$HEADER_LOG"
    ARGOCD_CONF="$RACINE/.argocd.conf"
    export ARGOCD_CONF
    : >"$ARGOCD_CONF"
    # Fake curl: logs its arguments (never the token), answers by URL and method
    cat >"$BATS_TEST_TMPDIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
cfg=""
prev=""
for a in "$@"; do
    if [ "$prev" = --config ]; then cfg="$a"; fi
    prev="$a"
done
echo "$*" >>"$LOG"
if [ -n "$cfg" ] && grep -q '^header = "PRIVATE-TOKEN: ' "$cfg"; then echo "auth" >>"$HEADER_LOG"; fi
url="${*: -1}"
case "$*" in
    *"--request DELETE"*) echo '{}' ;;
    *"/repository/files/"*)
        if [ "${FILE_EXISTS:-no}" = yes ]; then echo "{\"blob_id\":\"$BLOB\"}"; else echo '{"message":"404 File Not Found"}'; fi ;;
    *"/api/v4/projects/devzone%2Fdevzone-argocd"*)
        if [ "${PROJECT_EXISTS:-yes}" = yes ]; then echo '{"id":7}'; else echo '{"message":"404"}'; fi ;;
    *"/api/v4/groups/devzone"*) echo '{"id":3}' ;;
    *"/api/v4/projects"*) echo '{"id":7}' ;;
    *) echo '{}' ;;
esac
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/curl"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    export PATH
    # shellcheck disable=SC1091
    . "$BATS_TEST_DIRNAME/../../.devcontainer/argocd/conf.sh"
    # shellcheck disable=SC1091
    . "$BATS_TEST_DIRNAME/../../.devcontainer/argocd/gitops-gitlab.sh"
    gitops_put_text() { echo "put-text $1" >>"$LOG"; }
    printf 'kind: Application\n' >"$BATS_TEST_TMPDIR/app.yaml"
    BLOB="$(git hash-object "$BATS_TEST_TMPDIR/app.yaml")"
    export BLOB
}

@test "the root token never reaches the command line, only the config file" {
    run gitlab_gitops_id
    [[ "$output" == 7 ]] || false
    [[ "$(cat "$LOG")" != *s3cr3t-root-token* ]] || false
    [[ "$(cat "$HEADER_LOG")" == auth ]] || false
}

@test "no root token: refused before any call" {
    rm -f "$RACINE/workspace/.gitlab/root-token"
    run gitlab_gitops_init
    [[ "$status" -eq 1 ]] || false
    [[ ! -s "$LOG" ]] || false
}

@test "init: project created under the group, repository designated with provider gitlab" {
    export PROJECT_EXISTS=no
    run gitlab_gitops_init
    [[ "$status" -eq 0 ]] || false
    [[ "$(cat "$LOG")" == *"--data namespace_id=3"* ]] || false
    [[ "$(cat "$LOG")" == *"put-text apps/.gitkeep"* ]] || false
    [[ "$(cat "$ARGOCD_CONF")" == *"provider = gitlab"* || "$(cat "$ARGOCD_CONF")" == *"provider=gitlab"* ]] || false
    [[ "$(cat "$ARGOCD_CONF")" == *"http://gitlab-webservice-default.devzone-gitlab.svc:8181/devzone/devzone-argocd.git"* ]] || false
}

@test "put: a new file is created with POST, an existing one updated with PUT" {
    export FILE_EXISTS=no
    run gitlab_gitops_put apps/app.yaml "$BATS_TEST_TMPDIR/app.yaml" "devzone: test"
    [[ "$status" -eq 0 ]] || false
    [[ "$(cat "$LOG")" == *"--request POST"*"repository/files/apps%2Fapp.yaml"* ]] || false
    : >"$LOG"
    export FILE_EXISTS=yes
    printf 'kind: Other\n' >"$BATS_TEST_TMPDIR/autre.yaml"
    run gitlab_gitops_put apps/app.yaml "$BATS_TEST_TMPDIR/autre.yaml" "devzone: test"
    [[ "$(cat "$LOG")" == *"--request PUT"* ]] || false
}

@test "put: a file already holding the same blob is not written again" {
    export FILE_EXISTS=yes
    run gitlab_gitops_put apps/app.yaml "$BATS_TEST_TMPDIR/app.yaml" "devzone: test"
    [[ "$status" -eq 0 ]] || false
    [[ "$(cat "$LOG")" != *"--request PUT"* ]] || false
    [[ "$(cat "$LOG")" != *"--request POST"* ]] || false
}

@test "delete: the file of the branch removed with DELETE; absent file: nothing" {
    export FILE_EXISTS=yes
    run gitlab_gitops_delete apps/app.yaml "devzone: removed"
    [[ "$(cat "$LOG")" == *"--request DELETE"*"apps%2Fapp.yaml"* ]] || false
    : >"$LOG"
    export FILE_EXISTS=no
    run gitlab_gitops_delete apps/absent.yaml "devzone: removed"
    [[ "$(cat "$LOG")" != *"--request DELETE"* ]] || false
}

@test "gitops_put dispatches to GitLab when provider = gitlab (no gh call)" {
    conf_set argocd "provider=gitlab"
    # shellcheck disable=SC1091
    . "$BATS_TEST_DIRNAME/../../.devcontainer/argocd/gitops.sh"
    gitlab_gitops_put() { echo "gitlab-put $*" >>"$LOG"; }
    gh() { echo "gh-called" >>"$LOG"; }
    run gitops_put apps/a.yaml "$BATS_TEST_TMPDIR/app.yaml" "m"
    [[ "$(cat "$LOG")" == "gitlab-put apps/a.yaml $BATS_TEST_TMPDIR/app.yaml m" ]] || false
}
