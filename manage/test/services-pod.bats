#!/usr/bin/env bats
# Services in the Kubernetes workspace pod (#528): status by the cluster DNS,
# apply that installs nothing, enable refused in the pod, services-admin.sh
# with a temporary administrator token. Fake kubectl, getent, devzone and
# tools: no cluster is touched.

setup() {
    load commun
    devzone_pod_pret
    kube_isole
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    DEVZONE="$RACINE/.devcontainer/devzone"
    ADMIN="$RACINE/.devcontainer/services-admin.sh"
    T="$BATS_TEST_TMPDIR"
    export HOME="$T/home"
    export DEVZONE_ROOT="$T/racine"
    export DEVZONE_STATE="$T/racine/.devzone.modules"
    export DEVZONE_INSTANCE=devzone
    export DEVZONE_WORKSPACE=kubernetes
    export GIT_CONFIG_NOSYSTEM=1
    mkdir -p "$HOME" "$DEVZONE_ROOT/workspace" "$T/bin"
    : >"$T/kubectl.log"
    cd "$T" || return 1

    # Fake kubectl: no cluster at all (the pod has no kubeconfig)
    cat >"$T/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"$BATS_TEST_TMPDIR/kubectl.log"
case "$*" in
    "config get-contexts -o name") exit 0 ;;
esac
exit 1
KUBE
    # Fake getent: a name resolves when it is listed in $T/dns
    cat >"$T/bin/getent" <<'GETENT'
#!/usr/bin/env bash
grep -qxF "${2:-}" "$BATS_TEST_TMPDIR/dns" 2>/dev/null
GETENT
    for tool in kind gh docker helm; do
        printf '#!/usr/bin/env bash\nexit 1\n' >"$T/bin/$tool"
    done
    chmod +x "$T/bin/"*
    export PATH="$T/bin:$PATH"
}

@test "status in the pod: gitlab on and resolved by the cluster DNS, active, never read from a failure marker" {
    printf 'gitlab=on\n' >"$DEVZONE_STATE"
    echo "gitlab-webservice-default.devzone-gitlab.svc" >"$T/dns"
    echo gitlab >"$DEVZONE_STATE-failed-gitlab"
    run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    line="$(printf '%s\n' "$output" | grep 'module gitlab' || true)"
    [[ "$line" == *"✔ module gitlab"*"active:"*"gitlab-webservice-default.devzone-gitlab.svc"* ]] || false
    [[ "$output" != *"✖ module"* ]] || false
    ! grep -q 'get namespace' "$T/kubectl.log" || false
}

@test "status in the pod: gitlab on and absent, the workstation command, no failure" {
    printf 'gitlab=on\n' >"$DEVZONE_STATE"
    : >"$T/dns"
    run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    line="$(printf '%s\n' "$output" | grep 'module gitlab' || true)"
    [[ "$line" == *"⚠ module gitlab"*"not in the cluster"*"devzone workspace services enable gitlab"* ]] || false
    [[ "$output" != *"✖ module"* ]] || false
}

@test "status in the pod: postgres and argocd off, optional with the workstation command" {
    printf 'gitlab=off\npostgres=off\nargocd=off\n' >"$DEVZONE_STATE"
    : >"$T/dns"
    run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"○ module postgres"*"devzone workspace services enable postgres"* ]] || false
    [[ "$output" == *"○ module argocd"*"devzone workspace services enable argocd"* ]] || false
    [[ "$output" != *"devzone enable postgres"* ]] || false
}

@test "status in the pod: postgres off but present in the cluster, active" {
    printf 'postgres=off\n' >"$DEVZONE_STATE"
    echo "postgres.devzone-postgres.svc" >"$T/dns"
    run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"✔ module postgres"*"active:"*"postgres.devzone-postgres.svc"* ]] || false
}

@test "status --json in the pod: active with the service, or the workstation command, echec null" {
    printf 'gitlab=on\npostgres=on\n' >"$DEVZONE_STATE"
    echo "postgres.devzone-postgres.svc" >"$T/dns"
    run bash "$DEVZONE" status --json
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | jq -r '.modules[] | select(.name=="postgres") | .state')" = "active: postgres.devzone-postgres.svc" ]
    [ "$(printf '%s\n' "$output" | jq -r '.modules[] | select(.name=="gitlab") | .state')" = "not in the cluster" ]
    [ "$(printf '%s\n' "$output" | jq -r '.modules[] | select(.name=="gitlab") | .command')" = "devzone workspace services enable gitlab" ]
    [ "$(printf '%s\n' "$output" | jq -r '.modules[] | select(.name=="gitlab") | .failed')" = "null" ]
}

@test "apply in the pod: services not installed, failure markers cleared, status 0" {
    printf 'gitlab=on\npostgres=on\nargocd=on\n' >"$DEVZONE_STATE"
    echo gitlab >"$DEVZONE_STATE-failed-gitlab"
    echo argocd >"$DEVZONE_STATE-failed-argocd"
    run bash "$DEVZONE" apply
    [ "$status" -eq 0 ]
    [[ "$output" == *"gitlab is installed from the workstation (devzone workspace services enable gitlab)"* ]] || false
    [[ "$output" == *"postgres is installed from the workstation"* ]] || false
    [[ "$output" == *"argocd is installed from the workstation"* ]] || false
    [[ "$output" != *"activation via installer"* ]] || false
    [ ! -f "$DEVZONE_STATE-failed-gitlab" ]
    [ ! -f "$DEVZONE_STATE-failed-argocd" ]
    ! grep -q 'get namespace' "$T/kubectl.log" || false
}

@test "enable gitlab in the pod: refused with the workstation command, state unchanged" {
    printf 'gitlab=off\n' >"$DEVZONE_STATE"
    run bash "$DEVZONE" enable gitlab
    [ "$status" -eq 2 ]
    [[ "$output" == *"devzone workspace services enable gitlab"* ]] || false
    grep -qx 'gitlab=off' "$DEVZONE_STATE"
    [ ! -f "$DEVZONE_STATE-failed-gitlab" ]
}

@test "disable postgres in the pod: refused with the workstation command" {
    printf 'postgres=on\n' >"$DEVZONE_STATE"
    run bash "$DEVZONE" disable postgres --yes
    [ "$status" -eq 2 ]
    [[ "$output" == *"devzone workspace services disable postgres"* ]] || false
    grep -qx 'postgres=on' "$DEVZONE_STATE"
}

@test "enable in the pod with DEVZONE_SERVICES_ADMIN=1: the installer runs" {
    printf 'postgres=off\n' >"$DEVZONE_STATE"
    export DEVZONE_SERVICES_ADMIN=1
    run bash "$DEVZONE" enable postgres --context nulle-part
    [[ "$output" != *"devzone workspace services enable"* ]] || false
    # The installer itself was reached: the unknown cluster is refused by it
    [[ "$output" == *"unknown or unreachable cluster"* ]] || false
}
