#!/usr/bin/env bats
# Connected clusters (#337): view, namespace, prompt, cache.

setup() {
    load commun
    relais_docker_isole
    kube_isole
    export DEVZONE_RACINE="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_ETAT="$BATS_TEST_TMPDIR/modules"
    mkdir -p "$DEVZONE_RACINE/workspace" "$BATS_TEST_TMPDIR/bin"
    : >"$DEVZONE_ETAT"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
}

fake_kubectl() {
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"$BATS_TEST_TMPDIR/kubectl.log"
T="$BATS_TEST_TMPDIR"
case "$*" in
    "config get-contexts -o name")
        cat "$T/contexts" 2>/dev/null || true
        ;;
    "config current-context")
        cat "$T/current" 2>/dev/null || true
        ;;
    "config use-context "*)
        printf '%s\n' "${3:-}" >"$T/current"
        ;;
    "config set-context "*)
        # records the requested namespace
        ctx="${3:-}"
        ns=""
        for a in "$@"; do case "$a" in --namespace) ;; esac; done
        # gets the last argument after --namespace
        prev=""
        for a in "$@"; do
            if [ "$prev" = "--namespace" ]; then ns="$a"; fi
            prev="$a"
        done
        printf '%s\n' "$ns" >"$T/ns.$ctx"
        ;;
    *"config view"*)
        # targeted context
        name=""
        for c in $(cat "$T/contexts" 2>/dev/null); do
            if [[ "$*" == *\"$c\"* ]]; then name="$c"; break; fi
        done
        if [[ "$*" == *'.context.namespace'* ]]; then
            if [ -f "$T/ns.$name" ]; then cat "$T/ns.$name"; else printf 'default\n'; fi
        elif [[ "$*" == *'.cluster.server'* ]]; then
            case "$name" in
                docker-desktop) echo "https://127.0.0.1:6443" ;;
                prod) echo "https://example.org:6443" ;;
                *) echo "https://127.0.0.1:6443" ;;
            esac
        else
            # .context.cluster
            echo "$name"
        fi
        ;;
    *"get --raw /readyz"*)
        case "$*" in
            *"--context unreachable "*) exit 1 ;;
            *"--context unreachable"*) exit 1 ;;
        esac
        exit 0
        ;;
esac
exit 0
KUBE
    chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
    : >"$BATS_TEST_TMPDIR/kubectl.log"
}

@test "clusters : table with marks and remote" {
    fake_kubectl
    printf 'docker-desktop\nkind-gitlab\nprod\nunreachable\n' >"$BATS_TEST_TMPDIR/contexts"
    printf 'docker-desktop\n' >"$BATS_TEST_TMPDIR/current"
    printf 'gitlab\n' >"$BATS_TEST_TMPDIR/ns.kind-gitlab"
    printf 'kind-devzone\n' >"$BATS_TEST_TMPDIR/modules"
    # services cluster = kind-devzone (not in contexts) -> no mark
    run bash "$DEVZONE" clusters
    [ "$status" -eq 0 ]
    [[ "$output" == *"CONTEXT"* ]] || false
    [[ "$output" == *"docker-desktop"* ]] || false
    [[ "$output" == *"kind-gitlab"* ]] || false
    [[ "$output" == *"prod"* ]] || false
    [[ "$output" == *"remote"* ]] || false
    [[ "$output" == *"unreachable"* ]] || false
    [[ "$output" == *"working cluster"* ]] || false
}

@test "clusters : no context" {
    fake_kubectl
    : >"$BATS_TEST_TMPDIR/contexts"
    run bash "$DEVZONE" clusters
    [ "$status" -eq 0 ]
    [[ "$output" == *"no cluster"* ]] || false
}

@test "clusters : services cluster marked, alone and with the work" {
    fake_kubectl
    printf 'docker-desktop\nkind-gitlab\n' >"$BATS_TEST_TMPDIR/contexts"
    printf 'docker-desktop\n' >"$BATS_TEST_TMPDIR/current"
    printf 'cluster=docker-desktop\n' >"$DEVZONE_ETAT"
    run bash "$DEVZONE" clusters
    [ "$status" -eq 0 ]
    [[ "$output" == *"★● docker-desktop"* ]] || false
    printf 'kind-gitlab\n' >"$BATS_TEST_TMPDIR/current"
    run bash "$DEVZONE" clusters
    [ "$status" -eq 0 ]
    [[ "$output" == *"●  docker-desktop"* ]] || false
    [[ "$output" == *"★  kind-gitlab"* ]] || false
}

@test "clusters : columns aligned under LC_ALL=C" {
    fake_kubectl
    printf 'docker-desktop\nkind-gitlab\n' >"$BATS_TEST_TMPDIR/contexts"
    printf 'docker-desktop\n' >"$BATS_TEST_TMPDIR/current"
    printf 'cluster=kind-gitlab\n' >"$DEVZONE_ETAT"
    run env LC_ALL=C bash "$DEVZONE" clusters
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -q '^   CONTEXT' || false
    printf '%s\n' "$output" | grep -q '^★  docker-desktop' || false
    printf '%s\n' "$output" | grep -q '^●  kind-gitlab' || false
}

@test "use CTX -n NS : set-context with namespace" {
    fake_kubectl
    printf 'docker-desktop\nprod\n' >"$BATS_TEST_TMPDIR/contexts"
    printf 'docker-desktop\n' >"$BATS_TEST_TMPDIR/current"
    run bash "$DEVZONE" use prod --confirm prod -n gitlab
    [ "$status" -eq 0 ]
    grep -q "config use-context prod" "$BATS_TEST_TMPDIR/kubectl.log" || false
    grep -q "config set-context prod --namespace gitlab" "$BATS_TEST_TMPDIR/kubectl.log" || false
}

@test "use -n only : keeps the context and changes the namespace" {
    fake_kubectl
    printf 'docker-desktop\n' >"$BATS_TEST_TMPDIR/contexts"
    printf 'docker-desktop\n' >"$BATS_TEST_TMPDIR/current"
    run bash "$DEVZONE" use -n dev
    [ "$status" -eq 0 ]
    grep -q "config set-context docker-desktop --namespace dev" "$BATS_TEST_TMPDIR/kubectl.log" || false
    ! grep -q "use-context" "$BATS_TEST_TMPDIR/kubectl.log" || false
}

@test "use remote without confirming : refused" {
    fake_kubectl
    printf 'prod\n' >"$BATS_TEST_TMPDIR/contexts"
    printf 'docker-desktop\n' >"$BATS_TEST_TMPDIR/current"
    run bash "$DEVZONE" use prod
    [ "$status" -eq 2 ]
    [[ "$output" == *"--confirm prod"* ]] || false
}

@test "prompt : local and remote and cache" {
    fake_kubectl
    printf 'docker-desktop\n' >"$BATS_TEST_TMPDIR/contexts"
    printf 'docker-desktop\n' >"$BATS_TEST_TMPDIR/current"
    : >"$BATS_TEST_TMPDIR/ns.docker-desktop"
    # default namespace
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../../.devcontainer/kube-prompt.sh"
    run devzone_kube_prompt
    [ "$status" -eq 0 ]
    [[ "$output" == *"docker-desktop/default"* ]] || false
    [[ "$output" != *"remote"* ]] || false
    before="$(wc -l <"$BATS_TEST_TMPDIR/kubectl.log")"
    run devzone_kube_prompt
    [ "$status" -eq 0 ]
    after="$(wc -l <"$BATS_TEST_TMPDIR/kubectl.log")"
    [ "$before" -eq "$after" ] || false
}

@test "prompt : non-printing markers around the colours" {
    fake_kubectl
    printf 'docker-desktop\n' >"$BATS_TEST_TMPDIR/contexts"
    printf 'docker-desktop\n' >"$BATS_TEST_TMPDIR/current"
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../../.devcontainer/kube-prompt.sh"
    run devzone_kube_prompt
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\001\033[36m\002'* ]] || false
    [[ "$output" == *$'\001\033[0m\002'* ]] || false
}

@test "prompt : no side effect on the calling shell" {
    fake_kubectl
    printf 'docker-desktop\n' >"$BATS_TEST_TMPDIR/contexts"
    printf 'docker-desktop\n' >"$BATS_TEST_TMPDIR/current"
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../../.devcontainer/kube-prompt.sh"
    run devzone_kube_prompt
    [ "$status" -eq 0 ]
    [ -z "${ICI+x}" ] || false
    [ -z "${ETAT+x}" ] || false
    [ -z "${CLUSTER_DEDIE+x}" ] || false
    ! declare -F cluster_est_local || false
}

@test "post-create : prompt block only once" {
    script="$BATS_TEST_DIRNAME/../../.devcontainer/post-create.sh"
    [ "$(grep -c '# >>> devzone invite >>>' "$script")" -eq 1 ] || false
    grep -q "kube-prompt.sh" "$script" || false
    grep -q 'PS1=.*devzone_kube_prompt' "$script" || false
}
