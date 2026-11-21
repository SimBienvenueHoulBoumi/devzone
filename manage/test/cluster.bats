#!/usr/bin/env bats
# devzone cluster (cluster.sh): cluster_is_local, cluster_candidates,
# cluster_menu, cluster_choose. Fake kubectl and kind in $BATS_TEST_TMPDIR/bin,
# no network call, HOME and DEVZONE_ETAT under $BATS_TEST_TMPDIR.

setup() {
    load commun
    kube_isole
    export HOME="$BATS_TEST_TMPDIR/home"
    export DEVZONE_ETAT="$BATS_TEST_TMPDIR/modules"
    export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
    export DEVZONE_INSTANCE=devzone
    mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin"
    : >"$DEVZONE_KUBE_HOTE"
    : >"$DEVZONE_ETAT"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# Fake kubectl: get-contexts reads host.contexts, config view returns one
# server pair per context (wildcard), get --raw /readyz answers unless
# FAKE_UNREACHABLE.
fake_kubectl() {
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"$BATS_TEST_TMPDIR/kubectl.log"
case "$*" in
    *"config get-contexts -o name"*)
        cat "$BATS_TEST_TMPDIR/host.contexts" 2>/dev/null || true
        ;;
    *"config view"*)
        name=""
        for c in $(cat "$BATS_TEST_TMPDIR/host.contexts" 2>/dev/null); do
            if [[ "$*" == *\"$c\"* ]]; then name="$c"; break; fi
        done
        if [[ "$*" == *'.cluster.server'* ]]; then
            case "$name" in
                docker-desktop) echo "https://127.0.0.1:6443" ;;
                cluster-prod) echo "https://example.org:6443" ;;
                kind-devzone) echo "https://127.0.0.1:6443" ;;
                kind-gitlab) echo "https://gitlab-control-plane:6443" ;;
                cluster-ipv6) echo "https://[::1]:6443" ;;
                no-server) echo "" ;;
                *) echo "https://127.0.0.1:6443" ;;
            esac
        else
            echo "$name"
        fi
        ;;
    *"get --raw /readyz"*)
        case "$*" in
            *"--context ${FAKE_UNREACHABLE:-none} "*) exit 1 ;;
        esac
        ;;
esac
exit 0
KUBE
    chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
    : >"$BATS_TEST_TMPDIR/kubectl.log"
}

# Fake kind: get clusters is empty
fake_kind() {
    printf '#!/usr/bin/env bash\necho "kind $*" >>"$BATS_TEST_TMPDIR/kind.log"\nexit 0\n' >"$BATS_TEST_TMPDIR/bin/kind"
    chmod +x "$BATS_TEST_TMPDIR/bin/kind"
    : >"$BATS_TEST_TMPDIR/kind.log"
}

# Fake kubectl limited to the current context: reads and writes
# $HOME/.kube/config, like the `kubectl config` commands used by
# kind_create_keep_context. The other calls are neutral.
fake_kubectl_contexte() {
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"$BATS_TEST_TMPDIR/kubectl.log"
file="$HOME/.kube/config"
mkdir -p "$HOME/.kube"
case "$*" in
    "config current-context")
        sed -n 's/^current-context:[[:space:]]*//p' "$file" 2>/dev/null | head -1
        ;;
    "config use-context "*)
        new_ctx="${3:-}"
        { grep -v '^current-context:' "$file" 2>/dev/null || true; printf 'current-context: %s\n' "$new_ctx"; } >"$file.tmp"
        mv "$file.tmp" "$file"
        ;;
    "config unset current-context")
        { grep -v '^current-context:' "$file" 2>/dev/null || true; } >"$file.tmp"
        mv "$file.tmp" "$file"
        ;;
esac
exit 0
KUBE
    chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
    : >"$BATS_TEST_TMPDIR/kubectl.log"
}

# Fake kind: get clusters is empty; create writes the context kind-<name> like
# the real one, then fails with code 1 if FAKE_KIND_ECHEC=1.
fake_kind_contexte() {
    cat >"$BATS_TEST_TMPDIR/bin/kind" <<'KIND'
#!/usr/bin/env bash
echo "kind $*" >>"$BATS_TEST_TMPDIR/kind.log"
case "$1 $2" in
    "get clusters") exit 0 ;;
    "create cluster")
        name=""
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --name) name="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        mkdir -p "$HOME/.kube"
        printf 'current-context: kind-%s\n' "$name" >"$HOME/.kube/config"
        if [ "${FAKE_KIND_ECHEC:-0}" = 1 ]; then exit 1; fi
        exit 0
        ;;
esac
exit 0
KIND
    chmod +x "$BATS_TEST_TMPDIR/bin/kind"
    : >"$BATS_TEST_TMPDIR/kind.log"
}

@test "cluster_is_local : dedicated kind is local" {
    fake_kubectl
    fake_kind
    printf 'kind-devzone\n' >"$BATS_TEST_TMPDIR/host.contexts"
    printf 'kind-devzone\thttps://127.0.0.1:6443\n' >"$BATS_TEST_TMPDIR/host.servers"
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_is_local kind-devzone
        [ "$status" -eq 0 ]
    ) || false
}

@test "cluster_is_local : host 127.0.0.1 is local" {
    fake_kubectl
    printf 'docker-desktop\n' >"$BATS_TEST_TMPDIR/host.contexts"
    printf 'docker-desktop\thttps://127.0.0.1:6443\n' >"$BATS_TEST_TMPDIR/host.servers"
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_is_local docker-desktop
        [ "$status" -eq 0 ]
    ) || false
}

@test "cluster_is_local : host localhost is local" {
    fake_kubectl
    printf 'docker-desktop\n' >"$BATS_TEST_TMPDIR/host.contexts"
    printf 'docker-desktop\thttps://localhost:6443\n' >"$BATS_TEST_TMPDIR/host.servers"
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_is_local docker-desktop
        [ "$status" -eq 0 ]
    ) || false
}

@test "cluster_is_local : remote host is not local" {
    fake_kubectl
    printf 'cluster-prod\n' >"$BATS_TEST_TMPDIR/host.contexts"
    printf 'cluster-prod\thttps://example.org:6443\n' >"$BATS_TEST_TMPDIR/host.servers"
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_is_local cluster-prod
        [ "$status" -ne 0 ]
    ) || false
}

@test "cluster_is_local : unknown context is remote" {
    fake_kubectl
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_is_local unknown
        [ "$status" -ne 0 ] || false
    ) || false
}

@test "cluster_is_local : without server is remote" {
    fake_kubectl
    printf 'no-server\n' >"$BATS_TEST_TMPDIR/host.contexts"
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_is_local no-server
        [ "$status" -ne 0 ] || false
    ) || false
}

@test "cluster_is_local : kind-gitlab (gitlab-control-plane) is local" {
    fake_kubectl
    printf 'kind-gitlab\n' >"$BATS_TEST_TMPDIR/host.contexts"
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_is_local kind-gitlab
        [ "$status" -eq 0 ] || false
    ) || false
}

@test "cluster_is_local : docker-desktop is local by name" {
    fake_kubectl
    printf 'docker-desktop\n' >"$BATS_TEST_TMPDIR/host.contexts"
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_is_local docker-desktop
        [ "$status" -eq 0 ] || false
    ) || false
}

@test "cluster_is_local : kind-x is local by name" {
    fake_kubectl
    printf 'kind-x\n' >"$BATS_TEST_TMPDIR/host.contexts"
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_is_local kind-x
        [ "$status" -eq 0 ] || false
    ) || false
}

@test "cluster_is_local : bracketed IPv6 server is local" {
    fake_kubectl
    printf 'cluster-ipv6\n' >"$BATS_TEST_TMPDIR/host.contexts"
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_is_local cluster-ipv6
        [ "$status" -eq 0 ] || false
    ) || false
}

@test "cluster_candidates : order local, dedicated kind, remote" {
    fake_kubectl
    fake_kind
    FAKE_UNREACHABLE=none
    printf 'docker-desktop\ncluster-prod\nkind-devzone\n' >"$BATS_TEST_TMPDIR/host.contexts"
    printf 'docker-desktop\thttps://127.0.0.1:6443\ncluster-prod\thttps://example.org:6443\nkind-devzone\thttps://127.0.0.1:6443\n' >"$BATS_TEST_TMPDIR/host.servers"
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_candidates
        [ "$status" -eq 0 ] || false
        [ "${lines[0]}" = "docker-desktop" ] || false
        [ "${lines[1]}" = "kind-devzone" ] || false
        [ "${lines[2]}" = "cluster-prod" ] || false
    )
}

@test "cluster_candidates : no hote.config → only the dedicated kind" {
    fake_kubectl
    fake_kind
    rm -f "$BATS_TEST_TMPDIR/hote.config"
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_candidates
        [ "$status" -eq 0 ]
        [ "$output" = "kind-devzone" ]
    ) || false
}

@test "cluster_menu : marks « remote » and Enter = first local" {
    set +e
    fake_kubectl
    (
        export DEVZONE_INTERACTIF=1
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        printf 'docker-desktop\ncluster-prod\n' >"$BATS_TEST_TMPDIR/host.contexts"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_menu <<<""
        [ "$status" -eq 0 ] || false
        [[ "$output" == *"local cluster"* ]] || false
        [[ "$output" == *"remote cluster"* ]] || false
        [ "$output" = "docker-desktop" ] || false
    )
}

@test "cluster_choose : default without state → local (dedicated kind)" {
    fake_kubectl
    fake_kind
    FAKE_UNREACHABLE=none
    printf 'docker-desktop\n' >"$BATS_TEST_TMPDIR/host.contexts"
    printf 'docker-desktop\thttps://127.0.0.1:6443\n' >"$BATS_TEST_TMPDIR/host.servers"
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_choose
        [ "$status" -eq 0 ]
        [ "$output" = "kind-devzone" ]
    ) || false
}

@test "cluster_choose : explicit local context accepted" {
    fake_kubectl
    fake_kind
    FAKE_UNREACHABLE=none
    printf 'docker-desktop\n' >"$BATS_TEST_TMPDIR/host.contexts"
    printf 'docker-desktop\thttps://127.0.0.1:6443\n' >"$BATS_TEST_TMPDIR/host.servers"
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_choose docker-desktop
        [ "$status" -eq 0 ]
        [ "$output" = "docker-desktop" ]
    ) || false
}

@test "cluster_choose : explicit remote context refused outside a terminal" {
    fake_kubectl
    fake_kind
    FAKE_UNREACHABLE=none
    printf 'cluster-prod\n' >"$BATS_TEST_TMPDIR/host.contexts"
    printf 'cluster-prod\thttps://example.org:6443\n' >"$BATS_TEST_TMPDIR/host.servers"
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_choose cluster-prod </dev/null
        [ "$status" -eq 2 ]
        [[ "$output" == *"remote cluster refused"* ]] || false
    ) || false
}

@test "cluster_choose : remote context accepted with DEVZONE_CLUSTER_DISTANT" {
    fake_kubectl
    fake_kind
    FAKE_UNREACHABLE=none
    printf 'cluster-prod\n' >"$BATS_TEST_TMPDIR/host.contexts"
    printf 'cluster-prod\thttps://example.org:6443\n' >"$BATS_TEST_TMPDIR/host.servers"
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        export DEVZONE_CLUSTER_DISTANT=cluster-prod
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_choose cluster-prod </dev/null
        [ "$status" -eq 0 ] || false
        [ "$output" = "cluster-prod" ] || false
    ) || false
}

@test "cluster_choose : other DEVZONE_CLUSTER_DISTANT refused" {
    fake_kubectl
    fake_kind
    FAKE_UNREACHABLE=none
    printf 'cluster-prod\n' >"$BATS_TEST_TMPDIR/host.contexts"
    printf 'cluster-prod\thttps://example.org:6443\n' >"$BATS_TEST_TMPDIR/host.servers"
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        export DEVZONE_CLUSTER_DISTANT=other
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_choose cluster-prod </dev/null
        [ "$status" -eq 2 ] || false
        [[ "$output" == *"remote cluster refused"* ]] || false
    ) || false
}

@test "cluster_choose : exact --confirm accepted outside a terminal" {
    fake_kubectl
    fake_kind
    FAKE_UNREACHABLE=none
    printf 'cluster-prod\n' >"$BATS_TEST_TMPDIR/host.contexts"
    printf 'cluster-prod\thttps://example.org:6443\n' >"$BATS_TEST_TMPDIR/host.servers"
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_choose cluster-prod --confirm cluster-prod </dev/null
        [ "$status" -eq 0 ] || false
        [ "$output" = "cluster-prod" ] || false
    ) || false
}

@test "cluster_choose : other --confirm refused" {
    fake_kubectl
    fake_kind
    FAKE_UNREACHABLE=none
    printf 'cluster-prod\n' >"$BATS_TEST_TMPDIR/host.contexts"
    printf 'cluster-prod\thttps://example.org:6443\n' >"$BATS_TEST_TMPDIR/host.servers"
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_choose cluster-prod --confirm other </dev/null
        [ "$status" -eq 2 ] || false
        [[ "$output" == *"remote cluster refused"* ]] || false
    ) || false
}

@test "cluster_choose : --confirm without value refused" {
    fake_kubectl
    fake_kind
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_choose cluster-prod --confirm </dev/null
        [ "$status" -eq 2 ] || false
        [[ "$output" == *"--confirm needs a context"* ]] || false
    ) || false
}

@test "cluster_choose : exact typed confirmation accepted" {
    fake_kubectl
    fake_kind
    FAKE_UNREACHABLE=none
    printf 'cluster-prod\n' >"$BATS_TEST_TMPDIR/host.contexts"
    printf 'cluster-prod\thttps://example.org:6443\n' >"$BATS_TEST_TMPDIR/host.servers"
    (
        export DEVZONE_INTERACTIF=1
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_choose cluster-prod <<<"cluster-prod"
        [ "$status" -eq 0 ] || false
    ) || false
}

@test "cluster_choose : confirmation o refused" {
    fake_kubectl
    fake_kind
    FAKE_UNREACHABLE=none
    printf 'cluster-prod\n' >"$BATS_TEST_TMPDIR/host.contexts"
    printf 'cluster-prod\thttps://example.org:6443\n' >"$BATS_TEST_TMPDIR/host.servers"
    (
        export DEVZONE_INTERACTIF=1
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_choose cluster-prod <<<"y"
        [ "$status" -eq 2 ] || false
    ) || false
}

@test "cluster_choose : unknown context refused" {
    fake_kubectl
    fake_kind
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_choose unknown </dev/null
        [ "$status" -eq 2 ]
        [[ "$output" == *"unknown or unreachable cluster"* ]] || false
    ) || false
}

@test "cluster_choose : choice kept in the state returned as is" {
    fake_kubectl
    fake_kind
    printf 'cluster=my-choice\n' >"$BATS_TEST_TMPDIR/etat"
    (
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        run cluster_choose
        [ "$status" -eq 0 ]
        [ "$output" = "my-choice" ]
    ) || false
}

@test "kind_create_keep_context : success, docker-desktop context restored" {
    fake_kubectl_contexte
    fake_kind_contexte
    mkdir -p "$HOME/.kube"
    printf 'current-context: docker-desktop\n' >"$HOME/.kube/config"
    (
        set -e
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        kind_create_keep_context --name devzone --wait 120s
    ) || false
    [ "$(sed -n 's/^current-context:[[:space:]]*//p' "$HOME/.kube/config")" = docker-desktop ] || false
    grep -qx 'kind create cluster --name devzone --wait 120s' "$BATS_TEST_TMPDIR/kind.log" || false
    grep -qx 'kubectl config use-context docker-desktop' "$BATS_TEST_TMPDIR/kubectl.log" || false
}

@test "kind_create_keep_context : failure under set -e, context restored and code 1 returned" {
    fake_kubectl_contexte
    fake_kind_contexte
    mkdir -p "$HOME/.kube"
    printf 'current-context: docker-desktop\n' >"$HOME/.kube/config"
    FAKE_KIND_ECHEC=1 run bash -c '
        set -e
        export DEVZONE_INSTANCE=devzone
        export ETAT="$1/etat"
        export DEVZONE_KUBE_HOTE="$1/hote.config"
        source "$2"
        kind_create_keep_context --name devzone --wait 120s
    ' _ "$BATS_TEST_TMPDIR" "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
    [ "$status" -eq 1 ] || false
    [ "$(sed -n 's/^current-context:[[:space:]]*//p' "$HOME/.kube/config")" = docker-desktop ] || false
    grep -qx 'kubectl config use-context docker-desktop' "$BATS_TEST_TMPDIR/kubectl.log" || false
}

@test "kind_create_keep_context : no context before, unset called" {
    fake_kubectl_contexte
    fake_kind_contexte
    mkdir -p "$HOME/.kube"
    : >"$HOME/.kube/config"
    (
        set -e
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        kind_create_keep_context --name devzone --wait 120s
    ) || false
    grep -qx 'kubectl config unset current-context' "$BATS_TEST_TMPDIR/kubectl.log" || false
    ! grep -q 'config use-context' "$BATS_TEST_TMPDIR/kubectl.log" || false
    [ -z "$(sed -n 's/^current-context:[[:space:]]*//p' "$HOME/.kube/config")" ] || false
}

@test "cluster_prepare : the kind cluster is created by kind_create_keep_context" {
    fake_kubectl_contexte
    fake_kind_contexte
    mkdir -p "$HOME/.kube"
    printf 'current-context: docker-desktop\n' >"$HOME/.kube/config"
    (
        set -e
        export DEVZONE_INSTANCE=devzone
        export ETAT="$BATS_TEST_TMPDIR/etat"
        export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
        source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
        cluster_prepare kind-devzone
    ) || false
    grep -qx 'kind create cluster --name devzone --wait 120s' "$BATS_TEST_TMPDIR/kind.log" || false
    [ "$(sed -n 's/^current-context:[[:space:]]*//p' "$HOME/.kube/config")" = docker-desktop ] || false
}
