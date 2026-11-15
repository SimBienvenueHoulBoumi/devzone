#!/usr/bin/env bats
# Module llm in the Kubernetes workspace pod (#586): status by the cluster DNS,
# enable refused in the pod, services-admin.sh enable llm. Same fakes as
# services-pod.bats: no cluster is touched.

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

admin_setup() {
    export DEVZONE_SA_DIR="$T/sa"
    export DEVZONE_API_SERVER="https://kubernetes.default.svc:443"
    mkdir -p "$DEVZONE_SA_DIR"
    printf -- '-----BEGIN CERTIFICATE-----\nCA\n-----END CERTIFICATE-----\n' >"$DEVZONE_SA_DIR/ca.crt"
    : >"$T/devzone.log"
    # services-admin.sh runs the devzone beside it (#591): copy of the script
    # and of its state helpers in $T/pod, fake devzone next to them
    mkdir -p "$T/pod"
    cp "$RACINE/.devcontainer/services-admin.sh" "$RACINE/.devcontainer/etat.sh" \
        "$RACINE/.devcontainer/etat-verrou.sh" "$T/pod/"
    ADMIN="$T/pod/services-admin.sh"
    # Fake devzone beside the script: logs its arguments, keeps a copy of the
    # kubeconfig and of the state as seen during the run
    cat >"$T/pod/devzone" <<'DZ'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
echo "devzone $*" >>"$T/devzone.log"
if [ "${1:-}" != relay-stop ] && [ "${2:-}" != relay-stop ]; then
    [ -n "${KUBECONFIG:-}" ] && [ -f "$KUBECONFIG" ] && cp "$KUBECONFIG" "$T/kubeconfig.copy"
    cp "$DEVZONE_ETAT" "$T/etat.during" 2>/dev/null || true
    printf 'admin=%s kube=%s\n' "${DEVZONE_SERVICES_ADMIN:-}" "${DEVZONE_KUBE_CONFIG:-}" >"$T/devzone.env"
    [ "${FAKE_DEVZONE_FAIL:-0}" = 1 ] && exit 1
fi
exit 0
DZ
    chmod +x "$T/pod/devzone"
    # Another fake devzone on the PATH: must never be called
    cat >"$T/bin/devzone" <<'DZPATH'
#!/usr/bin/env bash
echo "PATH devzone $*" >>"$BATS_TEST_TMPDIR/path-devzone.log"
exit 0
DZPATH
    chmod +x "$T/bin/devzone"
}

@test "status in the pod: llm off, optional; present in the cluster, active" {
    printf 'llm=off\n' >"$DEVZONE_ETAT"
    : >"$T/dns"
    run bash "$DEVZONE"
    [[ "$output" == *"○ module llm"*"devzone workspace services enable llm"* ]] || false
    echo "llm.devzone-llm.svc" >"$T/dns"
    run bash "$DEVZONE"
    [[ "$output" == *"✔ module llm"*"active:"*"llm.devzone-llm.svc"* ]] || false
}

@test "enable llm in the pod: refused with the workstation command" {
    printf 'llm=off\n' >"$DEVZONE_ETAT"
    run bash "$DEVZONE" enable llm
    [ "$status" -eq 2 ]
    [[ "$output" == *"devzone workspace services enable llm"* ]] || false
    grep -qx 'llm=off' "$DEVZONE_ETAT"
}

@test "services-admin.sh enable llm --preset light: devzone enable llm, relay stopped" {
    admin_setup
    printf 'cluster=kind-devzone\nllm=off\n' >"$DEVZONE_ETAT"
    run bash -c 'printf "SECRET-TOKEN\n" | bash "$0" enable llm --preset light' "$ADMIN"
    [ "$status" -eq 0 ]
    grep -q '^devzone enable llm --preset light$' "$T/devzone.log"
    grep -q '^devzone llm relay-stop$' "$T/devzone.log"
    [ ! -e "$T/path-devzone.log" ]
}
