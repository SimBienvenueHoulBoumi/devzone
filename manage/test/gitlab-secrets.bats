#!/usr/bin/env bats
# Secret Rails GitLab (#347) : conservation dans workspace/.gitlab, réapplication
# avant helm upgrade --install, avertissement 422 et mot de passe régénéré.
# Faux kubectl, helm, curl, git, docker, getent, socat, setsid, kill, pgrep, npm et
# gh dans $BATS_TEST_TMPDIR/bin : aucun cluster, aucun vrai secret.

setup() {
    load commun
    kind_vide
    relais_docker_isole
    kube_isole
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    GITLAB="$BATS_TEST_DIRNAME/../../.devcontainer/gitlab/gitlab.sh"
    export DEVZONE_RACINE="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_ETAT="$BATS_TEST_TMPDIR/modules"
    export DEVZONE_MEMINFO="$BATS_TEST_TMPDIR/meminfo"
    export DEVZONE_HOSTS="$BATS_TEST_TMPDIR/hosts"
    export KIND_CLUSTERS="$BATS_TEST_TMPDIR/clusters"
    export DEVZONE_PORTS_AUTO_DIR="$BATS_TEST_TMPDIR/ports-auto"
    SECRETS="$DEVZONE_RACINE/workspace/.gitlab"
    mkdir -p "$HOME" "$DEVZONE_RACINE/workspace" "$SECRETS" "$BATS_TEST_TMPDIR/bin"
    printf 'MemAvailable: 16000000 kB\n' >"$DEVZONE_MEMINFO"
    : >"$KIND_CLUSTERS"
    printf '127.0.0.1 localhost\n' >"$DEVZONE_HOSTS"

    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"$BATS_TEST_TMPDIR/kubectl.log"
T="$BATS_TEST_TMPDIR"
case "$*" in
    *"get nodes -o jsonpath"*) printf '%s\n' "${FAUX_MEMOIRE_CLUSTER:-16777216Ki}" ;;
    *"create namespace"*) printf 'kind: Namespace\nmetadata:\n  name: devzone-gitlab\n' ;;
    *"apply -f -"*) tee -a "$T/apply.log" ;;
    *"get namespace "*) [ -f "$T/namespace" ] && exit 0 ; exit 1 ;;
    *"label namespace "*) touch "$T/namespace" ;;
    *"get secret"*) echo "cGFzc3dvcmQxMjM=" ;;
    *"get pod"*) echo "gitlab-toolbox-1" ;;
    *"gitlab-rails runner"*) echo "jeton-root-secret" ;;
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
echo "curl $*" | sed -e 's/token=[^ &]*/token=<masque>/g' -e 's/PRIVATE-TOKEN: [^ "]*/PRIVATE-TOKEN: <masque>/g' >>"$BATS_TEST_TMPDIR/curl.log"
case "$*" in
    *"api/v4/runners/verify"*) echo 200 ;;
    *"api/v4/groups/devzone"*) echo '{"id":42}' ;;
    *"--request POST"*"api/v4/user/runners"*) echo '{"token":"jeton-runner-secret"}' ;;
    *"api/v4/projects/devzone%2Fdemo/repository"*) [ -f "$BATS_TEST_TMPDIR/pousse" ] || exit 22 ;;
    *"--request POST"*) ;;
    *"api/v4/projects/devzone%2Fdemo"*) exit 22 ;;
    *"api/v4/users?username=dev"*) echo '[]' ;;
    *"api/v4/runners/all"*) echo "${FAUX_RUNNERS:-[]}" ;;
esac
exit 0
CURL
    cat >"$BATS_TEST_TMPDIR/bin/git" <<'GIT'
#!/usr/bin/env bash
echo "git $*" >>"$BATS_TEST_TMPDIR/git.log"
case "$*" in *" push "*) touch "$BATS_TEST_TMPDIR/pousse" ;; esac
GIT
    cat >"$BATS_TEST_TMPDIR/bin/setsid" <<'SETSID'
#!/usr/bin/env bash
echo "setsid $*" >>"$BATS_TEST_TMPDIR/setsid.log"
SETSID
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
    cat >"$BATS_TEST_TMPDIR/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
echo "docker $*" >>"$BATS_TEST_TMPDIR/docker.log"
exit 0
DOCKER
    chmod +x "$BATS_TEST_TMPDIR"/bin/*
    export NPM_LOG="$BATS_TEST_TMPDIR/npm.log"
    : >"$NPM_LOG"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "gitlab : secret rails copié dans workspace/.gitlab (600), jamais affiché" {
    run bash "$GITLAB" installer
    [ "$status" -eq 0 ] || false
    [ -f "$SECRETS/rails-secret.yaml" ] || false
    [ "$(stat -c %a "$SECRETS/rails-secret.yaml" 2>/dev/null || stat -f %Lp "$SECRETS/rails-secret.yaml")" = 600 ]
    [ "$(cat "$SECRETS/rails-secret.yaml")" = "password123" ]
    [[ "$output" != *"cGFzc3dvcmQxMjM"* ]] || false
    grep -q -- "--kube-context devzone upgrade --install gitlab gitlab/gitlab" "$BATS_TEST_TMPDIR/helm.log" || false
}

@test "gitlab : réinstallation réapplique le secret rails avant helm upgrade --install" {
    echo "gitlab" >"$KIND_CLUSTERS"
    mkdir -p "$SECRETS"
    echo secret-local >"$SECRETS/rails-secret.yaml"
    run bash "$GITLAB" installer
    [ "$status" -eq 0 ] || false
    grep -q -- "apply -f .*rails-secret.yaml" "$BATS_TEST_TMPDIR/kubectl.log" || false
    grep -q -- "--kube-context devzone upgrade --install gitlab gitlab/gitlab" "$BATS_TEST_TMPDIR/helm.log" || false
}

@test "gitlab : nouveau-mdp root régénère le mot de passe, n'affiche que le chemin" {
    run bash "$GITLAB" nouveau-mdp root
    [ "$status" -eq 0 ] || false
    [ "$output" = "$DEVZONE_RACINE/.password" ]
    grep -q "gitlab-rails runner" "$BATS_TEST_TMPDIR/kubectl.log" || false
    [ -f "$SECRETS/root-password" ] || false
    grep -q $'^gitlab\thttp://gitlab.localhost:8929\troot\t' "$DEVZONE_RACINE/.password" || false
}

@test "gitlab : nouveau-mdp dev régénère le mot de passe dev" {
    run bash "$GITLAB" nouveau-mdp dev
    [ "$status" -eq 0 ] || false
    [ -f "$SECRETS/dev-password" ] || false
}

@test "gitlab : nouveau-mdp : utilisateur inconnu -> code 2" {
    run bash "$GITLAB" nouveau-mdp admin
    [ "$status" -eq 2 ] || false
    [[ "$output" == *"utilisateur inconnu"* ]] || false
}

@test "devzone : récapitulatif avertit si le secret rails GitLab a été perdu" {
    printf 'gitlab=on\n' >"$DEVZONE_ETAT"
    run bash "$DEVZONE"
    [ "$status" -eq 0 ] || false
    [[ "$output" == *"GitLab réinstallé : si le navigateur affiche 422, supprimez les données de site de gitlab.localhost"* ]] || false
}

@test "devzone : récapitulatif sans avertissement si le secret rails GitLab est conservé" {
    printf 'gitlab=on\n' >"$DEVZONE_ETAT"
    mkdir -p "$SECRETS"
    echo secret-local >"$SECRETS/rails-secret.yaml"
    run bash "$DEVZONE"
    [ "$status" -eq 0 ] || false
    [[ "$output" != *"GitLab réinstallé"* ]] || false
}
