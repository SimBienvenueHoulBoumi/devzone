#!/usr/bin/env bats
# Menu at creation when no cluster answers (#653): create_mode_choose with a
# terminal forced by DEVZONE_TERMINAL=1 (answers on stdin). Fake kubectl, helm
# and minikube: no cluster is touched, nothing is installed. The cluster
# "answers" once $T/ready exists (created by use-context or minikube start).

setup() {
    load commun
    kube_isole
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CM="$RACINE/manage/scripts/create-mode.sh"
    T="$BATS_TEST_TMPDIR"
    FAKE_LOG="$T/tools.log"
    export FAKE_LOG T
    mkdir -p "$T/bin"
    cat >"$T/bin/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
echo "kubectl $*" >>"$FAKE_LOG"
case "$*" in
    *"config get-contexts"*) printf '%s\n' "${FAKE_CONTEXTS-docker-desktop}" | tr ' ' '\n' ;;
    *"config use-context"*) [ "${FAKE_USE_FAIL:-}" = 1 ] || touch "$T/ready" ;;
    *"cluster-info"*) [ -f "$T/ready" ] ;;
    *"current-context"*) echo docker-desktop ;;
    *"clusters[0].cluster.server"*) echo "${FAKE_SERVER:-https://203.0.113.5:6443}" ;;
    *"get application"*) exit 1 ;;
esac
KUBECTL
    printf '#!/usr/bin/env bash\necho "helm $*" >>"$FAKE_LOG"\nexit 1\n' >"$T/bin/helm"
    chmod +x "$T/bin/kubectl" "$T/bin/helm"
    PATH_SYSTEME="$PATH"
    outils_isoles "$T/outils"
    # the menu and the fakes also call these tools
    for outil in sed tr uname touch; do ln -s "$(command -v "$outil")" "$T/outils/$outil"; done
    mkdir -p "$T/mk"
    cat >"$T/mk/minikube" <<'MK'
#!/usr/bin/env bash
echo "minikube $*" >>"$FAKE_LOG"
[ "${FAKE_MINIKUBE_FAIL:-}" = 1 ] && exit 1
touch "$T/ready"
MK
    chmod +x "$T/mk/minikube"
    export PATH="$T/bin:$T/outils"
    export DEVZONE_TERMINAL=1
    : >"$FAKE_LOG"
    rm -f "$T/ready"
}

# Makes the fake minikube (logs, makes the cluster answer unless FAKE_MINIKUBE_FAIL=1) reachable.
avec_minikube() {
    export PATH="$T/mk:$PATH"
}

# Runs create_mode_choose with no option and the answers given as arguments
# (one per line on stdin): prints the mode set.
choisir() {
    local reponses
    reponses="$(printf '%s\n' "$@")"
    run bash -c '. "$1"; create_mode_choose "" <<<"$2" && echo "mode=$CREATE_MODE"' _ "$CM" "$reponses"
}

@test "no terminal: no menu, failure with the ways to get a cluster" {
    unset DEVZONE_TERMINAL
    run bash -c '. "$1"; create_mode_choose "" </dev/null && echo "mode=$CREATE_MODE"' _ "$CM"
    [ "$status" -eq 1 ]
    [[ "$output" != *"Your choice"* ]] || false
    [[ "$output" == *"Nothing created"* ]] || false
}

@test "--kubernetes without a cluster: no menu even in a terminal" {
    run bash -c '. "$1"; create_mode_choose kubernetes <<<"1" && echo "mode=$CREATE_MODE"' _ "$CM"
    [ "$status" -eq 1 ]
    [[ "$output" != *"Your choice"* ]] || false
}

@test "terminal: the menu is asked, an empty answer cancels, nothing created" {
    choisir ""
    [ "$status" -eq 1 ]
    [[ "$output" == *"Your choice"* ]] || false
    [[ "$output" == *"cancelled"* ]] || false
    [[ "$output" == *"Nothing created"* ]] || false
}

@test "remote: a local context is not offered, the remote one is marked remote" {
    FAKE_CONTEXTS="docker-desktop kind-poste prod-eks"
    export FAKE_CONTEXTS
    choisir 1 ""
    [[ "$output" == *"1) prod-eks (remote)"* ]] || false
    [[ "$output" != *"docker-desktop (remote)"* ]] || false
    [[ "$output" != *"kind-poste (remote)"* ]] || false
}

@test "remote: name typed back right -> context selected, mode kubernetes, cost warning" {
    FAKE_CONTEXTS="docker-desktop prod-eks"
    export FAKE_CONTEXTS
    choisir 1 1 prod-eks
    [ "$status" -eq 0 ]
    [[ "$output" == *"a pod, a volume and the namespace devzone-workspace"* ]] || false
    [[ "$output" == *"mode=kubernetes"* ]] || false
    grep -q "kubectl config use-context prod-eks" "$FAKE_LOG"
}

@test "remote: wrong name typed -> nothing done, no use-context" {
    FAKE_CONTEXTS="docker-desktop prod-eks"
    export FAKE_CONTEXTS
    choisir 1 1 prod
    [ "$status" -eq 1 ]
    [[ "$output" == *"name not typed back"* ]] || false
    ! grep -q "use-context" "$FAKE_LOG" || false
}

@test "remote: no remote context in the kubeconfig -> message, status 1" {
    FAKE_CONTEXTS="docker-desktop"
    export FAKE_CONTEXTS
    choisir 1
    [ "$status" -eq 1 ]
    [[ "$output" == *"no remote context in your kubeconfig"* ]] || false
}

@test "remote: a context pointing at localhost is treated as local" {
    FAKE_CONTEXTS="mon-cluster"
    FAKE_SERVER="https://127.0.0.1:6443"
    export FAKE_CONTEXTS FAKE_SERVER
    choisir 1
    [[ "$output" == *"no remote context"* ]] || false
}

@test "minikube missing: the install command is displayed, never run" {
    choisir 2
    [ "$status" -eq 1 ]
    [[ "$output" == *"minikube is not installed"* ]] || false
    [[ "$output" == *"Then run the same command again"* ]] || false
    [[ "$output" == *"brew install minikube"* || "$output" == *"minikube-linux-amd64"* || "$output" == *"winget install"* ]] || false
}

@test "minikube present, answer no: nothing started" {
    avec_minikube
    choisir 2 n
    [ "$status" -eq 1 ]
    ! grep -q "minikube start" "$FAKE_LOG" || false
}

@test "minikube present, answer yes: profile devzone started, mode kubernetes" {
    avec_minikube
    choisir 2 y
    [ "$status" -eq 0 ]
    grep -q "^minikube start -p devzone$" "$FAKE_LOG"
    [[ "$output" == *"mode=kubernetes"* ]] || false
}

@test "minikube start fails: status 1, message, no mode" {
    avec_minikube
    FAKE_MINIKUBE_FAIL=1
    export FAKE_MINIKUBE_FAIL
    choisir 2 y
    [ "$status" -eq 1 ]
    [[ "$output" == *"minikube start failed"* ]] || false
    [[ "$output" != *"mode="* ]] || false
}

@test "creation through the command: a cluster chosen in the menu creates the devzone in kubernetes mode" {
    FAKE_CONTEXTS="docker-desktop prod-eks"
    export FAKE_CONTEXTS
    export DEVZONE_NO_START=1
    # the whole creation copies files: the system tools after the fakes (the fake kubectl and helm stay first)
    export PATH="$T/bin:$T/outils:$PATH_SYSTEME"
    mkdir -p "$T/work"
    cd "$T/work"
    run bash -c 'bash "$1" mon --gitops none <<<"$2"' _ "$RACINE/manage/devzone" "$(printf '1\n1\nprod-eks\n')"
    [ "$status" -eq 0 ]
    [ "$(cat mon/.devzone.modules)" = "workspace=kubernetes" ]
}
