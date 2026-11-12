#!/usr/bin/env bats
# Services in the Kubernetes workspace pod (#528): status by the cluster DNS,
# apply that installs nothing, enable refused in the pod, services-admin.sh
# with a temporary administrator token. Fake kubectl, getent, devzone and
# tools: no cluster is touched.

setup() {
    load commun
    relais_docker_isole
    kube_isole
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    DEVZONE="$RACINE/.devcontainer/devzone"
    ADMIN="$RACINE/.devcontainer/services-admin.sh"
    T="$BATS_TEST_TMPDIR"
    export HOME="$T/home"
    export DEVZONE_RACINE="$T/racine"
    export DEVZONE_ETAT="$T/racine/.devzone.modules"
    export DEVZONE_INSTANCE=devzone
    export DEVZONE_WORKSPACE=kubernetes
    export GIT_CONFIG_NOSYSTEM=1
    mkdir -p "$HOME" "$DEVZONE_RACINE/workspace" "$T/bin"
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
    printf 'gitlab=on\n' >"$DEVZONE_ETAT"
    echo "gitlab-webservice-default.devzone-gitlab.svc" >"$T/dns"
    echo gitlab >"$DEVZONE_ETAT-echec-gitlab"
    run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    line="$(printf '%s\n' "$output" | grep 'module gitlab' || true)"
    [[ "$line" == *"✔ module gitlab"*"active:"*"gitlab-webservice-default.devzone-gitlab.svc"* ]] || false
    [[ "$output" != *"✖ module"* ]] || false
    ! grep -q 'get namespace' "$T/kubectl.log" || false
}

@test "status in the pod: gitlab on and absent, the workstation command, no failure" {
    printf 'gitlab=on\n' >"$DEVZONE_ETAT"
    : >"$T/dns"
    run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    line="$(printf '%s\n' "$output" | grep 'module gitlab' || true)"
    [[ "$line" == *"⚠ module gitlab"*"not in the cluster"*"devzone workspace services enable gitlab"* ]] || false
    [[ "$output" != *"✖ module"* ]] || false
}

@test "status in the pod: postgres and argocd off, optional with the workstation command" {
    printf 'gitlab=off\npostgres=off\nargocd=off\n' >"$DEVZONE_ETAT"
    : >"$T/dns"
    run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"○ module postgres"*"devzone workspace services enable postgres"* ]] || false
    [[ "$output" == *"○ module argocd"*"devzone workspace services enable argocd"* ]] || false
    [[ "$output" != *"devzone activer postgres"* ]] || false
}

@test "status in the pod: postgres off but present in the cluster, active" {
    printf 'postgres=off\n' >"$DEVZONE_ETAT"
    echo "postgres.devzone-postgres.svc" >"$T/dns"
    run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"✔ module postgres"*"active:"*"postgres.devzone-postgres.svc"* ]] || false
}

@test "status --json in the pod: active with the service, or the workstation command, echec null" {
    printf 'gitlab=on\npostgres=on\n' >"$DEVZONE_ETAT"
    echo "postgres.devzone-postgres.svc" >"$T/dns"
    run bash "$DEVZONE" etat --json
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | jq -r '.modules[] | select(.nom=="postgres") | .etat')" = "active: postgres.devzone-postgres.svc" ]
    [ "$(printf '%s\n' "$output" | jq -r '.modules[] | select(.nom=="gitlab") | .etat')" = "not in the cluster" ]
    [ "$(printf '%s\n' "$output" | jq -r '.modules[] | select(.nom=="gitlab") | .commande')" = "devzone workspace services enable gitlab" ]
    [ "$(printf '%s\n' "$output" | jq -r '.modules[] | select(.nom=="gitlab") | .echec')" = "null" ]
}

@test "apply in the pod: services not installed, failure markers cleared, status 0" {
    printf 'gitlab=on\npostgres=on\nargocd=on\n' >"$DEVZONE_ETAT"
    echo gitlab >"$DEVZONE_ETAT-echec-gitlab"
    echo argocd >"$DEVZONE_ETAT-echec-argocd"
    run bash "$DEVZONE" appliquer
    [ "$status" -eq 0 ]
    [[ "$output" == *"gitlab is installed from the workstation (devzone workspace services enable gitlab)"* ]] || false
    [[ "$output" == *"postgres is installed from the workstation"* ]] || false
    [[ "$output" == *"argocd is installed from the workstation"* ]] || false
    [[ "$output" != *"activation via installer"* ]] || false
    [ ! -f "$DEVZONE_ETAT-echec-gitlab" ]
    [ ! -f "$DEVZONE_ETAT-echec-argocd" ]
    ! grep -q 'get namespace' "$T/kubectl.log" || false
}

@test "enable gitlab in the pod: refused with the workstation command, state unchanged" {
    printf 'gitlab=off\n' >"$DEVZONE_ETAT"
    run bash "$DEVZONE" activer gitlab
    [ "$status" -eq 2 ]
    [[ "$output" == *"devzone workspace services enable gitlab"* ]] || false
    grep -qx 'gitlab=off' "$DEVZONE_ETAT"
    [ ! -f "$DEVZONE_ETAT-echec-gitlab" ]
}

@test "disable postgres in the pod: refused with the workstation command" {
    printf 'postgres=on\n' >"$DEVZONE_ETAT"
    run bash "$DEVZONE" disable postgres --oui
    [ "$status" -eq 2 ]
    [[ "$output" == *"devzone workspace services disable postgres"* ]] || false
    grep -qx 'postgres=on' "$DEVZONE_ETAT"
}

@test "enable in the pod with DEVZONE_SERVICES_ADMIN=1: the installer runs" {
    printf 'postgres=off\n' >"$DEVZONE_ETAT"
    export DEVZONE_SERVICES_ADMIN=1
    run bash "$DEVZONE" activer postgres --contexte nulle-part
    [[ "$output" != *"devzone workspace services enable"* ]] || false
    # The installer itself was reached: the unknown cluster is refused by it
    [[ "$output" == *"cluster inconnu"* ]] || false
}

# ---- services-admin.sh: temporary administrator inside the pod ----

admin_setup() {
    export DEVZONE_SA_DIR="$T/sa"
    export DEVZONE_API_SERVER="https://kubernetes.default.svc:443"
    mkdir -p "$DEVZONE_SA_DIR"
    printf -- '-----BEGIN CERTIFICATE-----\nCA\n-----END CERTIFICATE-----\n' >"$DEVZONE_SA_DIR/ca.crt"
    : >"$T/devzone.log"
    # Fake devzone: logs its arguments, keeps a copy of the kubeconfig and of
    # the state as seen during the run
    cat >"$T/bin/devzone" <<'DZ'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
echo "devzone $*" >>"$T/devzone.log"
if [ "${1:-}" != relais-arreter ] && [ "${2:-}" != relais-arreter ]; then
    [ -n "${KUBECONFIG:-}" ] && [ -f "$KUBECONFIG" ] && cp "$KUBECONFIG" "$T/kubeconfig.copy"
    cp "$DEVZONE_ETAT" "$T/etat.during" 2>/dev/null || true
    printf 'admin=%s kube=%s\n' "${DEVZONE_SERVICES_ADMIN:-}" "${DEVZONE_KUBE_CONFIG:-}" >"$T/devzone.env"
    [ "${FAKE_DEVZONE_FAIL:-0}" = 1 ] && exit 1
fi
exit 0
DZ
    chmod +x "$T/bin/devzone"
}

@test "services-admin.sh enable: kubeconfig with the token, two contexts, installer run, everything cleaned" {
    admin_setup
    printf 'cluster=docker-desktop\npostgres=off\n' >"$DEVZONE_ETAT"
    run bash -c 'printf "SECRET-TOKEN\n" | bash "$0" enable postgres --contexte x' "$ADMIN"
    [ "$status" -eq 0 ]
    [[ "$output" != *"SECRET-TOKEN"* ]] || false
    grep -q '^devzone enable postgres --contexte x$' "$T/devzone.log"
    grep -q '^devzone postgres relais-arreter$' "$T/devzone.log"
    grep -q 'token: SECRET-TOKEN' "$T/kubeconfig.copy"
    grep -q 'name: devzone-admin' "$T/kubeconfig.copy"
    grep -q 'name: devzone$' "$T/kubeconfig.copy"
    grep -q 'current-context: devzone-admin' "$T/kubeconfig.copy"
    grep -q 'server: https://kubernetes.default.svc:443' "$T/kubeconfig.copy"
    grep -q 'admin=1 kube=' "$T/devzone.env"
    grep -qx 'cluster=devzone-admin' "$T/etat.during"
    # Afterwards: cluster line as before, kubeconfig removed
    grep -qx 'cluster=docker-desktop' "$DEVZONE_ETAT"
    [ -z "$(ls "${TMPDIR:-/tmp}"/devzone-services-admin.* 2>/dev/null)" ]
}

@test "services-admin.sh: no cluster line before, none after; disable passes --oui" {
    admin_setup
    printf 'argocd=on\n' >"$DEVZONE_ETAT"
    run bash -c 'printf "tok\n" | bash "$0" disable argocd --oui' "$ADMIN"
    [ "$status" -eq 0 ]
    grep -q '^devzone disable argocd --oui$' "$T/devzone.log"
    ! grep -q '^cluster=' "$DEVZONE_ETAT" || false
}

@test "services-admin.sh: installer failure, code kept and cleanup done" {
    admin_setup
    printf 'cluster=kind-devzone\n' >"$DEVZONE_ETAT"
    export FAKE_DEVZONE_FAIL=1
    run bash -c 'printf "tok\n" | bash "$0" enable gitlab' "$ADMIN"
    [ "$status" -eq 1 ]
    grep -q '^devzone gitlab relais-arreter$' "$T/devzone.log"
    grep -qx 'cluster=kind-devzone' "$DEVZONE_ETAT"
    [ -z "$(ls "${TMPDIR:-/tmp}"/devzone-services-admin.* 2>/dev/null)" ]
}

@test "services-admin.sh: refused outside the pod, for an unknown service, with an empty token" {
    admin_setup
    run bash -c 'printf "tok\n" | DEVZONE_WORKSPACE= bash "$0" enable postgres' "$ADMIN"
    [ "$status" -eq 2 ]
    [[ "$output" == *"only in the Kubernetes workspace pod"* ]] || false
    run bash -c 'printf "tok\n" | bash "$0" enable mysql' "$ADMIN"
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown service: mysql"* ]] || false
    run bash -c 'printf "" | bash "$0" enable postgres' "$ADMIN"
    [ "$status" -eq 2 ]
    [[ "$output" == *"empty token"* ]] || false
    [ ! -s "$T/devzone.log" ]
}
