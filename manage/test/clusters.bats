#!/usr/bin/env bats
# Clusters connectés (#337) : vue, namespace, invite, cache.

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

faux_kubectl() {
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
        # enregistre le namespace demande
        ctx="${3:-}"
        ns=""
        for a in "$@"; do case "$a" in --namespace) ;; esac; done
        # recupere le dernier argument apres --namespace
        prev=""
        for a in "$@"; do
            if [ "$prev" = "--namespace" ]; then ns="$a"; fi
            prev="$a"
        done
        printf '%s\n' "$ns" >"$T/ns.$ctx"
        ;;
    *"config view"*)
        # contexte vise
        nom=""
        for c in $(cat "$T/contexts" 2>/dev/null); do
            if [[ "$*" == *\"$c\"* ]]; then nom="$c"; break; fi
        done
        if [[ "$*" == *'.context.namespace'* ]]; then
            if [ -f "$T/ns.$nom" ]; then cat "$T/ns.$nom"; else printf 'default\n'; fi
        elif [[ "$*" == *'.cluster.server'* ]]; then
            case "$nom" in
                docker-desktop) echo "https://127.0.0.1:6443" ;;
                prod) echo "https://example.org:6443" ;;
                *) echo "https://127.0.0.1:6443" ;;
            esac
        else
            # .context.cluster
            echo "$nom"
        fi
        ;;
    *"get --raw /readyz"*)
        case "$*" in
            *"--context injoignable "*) exit 1 ;;
            *"--context injoignable"*) exit 1 ;;
        esac
        exit 0
        ;;
esac
exit 0
KUBE
    chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
    : >"$BATS_TEST_TMPDIR/kubectl.log"
}

@test "clusters : tableau avec marques et distant" {
    faux_kubectl
    printf 'docker-desktop\nkind-gitlab\nprod\ninjoignable\n' >"$BATS_TEST_TMPDIR/contexts"
    printf 'docker-desktop\n' >"$BATS_TEST_TMPDIR/current"
    printf 'gitlab\n' >"$BATS_TEST_TMPDIR/ns.kind-gitlab"
    printf 'kind-devzone\n' >"$BATS_TEST_TMPDIR/modules"
    # cluster services = kind-devzone (pas dans contexts) -> pas de marque
    run bash "$DEVZONE" clusters
    [ "$status" -eq 0 ]
    [[ "$output" == *"CONTEXTE"* ]] || false
    [[ "$output" == *"docker-desktop"* ]] || false
    [[ "$output" == *"kind-gitlab"* ]] || false
    [[ "$output" == *"prod"* ]] || false
    [[ "$output" == *"distant"* ]] || false
    [[ "$output" == *"injoignable"* ]] || false
    [[ "$output" == *"cluster de travail"* ]] || false
}

@test "clusters : aucun contexte" {
    faux_kubectl
    : >"$BATS_TEST_TMPDIR/contexts"
    run bash "$DEVZONE" clusters
    [ "$status" -eq 0 ]
    [[ "$output" == *"aucun cluster"* ]] || false
}

@test "utiliser CTX -n NS : set-context avec namespace" {
    faux_kubectl
    printf 'docker-desktop\nprod\n' >"$BATS_TEST_TMPDIR/contexts"
    printf 'docker-desktop\n' >"$BATS_TEST_TMPDIR/current"
    run bash "$DEVZONE" utiliser prod --confirmer prod -n gitlab
    [ "$status" -eq 0 ]
    grep -q "config use-context prod" "$BATS_TEST_TMPDIR/kubectl.log" || false
    grep -q "config set-context prod --namespace gitlab" "$BATS_TEST_TMPDIR/kubectl.log" || false
}

@test "utiliser -n seul : garde le contexte et change le namespace" {
    faux_kubectl
    printf 'docker-desktop\n' >"$BATS_TEST_TMPDIR/contexts"
    printf 'docker-desktop\n' >"$BATS_TEST_TMPDIR/current"
    run bash "$DEVZONE" utiliser -n dev
    [ "$status" -eq 0 ]
    grep -q "config set-context docker-desktop --namespace dev" "$BATS_TEST_TMPDIR/kubectl.log" || false
    ! grep -q "use-context" "$BATS_TEST_TMPDIR/kubectl.log" || false
}

@test "utiliser distant sans confirmer : refuse" {
    faux_kubectl
    printf 'prod\n' >"$BATS_TEST_TMPDIR/contexts"
    printf 'docker-desktop\n' >"$BATS_TEST_TMPDIR/current"
    run bash "$DEVZONE" utiliser prod
    [ "$status" -eq 2 ]
    [[ "$output" == *"cluster distant refusé"* ]] || false
}

@test "invite : local et distant et cache" {
    faux_kubectl
    printf 'docker-desktop\n' >"$BATS_TEST_TMPDIR/contexts"
    printf 'docker-desktop\n' >"$BATS_TEST_TMPDIR/current"
    : >"$BATS_TEST_TMPDIR/ns.docker-desktop"
    # namespace default
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../../.devcontainer/cluster.sh"
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../../.devcontainer/invite-kube.sh"
    run devzone_invite_kube
    [ "$status" -eq 0 ]
    [[ "$output" == *"docker-desktop/default"* ]] || false
    [[ "$output" != *"distant"* ]] || false
    before="$(wc -l <"$BATS_TEST_TMPDIR/kubectl.log")"
    run devzone_invite_kube
    [ "$status" -eq 0 ]
    after="$(wc -l <"$BATS_TEST_TMPDIR/kubectl.log")"
    [ "$before" -eq "$after" ] || false
}

@test "post-create : bloc invite une seule fois" {
    script="$BATS_TEST_DIRNAME/../../.devcontainer/post-create.sh"
    [ "$(grep -c '# >>> devzone invite >>>' "$script")" -eq 1 ] || false
    grep -q "invite-kube.sh" "$script" || false
    grep -q 'PS1=.*devzone_invite_kube' "$script" || false
}
