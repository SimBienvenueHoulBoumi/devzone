#!/usr/bin/env bats
# Rebuild and gitlab (#366, #396): kind_keep_context and
# kind_create_keep_context (cluster.sh), installation in the services cluster
# without kind nor context switch, migration from kind-gitlab, failure cleared
# when gitlab is ready (devzone apply).
# Fake kind, kubectl, helm, docker, curl, setsid and git in $BATS_TEST_TMPDIR/bin:
# no real cluster, no real kubeconfig. Each fake tool logs its arguments in
# $BATS_TEST_TMPDIR/<tool>.log.

# Fake devzone: the gitlab module is Go (#866), only its calls are logged.
# Ready once the namespace exists; runner online when FAKE_RUNNERS is set.
fake_devzone_gitlab() {
    # The launcher calls itself by its path ("$ICI/devzone", #882): the fake
    # sits beside a copy of the launcher, the other scripts are linked.
    local source="$BATS_TEST_DIRNAME/../../.devcontainer" arbre="$BATS_TEST_TMPDIR/arbre" f
    mkdir -p "$arbre/.devcontainer"
    ln -sfn "$BATS_TEST_DIRNAME/../../manage" "$arbre/manage"
    for f in "$source"/*; do
        [ "$(basename "$f")" = devzone ] || ln -sfn "$f" "$arbre/.devcontainer/"
    done
    cp "$source/devzone" "$arbre/.devcontainer/launcher"
    DEVZONE="$arbre/.devcontainer/launcher"
    cat >"$arbre/.devcontainer/devzone" <<'FAKE'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
printf 'devzone %s\n' "$*" >>"$T/devzone.log"
case "$*" in
    "gitlab status")
        if [ ! -f "$T/namespace" ]; then
            echo "disabled"
        elif [ -n "${FAKE_RUNNERS:-}" ]; then
            echo "ready, runner online"
        else
            echo "ready, no runner"
        fi
        ;;
    "gitlab installed") [ -f "$T/namespace" ] ;;
    "gitlab host-set") echo "127.0.0.1 gitlab.localhost # devzone:gitlab" >>"$DEVZONE_HOSTS" ;;
esac
FAKE
    chmod +x "$arbre/.devcontainer/devzone"
}

setup() {
    load commun
    kind_vide
    kube_isole
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    GITLAB="$BATS_TEST_DIRNAME/../../.devcontainer/gitlab/gitlab.sh"
    CLUSTER="$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
    export DEVZONE_ROOT="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_STATE="$BATS_TEST_TMPDIR/modules"
    export DEVZONE_MEMINFO="$BATS_TEST_TMPDIR/meminfo"
    export DEVZONE_HOSTS="$BATS_TEST_TMPDIR/hosts"
    export DEVZONE_KUBE_HOST="$BATS_TEST_TMPDIR/hote.config"
    export KIND_CLUSTERS="$BATS_TEST_TMPDIR/clusters"
    SECRETS="$DEVZONE_ROOT/workspace/.gitlab"
    mkdir -p "$DEVZONE_ROOT/workspace" "$BATS_TEST_TMPDIR/bin"
    printf 'MemAvailable: 16000000 kB\n' >"$DEVZONE_MEMINFO"
    : >"$KIND_CLUSTERS"
    printf '127.0.0.1 localhost\n' >"$DEVZONE_HOSTS"

    # kind: clusters in $KIND_CLUSTERS; create and export write the kind-<name>
    # context into --kubeconfig (default ~/.kube/config), as the real one does
    cat >"$BATS_TEST_TMPDIR/bin/kind" <<'KIND'
#!/usr/bin/env bash
echo "kind $*" >>"$BATS_TEST_TMPDIR/kind.log"
sub="$1 $2"
name="" file="$HOME/.kube/config"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --name) name="$2"; shift ;;
        --kubeconfig) file="$2"; shift ;;
    esac
    shift
done
case "$sub" in
    "get clusters") cat "$KIND_CLUSTERS" ;;
    "create cluster")
        echo "$name" >>"$KIND_CLUSTERS"
        printf 'ctx: kind-%s\ncurrent-context: kind-%s\n' "$name" "$name" >>"$file" ;;
    "export kubeconfig")
        printf 'ctx: kind-%s\ncurrent-context: kind-%s\n' "$name" "$name" >>"$file" ;;
esac
if [ -n "${FAKE_KIND_FAIL:-}" ]; then exit 1; fi
exit 0
KIND

    # kubectl: fake kubeconfig ("ctx:" and "current-context:" lines), root
    # secret, toolbox pod, root token
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"$BATS_TEST_TMPDIR/kubectl.log"
file="$HOME/.kube/config"
case "$*" in
    "config current-context") sed -n 's/^current-context:[[:space:]]*//p' "$file" 2>/dev/null | head -1 ;;
    "config get-contexts -o name") sed -n 's/^ctx: //p' "$file" 2>/dev/null ;;
    "config use-context "*)
        { grep -v '^current-context:' "$file" 2>/dev/null || true; printf 'current-context: %s\n' "${3:-}"; } >"$file.tmp"
        mv "$file.tmp" "$file" ;;
    "config unset current-context")
        { grep -v '^current-context:' "$file" 2>/dev/null || true; } >"$file.tmp"
        mv "$file.tmp" "$file" ;;
    *"get nodes"*) echo "${FAKE_KUBE_MEMORY:-16Gi}" ;;
    *"get namespace "*) [ -f "$BATS_TEST_TMPDIR/namespace" ] && exit 0 ; exit 1 ;;
    *"get secret"*) echo "cGFzc3dvcmQxMjM=" ;;
    *"get pod"*) echo "gitlab-toolbox-1" ;;
    *"gitlab-rails runner"*) echo "token-root-secret" ;;
esac
exit 0
KUBE

    # helm: logs the arguments
    cat >"$BATS_TEST_TMPDIR/bin/helm" <<'HELM'
#!/usr/bin/env bash
echo "helm $*" >>"$BATS_TEST_TMPDIR/helm.log"
HELM

    # docker: logs, no real mapping nor network
    cat >"$BATS_TEST_TMPDIR/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
echo "docker $*" >>"$BATS_TEST_TMPDIR/docker.log"
exit 0
DOCKER

    # curl: simulated GitLab API (readiness, group, runner, token)
    cat >"$BATS_TEST_TMPDIR/bin/curl" <<'CURL'
#!/usr/bin/env bash
echo "curl $*" | sed -e 's/token=[^ &]*/token=<masked>/g' -e 's/PRIVATE-TOKEN: [^ "]*/PRIVATE-TOKEN: <masked>/g' >>"$BATS_TEST_TMPDIR/curl.log"
case "$*" in
    *"api/v4/runners/verify"*) echo 200 ;;
    *"api/v4/groups/devzone"*) echo '{"id":42}' ;;
    *"--request POST"*"api/v4/user/runners"*) echo '{"token":"token-runner-secret"}' ;;
    # main branch: absent until the fake git has pushed
    *"api/v4/projects/devzone%2Fdemo/repository"*) [ -f "$BATS_TEST_TMPDIR/pushed" ] || exit 22 ;;
    *"--request POST"*) ;;
    *"api/v4/projects/devzone%2Fdemo"*) exit 22 ;;
    *"api/v4/users?username=dev"*) echo '[]' ;;
    *"api/v4/runners/all"*) echo "${FAKE_RUNNERS:-[]}" ;;
esac
exit 0
CURL

    # git: logs, touches pushed
    cat >"$BATS_TEST_TMPDIR/bin/git" <<'GIT'
#!/usr/bin/env bash
echo "git $*" >>"$BATS_TEST_TMPDIR/git.log"
case "$*" in *" push "*) touch "$BATS_TEST_TMPDIR/pushed" ;; esac
GIT

    # setsid: logs without starting the port-forward
    cat >"$BATS_TEST_TMPDIR/bin/setsid" <<'SETSID'
#!/usr/bin/env bash
echo "setsid $*" >>"$BATS_TEST_TMPDIR/setsid.log"
SETSID

    chmod +x "$BATS_TEST_TMPDIR"/bin/*
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    fake_devzone_gitlab
}

# Writes the current context into the fake ~/.kube/config; empty = none
set_current_context() {
    printf 'current-context: %s\n' "$1" >"$HOME/.kube/config"
}

# Reads the current context of the fake ~/.kube/config
current_context() {
    sed -n 's/^current-context:[[:space:]]*//p' "$HOME/.kube/config" 2>/dev/null | head -1
}

@test "kind_keep_context: export without switching, current context kept" {
    set_current_context docker-desktop
    (
        set -e
        source "$CLUSTER"
        kind_keep_context export kubeconfig --name gitlab --kubeconfig "$HOME/.kube/config"
    ) || false
    grep -qxF "kind export kubeconfig --name gitlab --kubeconfig $HOME/.kube/config" "$BATS_TEST_TMPDIR/kind.log" || false
    grep -qxF 'ctx: kind-gitlab' "$HOME/.kube/config" || false
    [ "$(current_context)" = docker-desktop ] || false
}

@test "kind_keep_context: no context at start, none set at the end" {
    set_current_context ""
    (
        set -e
        source "$CLUSTER"
        kind_keep_context export kubeconfig --name gitlab --kubeconfig "$HOME/.kube/config"
    ) || false
    grep -qxF 'ctx: kind-gitlab' "$HOME/.kube/config" || false
    [ -z "$(current_context)" ] || false
    grep -qxF 'kubectl config unset current-context' "$BATS_TEST_TMPDIR/kubectl.log" || false
    ! grep -q 'config use-context' "$BATS_TEST_TMPDIR/kubectl.log" || false
}

@test "kind_keep_context: kind failure, code 1 returned under set -e, context restored" {
    set_current_context docker-desktop
    FAKE_KIND_FAIL=1 run bash -c '
        set -e
        source "$1"
        kind_keep_context create cluster --name gitlab
    ' _ "$CLUSTER"
    [ "$status" -eq 1 ] || false
    [ "$(current_context)" = docker-desktop ] || false
}

@test "kind_create_keep_context: calls kind create cluster, context kept" {
    set_current_context docker-desktop
    (
        set -e
        source "$CLUSTER"
        kind_create_keep_context --name devzone --wait 120s
    ) || false
    grep -qxF 'kind create cluster --name devzone --wait 120s' "$BATS_TEST_TMPDIR/kind.log" || false
    [ "$(current_context)" = docker-desktop ] || false
}

@test "apply: gitlab ready, runner online → failure mark cleared, summary at ✔" {
    touch "$BATS_TEST_TMPDIR/namespace"
    printf 'gitlab=on\n' >"$DEVZONE_STATE"
    mkdir -p "$SECRETS" && echo token >"$SECRETS/root-token"
    echo gitlab >"$DEVZONE_STATE-failed-gitlab"
    FAKE_RUNNERS='[{"id":1}]' run bash "$DEVZONE" apply
    [ "$status" -eq 0 ] || false
    [[ "$output" == *"already active, nothing to do"* ]] || false
    [ ! -e "$DEVZONE_STATE-failed-gitlab" ] || false
    FAKE_RUNNERS='[{"id":1}]' run bash "$DEVZONE"
    [[ "$output" == *"✔ module gitlab"* ]] || false
    [[ "$output" != *"failed"* ]] || false
}
