#!/usr/bin/env bats
# Network isolation and access authorization between devzone namespaces (#396 step A).
# Tests with fake kubectl, kind: no cluster touched.
# Helpers of manage/test/commun.bash: kube_isole.

# Source of the isolation functions
source "$BATS_TEST_DIRNAME/../../.devcontainer/isolation.sh"

load commun
load commun-helm

setup() {
    kube_isole
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    export HOME="$BATS_TEST_TMPDIR/home"
    export DEVZONE_ROOT="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_STATE="$BATS_TEST_TMPDIR/modules"
    export DEVZONE_KUBE_HOST="$BATS_TEST_TMPDIR/hote.config"
    mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin" "$DEVZONE_ROOT/workspace"
    : >"$DEVZONE_KUBE_HOST"
    : >"$DEVZONE_STATE"
    helm_fake_install
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    active_on() {
        local c="${1:-}"
        [ -n "$c" ] || return 2
        printf 'postgres=on\ncluster=%s\n' "$c" >"$DEVZONE_STATE"
    }
}

fake_kubectl_isole() {
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"$BATS_TEST_TMPDIR/kubectl.log"
T="$BATS_TEST_TMPDIR"
case "$*" in
    *"config get-contexts -o name"*)
        echo "docker-desktop"
        ;;
    *"config current-context"*) cat "$T/ctx" 2>/dev/null ;;
    *"config use-context"*) echo "${@: -1}" >"$T/ctx" ;;
    *"config unset current-context"*) : >"$T/ctx" ;;
    *"config view"*)
        name=""
        for c in docker-desktop; do
            if [[ "$*" == *\"$c\"* ]]; then name="$c"; break; fi
        done
        if [[ "$*" == *'.cluster.server'* ]]; then echo "https://127.0.0.1:6443"; else echo "$name"; fi
        ;;
    *"get --raw /readyz"*)
        case "$*" in *"--context ${FAKE_UNREACHABLE:-none} "*) exit 1 ;; esac ;;
    *"create namespace"*) printf 'kind: Namespace\nmetadata:\n  name: devzone-postgres\n' ;;
    *"get namespace devzone-postgres"*) [ -f "$T/ns" ]; exit $? ;;
    *"get namespaces -l"*) ;;
    *"apply -f -"*)
        # Manifest received on stdin: logged in np (read by the test) and apply.log
        tee -a "$T/apply.log" >>"$T/np"
        touch "$T/ns" ;;
    *"get secret postgres-admin -o jsonpath"*) printf 'YWRtaW4tZXhpc3RhbnQ=' ;;
    *"get secret"*) [ -f "$T/secret" ]; exit $? ;;
    *"create secret"*) touch "$T/secret" ;;
    *"rollout status"*) ;;
    *"readyReplicas"*) echo 1 ;;
    *"exec -i postgres-0"*"-c SELECT count"*) echo 2 ;;
    *"exec -i postgres-0"*"-c SELECT datname"*) printf 'taskmanager taskmanager\n' ;;
    *"exec -i postgres-0"*) cat >>"$T/sql.log" ;;
    *"delete namespace devzone-postgres"*) rm -f "$T/ns" "$T/secret" ;;
    *"port-forward"*) exit 0 ;;
esac
exit 0
KUBE
    chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
    : >"$BATS_TEST_TMPDIR/kubectl.log"
}

fake_kind_isole() {
    printf '#!/usr/bin/env bash\necho "kind $*" >>"$BATS_TEST_TMPDIR/kind.log"\nexit 0\n' >"$BATS_TEST_TMPDIR/bin/kind"
    chmod +x "$BATS_TEST_TMPDIR/bin/kind"
    : >"$BATS_TEST_TMPDIR/kind.log"
}

@test "isolation : namespace isolated with NetworkPolicy devzone-meme-namespace" {
    fake_kubectl_isole
    fake_kind_isole
    printf 'kind-devzone\n' >"$BATS_TEST_TMPDIR/host.contexts"
    printf 'kind-devzone\thttps://127.0.0.1:6443\n' >"$BATS_TEST_TMPDIR/host.servers"

    # Tests the namespace_isolate function directly
    namespace_isolate devzone-postgres
    [ "$?" -eq 0 ]

    # Check that apply was called
    grep -q 'devzone-meme-namespace' "$BATS_TEST_TMPDIR/apply.log"

    # Check the content of the NetworkPolicy
    grep -q 'podSelector' "$BATS_TEST_TMPDIR/np" 
}

@test "isolation : allow then forbid access from a namespace to PostgreSQL" {
    fake_kubectl_isole
    fake_kind_isole
    printf 'kind-devzone\n' >"$BATS_TEST_TMPDIR/host.contexts"
    printf 'kind-devzone\thttps://127.0.0.1:6443\n' >"$BATS_TEST_TMPDIR/host.servers"

    # Tests the allow function
    active_on kind-devzone
    run allow devzone-postgres
    [ "$status" -eq 0 ]
    [[ "$output" == *"rule allowed to devzone-postgres"* ]] || false
    # The patch sent by allow: valid JSON, with the namespaceSelector
    p="$(grep 'patch networkpolicy' "$BATS_TEST_TMPDIR/kubectl.log" | head -n 1 | sed 's/^.*-p //')"
    python3 -c 'import json,sys; json.loads(sys.argv[1])' "$p"
    [[ "$p" == *namespaceSelector* ]] || false

    # Tests the forbid function
    run forbid devzone-postgres
    [ "$status" -eq 0 ]
    [[ "$output" == *"rule forbidden to devzone-postgres"* ]] || false
    # The patch of forbid: valid JSON, without namespaceSelector
    p="$(grep 'patch networkpolicy' "$BATS_TEST_TMPDIR/kubectl.log" | tail -n 1 | sed 's/^.*-p //')"
    python3 -c 'import json,sys; json.loads(sys.argv[1])' "$p"
    [[ "$p" != *namespaceSelector* ]] || false
}

@test "isolation : work context unchanged after devzone cluster" {
    fake_kubectl_isole
    fake_kind_isole
    printf 'kind-devzone\n' >"$BATS_TEST_TMPDIR/host.contexts"
    printf 'kind-devzone\thttps://127.0.0.1:6443\n' >"$BATS_TEST_TMPDIR/host.servers"

    # Fake nohup and fake sleep: the relay and the waits never go to the background
    cat >"$BATS_TEST_TMPDIR/bin/nohup" <<'NOHUP'
#!/usr/bin/env bash
echo "nohup $*" >>"$BATS_TEST_TMPDIR/nohup.log"
exit 0
NOHUP
    cat >"$BATS_TEST_TMPDIR/bin/sleep" <<'SLEEP'
#!/usr/bin/env bash
echo "sleep $*" >>"$BATS_TEST_TMPDIR/sleep.log"
exit 0
SLEEP
    chmod +x "$BATS_TEST_TMPDIR/bin/nohup" "$BATS_TEST_TMPDIR/bin/sleep"

    # Current kubectl context: kind-devzone (kept by the fake kubectl in $BATS_TEST_TMPDIR/ctx)
    printf 'kind-devzone\n' >"$BATS_TEST_TMPDIR/ctx"
    active_on kind-devzone

    run bash "$DEVZONE" cluster docker-desktop --yes </dev/null
    [ "$status" -eq 0 ]
    # The cluster choice is recorded
    grep -qx 'cluster=docker-desktop' "$DEVZONE_STATE"
    # The installation in the new cluster goes through the devzone context
    grep -q 'kubectl config set-context devzone --cluster=docker-desktop --user=docker-desktop' "$BATS_TEST_TMPDIR/kubectl.log"
    grep -q 'kubectl --context devzone -n devzone-postgres apply -f -' "$BATS_TEST_TMPDIR/kubectl.log"
    # The user context was not switched: no use-context, nor unset
    ! grep -q 'config use-context' "$BATS_TEST_TMPDIR/kubectl.log" || false
    ! grep -q 'config unset current-context' "$BATS_TEST_TMPDIR/kubectl.log" || false
    [ "$(cat "$BATS_TEST_TMPDIR/ctx")" = "kind-devzone" ]
    [ "$(kubectl config current-context)" = "kind-devzone" ]
}