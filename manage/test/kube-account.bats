#!/usr/bin/env bats
# Limited Kubernetes account (#430): the token cycle moved to Go (devzone
# account token, #863); the library of the modules and the removal of the
# account stay in kube-account.sh. Fake kubectl in $BATS_TEST_TMPDIR/bin, which
# logs and keeps the state of the `config set-*` commands in $HOME/.kube/config:
# no cluster touched, never the workstation's kubeconfig.

setup() {
    load commun
    kube_isole
    KUBE_ACCOUNT="$BATS_TEST_DIRNAME/../../.devcontainer/kube-account.sh"
    export DEVZONE_STATE="$BATS_TEST_TMPDIR/modules"
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    : >"$DEVZONE_STATE"
    # hote.config exists and lists docker-desktop (host kubeconfig)
    : >"$DEVZONE_KUBE_HOST"
    printf 'docker-desktop\n' >"$BATS_TEST_TMPDIR/hote.contexts"
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"$BATS_TEST_TMPDIR/kubectl.log"
T="$BATS_TEST_TMPDIR"
CONFIG="$HOME/.kube/config"
mkdir -p "$HOME/.kube"
after() {
    local target="$1" a prev=""
    shift
    for a in "$@"; do
        if [ "$prev" = "$target" ]; then
            echo "$a"
            return 0
        fi
        prev="$a"
    done
}
case "$*" in
    *"config get-contexts -o name"*) cat "$T/hote.contexts" 2>/dev/null || true ;;
    *"config view"*)
        if [[ "$*" == *--minify* ]]; then
            # The agent kubeconfig is minified from the source file only: a
            # function reading the file it writes would get nothing here (#844).
            if [ "${FAKE_MINIFY_FAIL:-}" = 1 ]; then
                exit 1
            fi
            if [ "${KUBECONFIG:-}" = "$CONFIG" ]; then
                printf '# agent context minified from %s\n' "$KUBECONFIG"
            fi
        elif [[ "$*" == *'.context.cluster'* ]]; then
            case "$*" in
                *"docker-desktop"*) echo cluster-hote ;;
                *"kind-devzone"*) echo kind-devzone ;;
            esac
        elif [[ "$*" == *'.cluster.server'* ]]; then
            echo "https://127.0.0.1:6443"
        elif [[ "$*" == *'.cluster.certificate-authority-data'* ]]; then
            if [[ "$*" == *"--raw"* ]]; then
                if [ -z "${FAKE_NO_CA_DATA:-}" ]; then echo "Y2EtdGVzdAo="; fi
            else
                echo "DATA+OMITTED"
            fi
        fi
        ;;
    *"config set-cluster"*)
        # kubectl 1.37 refuses --certificate-authority-data at set-cluster
        case "$*" in
            *--certificate-authority-data*)
                echo "error: unknown flag: --certificate-authority-data" >&2
                exit 1 ;;
        esac
        if [ -n "${FAKE_FAIL_SET_CLUSTER:-}" ]; then exit 1; fi
        printf 'cluster: %s %s\n' "$(after set-cluster "$@")" "$4" >>"$CONFIG" ;;
    *"config set "*)
        if [ -n "${FAKE_FAIL_SET:-}" ]; then exit 1; fi
        printf 'set: %s %s\n' "$3" "$4" >>"$CONFIG" ;;
    *"config set-credentials"*)
        if [ -n "${FAKE_FAIL_SET_CREDENTIALS:-}" ]; then exit 1; fi
        printf 'user: %s %s\n' "$(after set-credentials "$@")" "$4" >>"$CONFIG" ;;
    *"config set-context"*)
        if [ -n "${FAKE_FAIL_SET_CONTEXT:-}" ]; then exit 1; fi
        printf 'context: %s %s %s\n' "$(after set-context "$@")" "$4" "$5" >>"$CONFIG" ;;
    *"auth can-i"*)
        printf 'kubeconfig=%s args=%s\n' "${KUBECONFIG:-}" "$*" >>"$T/auth.log"
        if [ -n "${FAKE_AUTH_FAIL:-}" ]; then exit 1; fi
        if [ -n "${FAKE_AUTH_NO:-}" ]; then echo no; exit 1; fi
        echo yes ;;
    *"create token"*)
        case "$*" in
            *jsonpath*)
                if [ -n "${FAKE_TOKEN_EXPIRY:-}" ]; then
                    printf 'token-test\n%s\n' "$FAKE_TOKEN_EXPIRY"
                else
                    echo token-test
                fi
                ;;
            *) echo token-test ;;
        esac
        ;;
    *"create namespace"*)
        printf 'kind: Namespace\nmetadata:\n  name: %s\n' "$(after namespace "$@")" ;;
    *"create serviceaccount"*)
        printf 'kind: ServiceAccount\nmetadata:\n  name: %s\n' "$(after serviceaccount "$@")" ;;
    *"create rolebinding"*)
        printf 'kind: RoleBinding\nmetadata:\n  name: %s\n' "$(after rolebinding "$@")" ;;
    *"get namespaces -l"*)
        if [ -f "$T/namespaces" ]; then cat "$T/namespaces"; fi
        ;;
    *"apply -f -"*) cat >>"$T/apply.log" ;;
    *"delete rolebinding"*) ;;
esac
exit 0
KUBE
    chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
    : >"$BATS_TEST_TMPDIR/kubectl.log"
    : >"$BATS_TEST_TMPDIR/apply.log"
    : >"$BATS_TEST_TMPDIR/auth.log"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "account_remove : RoleBinding deleted in the namespace" {
    (
        set -e
        source "$KUBE_ACCOUNT"
        account_remove docker-desktop devzone-postgres
    ) || false
    grep -qF -- "--context docker-desktop -n devzone-postgres delete rolebinding devzone-agent --ignore-not-found" \
        "$BATS_TEST_TMPDIR/kubectl.log" || false
}

@test "kube-account.sh jeton : renamed to devzone account token" {
    cat >"$BATS_TEST_TMPDIR/bin/devzone" <<'DEVZONE'
#!/usr/bin/env bash
echo "devzone $*" >>"$BATS_TEST_TMPDIR/devzone.log"
exit 0
DEVZONE
    chmod +x "$BATS_TEST_TMPDIR/bin/devzone"
    run bash "$KUBE_ACCOUNT" jeton
    [ "$status" -eq 0 ] || false
    [[ "$output" == *"devzone : « kube-account.sh jeton » was renamed: devzone account token"* ]] || false
    grep -q "account token" "$BATS_TEST_TMPDIR/devzone.log" || false
}
