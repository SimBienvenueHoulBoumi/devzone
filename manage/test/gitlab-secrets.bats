#!/usr/bin/env bats
# GitLab Rails secret (#347): kept in workspace/.gitlab, applied again
# before helm upgrade --install, 422 warning and regenerated password.
# Fake kubectl, helm, curl, git, docker, getent, setsid, kill, pgrep, npm and
# gh in $BATS_TEST_TMPDIR/bin: no cluster, no real secret.

setup() {
    load commun
    relais_docker_isole
    kube_isole
    kind_vide
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    GITLAB="$BATS_TEST_DIRNAME/../../.devcontainer/gitlab/gitlab.sh"
    export DEVZONE_ROOT="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_STATE="$BATS_TEST_TMPDIR/modules"
    export DEVZONE_MEMINFO="$BATS_TEST_TMPDIR/meminfo"
    export DEVZONE_HOSTS="$BATS_TEST_TMPDIR/hosts"
    export KIND_CLUSTERS="$BATS_TEST_TMPDIR/clusters"
    export DEVZONE_PORTS_AUTO_DIR="$BATS_TEST_TMPDIR/ports-auto"
    SECRETS="$DEVZONE_ROOT/workspace/.gitlab"
    mkdir -p "$HOME" "$DEVZONE_ROOT/workspace" "$SECRETS" "$BATS_TEST_TMPDIR/bin"
    printf 'MemAvailable: 16000000 kB\n' >"$DEVZONE_MEMINFO"
    : >"$KIND_CLUSTERS"
    printf '127.0.0.1 localhost\n' >"$DEVZONE_HOSTS"

    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"$BATS_TEST_TMPDIR/kubectl.log"
T="$BATS_TEST_TMPDIR"
case "$*" in
    *"get nodes -o jsonpath"*) printf '%s\n' "${FAKE_CLUSTER_MEMORY:-16777216Ki}" ;;
    *"create namespace"*) printf 'kind: Namespace\nmetadata:\n  name: devzone-gitlab\n' ;;
    *"apply -f -"*) tee -a "$T/apply.log" ;;
    *"apply -f "*) ;;
    *"get namespace "*) [ -f "$T/namespace" ] && exit 0 ; exit 1 ;;
    *"label namespace "*) touch "$T/namespace" ;;
    *"get secret "*"gitlab-rails-secret"*)
        [ -n "${FAKE_SECRET_ABSENT:-}" ] && exit 1
        cat <<'SECRET'
{
  "apiVersion": "v1",
  "data": {"secrets.yml": "c2VjcmV0czoK"},
  "kind": "Secret",
  "metadata": {
    "annotations": {"kubectl.kubernetes.io/last-applied-configuration": "{\"x\":1}"},
    "creationTimestamp": "2026-01-01T00:00:00Z",
    "labels": {"app": "gitlab"},
    "managedFields": [{"manager": "helm"}],
    "name": "gitlab-rails-secret",
    "namespace": "devzone-gitlab",
    "ownerReferences": [{"name": "x"}],
    "resourceVersion": "123",
    "uid": "abc"
  },
  "type": "Opaque"
}
SECRET
        ;;
    *"get secret"*) echo "cGFzc3dvcmQxMjM=" ;;
    *"get pod"*) echo "gitlab-toolbox-1" ;;
    *"gitlab-rails runner -"*)
        cat >/dev/null
        if [ -n "${FAKE_RUNNER_OK:-}" ]; then echo "OK"; else echo "false"; fi
        ;;
    *"gitlab-rails runner"*) echo "token-root-secret" ;;
esac
exit 0
KUBE
    cat >"$BATS_TEST_TMPDIR/bin/helm" <<'HELM'
#!/usr/bin/env bash
echo "helm $*" >>"$BATS_TEST_TMPDIR/helm.log"
precedent=""
for a in "$@"; do
    if [ "$precedent" = -f ] && [ -f "$a" ]; then
        cat "$a" >>"$BATS_TEST_TMPDIR/helm.log"
    fi
    precedent="$a"
done
exit 0
HELM
    cat >"$BATS_TEST_TMPDIR/bin/curl" <<'CURL'
#!/usr/bin/env bash
echo "curl $*" | sed -e 's/token=[^ &]*/token=<masked>/g' -e 's/PRIVATE-TOKEN: [^ "]*/PRIVATE-TOKEN: <masked>/g' >>"$BATS_TEST_TMPDIR/curl.log"
case "$*" in
    *"api/v4/runners/verify"*) echo 200 ;;
    *"api/v4/groups/devzone"*) echo '{"id":42}' ;;
    *"--request POST"*"api/v4/user/runners"*) echo '{"token":"token-runner-secret"}' ;;
    *"api/v4/projects/devzone%2Fdemo/repository"*) [ -f "$BATS_TEST_TMPDIR/pousse" ] || exit 22 ;;
    *"--request POST"*) ;;
    *"api/v4/projects/devzone%2Fdemo"*) exit 22 ;;
    *"api/v4/users?username=dev"*) echo '[]' ;;
    *"api/v4/runners/all"*) echo "${FAKE_RUNNERS:-[]}" ;;
esac
exit 0
CURL
    printf '#!/usr/bin/env bash\necho "git $*" >>"%s/git.log"\ncase "$*" in *" push "*) touch "%s/pousse" ;; esac\n' "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/bin/git"
    printf '#!/usr/bin/env bash\necho "setsid $*" >>"%s/setsid.log"\n' "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/bin/setsid"
    cat >"$BATS_TEST_TMPDIR/bin/kill" <<'KILL'
#!/usr/bin/env bash
if [ "${1:-}" = "-0" ]; then
    builtin kill -0 "${2:-}" 2>/dev/null
    exit $?
fi
echo "kill $*" >>"$BATS_TEST_TMPDIR/kill.log"
exit 0
KILL
    cat >"$BATS_TEST_TMPDIR/bin/pgrep" <<'PGREP'
#!/usr/bin/env bash
echo "pgrep $*" >>"$BATS_TEST_TMPDIR/pgrep.log"
exit 1
PGREP
    cat >"$BATS_TEST_TMPDIR/bin/npm" <<'NPM'
#!/usr/bin/env bash
echo "npm $*" >>"$NPM_LOG"
if [ "${1:-}" = view ]; then
    printf '%s\n' "${NPM_PUBLIEE:-}"
    exit 0
fi
if [ "${1:-}" = ls ]; then
    printf '{"dependencies":{}}\n'
    exit 0
fi
NPM
    cat >"$BATS_TEST_TMPDIR/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "gh $*" >>"$BATS_TEST_TMPDIR/gh.log"
exit 1
GH
    cat >"$BATS_TEST_TMPDIR/bin/getent" <<'GETENT'
#!/usr/bin/env bash
echo "getent $*" >>"$BATS_TEST_TMPDIR/getent.log"
case "$*" in
    "hosts gitlab.localhost") echo "127.0.0.1 gitlab.localhost" ;;
esac
exit 0
GETENT
    printf '#!/usr/bin/env bash\necho "docker $*" >>"%s/docker.log"\nexit 0\n' "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/bin/docker"
    chmod +x "$BATS_TEST_TMPDIR"/bin/*
    export NPM_LOG="$BATS_TEST_TMPDIR/npm.log"
    : >"$NPM_LOG"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "gitlab : Rails secret copied to workspace/.gitlab (600), never shown" {
    run bash "$GITLAB" install
    [ "$status" -eq 0 ] || false
    [ -f "$SECRETS/rails-secret.yaml" ] || false
    [ "$(stat -c %a "$SECRETS/rails-secret.yaml" 2>/dev/null || stat -f %Lp "$SECRETS/rails-secret.yaml")" = 600 ]
    jq -e '.kind == "Secret"' "$SECRETS/rails-secret.yaml" >/dev/null || false
    ! grep -q 'resourceVersion' "$SECRETS/rails-secret.yaml" || false
    [[ "$output" != *"c2VjcmV0czoK"* ]] || false
    grep -Eq -- "helm --kubeconfig [^ ]+ upgrade --install gitlab [^ ]*charts/devzone-gitlab" "$BATS_TEST_TMPDIR/helm.log" || false
}

@test "gitlab : reinstallation applies the Rails secret again before helm upgrade --install" {
    echo "gitlab" >"$KIND_CLUSTERS"
    mkdir -p "$SECRETS"
    echo secret-local >"$SECRETS/rails-secret.yaml"
    run bash "$GITLAB" install
    [ "$status" -eq 0 ] || false
    grep -q -- "-n devzone-gitlab apply -f .*rails-secret.yaml" "$BATS_TEST_TMPDIR/kubectl.log" || false
    grep -Eq -- "helm --kubeconfig [^ ]+ upgrade --install gitlab [^ ]*charts/devzone-gitlab" "$BATS_TEST_TMPDIR/helm.log" || false
}

@test "gitlab : Rails secret missing → no file, no empty file" {
    export FAKE_SECRET_ABSENT=1
    run bash "$GITLAB" install
    [ "$status" -eq 0 ] || false
    [ ! -e "$SECRETS/rails-secret.yaml" ] || false
}

@test "gitlab : new-password root regenerates the password, shows only the path" {
    export FAKE_RUNNER_OK=1
    run bash "$GITLAB" new-password root
    [ "$status" -eq 0 ] || false
    [ "$output" = "$DEVZONE_ROOT/.password" ]
    grep -q "exec -i .*gitlab-rails runner -" "$BATS_TEST_TMPDIR/kubectl.log" || false
    [ -f "$SECRETS/root-password" ] || false
    grep -q $'^gitlab\thttp://gitlab.localhost:8929\troot\t' "$DEVZONE_ROOT/.password" || false
}

@test "gitlab : new-password dev regenerates the dev password" {
    export FAKE_RUNNER_OK=1
    run bash "$GITLAB" new-password dev
    [ "$status" -eq 0 ] || false
    [ -f "$SECRETS/dev-password" ] || false
}

@test "gitlab : new-password without OK → file unchanged, non-zero code" {
    printf 'old-password' >"$SECRETS/root-password"
    run bash "$GITLAB" new-password root
    [ "$status" -ne 0 ] || false
    [ "$(cat "$SECRETS/root-password")" = old-password ] || false
}

@test "gitlab : new-password with OK → file updated, password absent from the arguments" {
    printf 'old-password' >"$SECRETS/root-password"
    export FAKE_RUNNER_OK=1
    run bash "$GITLAB" new-password root
    [ "$status" -eq 0 ] || false
    [ "$(cat "$SECRETS/root-password")" != old-password ] || false
    pass="$(cat "$SECRETS/root-password")"
    ! grep -q -- "$pass" "$BATS_TEST_TMPDIR/kubectl.log" || false
    grep -q $'^gitlab\thttp://gitlab.localhost:8929\troot\t'"$pass"'$' "$DEVZONE_ROOT/.password" || false
}

@test "gitlab : new-password: unknown user -> code 2" {
    run bash "$GITLAB" new-password admin
    [ "$status" -eq 2 ] || false
    [[ "$output" == *"unknown user"* ]] || false
}

@test "gitlab : uninstall keeps rails-secret.yaml" {
    printf '%s\n' '{"kind":"Secret","metadata":{"name":"gitlab-rails-secret"}}' >"$SECRETS/rails-secret.yaml"
    printf 'root' >"$SECRETS/root-password"
    run bash "$GITLAB" uninstall
    [ "$status" -eq 0 ] || false
    [ -f "$SECRETS/rails-secret.yaml" ] || false
    [ ! -e "$SECRETS/root-password" ] || false
    [[ "$output" == *"Rails secret kept in workspace/.gitlab/rails-secret.yaml"* ]] || false
}

@test "gitlab : complete uninstall --yes deletes rails-secret.yaml" {
    printf '%s\n' '{"kind":"Secret","metadata":{"name":"gitlab-rails-secret"}}' >"$SECRETS/rails-secret.yaml"
    run bash "$GITLAB" uninstall --yes
    [ "$status" -eq 0 ] || false
    [ ! -e "$SECRETS" ] || false
    [[ "$output" == *"Rails secret deleted"* ]] || false
}

@test "devzone : summary warns if the GitLab Rails secret was lost" {
    printf 'gitlab=on\n' >"$DEVZONE_STATE"
    run bash "$DEVZONE"
    [ "$status" -eq 0 ] || false
    [[ "$output" == *"GitLab reinstalled: if the browser shows 422, delete the site data of gitlab.localhost"* ]] || false
}

@test "devzone : summary without warning if the GitLab Rails secret is kept" {
    printf 'gitlab=on\n' >"$DEVZONE_STATE"
    mkdir -p "$SECRETS"
    printf '%s\n' '{"kind":"Secret","metadata":{"name":"gitlab-rails-secret"}}' >"$SECRETS/rails-secret.yaml"
    run bash "$DEVZONE"
    [ "$status" -eq 0 ] || false
    [[ "$output" != *"GitLab reinstalled"* ]] || false
}
