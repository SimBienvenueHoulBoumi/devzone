#!/usr/bin/env bats
# Helm-direct installation (#559, step 7): chart_install renders the chart
# charts/devzone-<svc> of the code tree and upgrades the release on the devzone
# context; the objects already there are adopted first (release annotations and
# managed-by label), never recreated. helm and kubectl are fakes (commun-helm.bash
# and the kubectl below): no cluster is reached.

load commun-helm

setup() {
    LOG="$BATS_TEST_TMPDIR/kubectl.log"
    APPLIED="$BATS_TEST_TMPDIR/applied.yaml"
    EXISTANT="$BATS_TEST_TMPDIR/existant.txt"
    export LOG APPLIED EXISTANT
    : >"$LOG"
    : >"$EXISTANT"
    helm_fake_install
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"$LOG"
case "$*" in
    *"get -f"*) cat "$EXISTANT" ;;
    *"apply -f -"*) cat >"$APPLIED" ;;
esac
KUBE
    chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    # shellcheck disable=SC1091
    . "$BATS_TEST_DIRNAME/../../.devcontainer/chart-direct.sh"
}

@test "chart_install: the release upgraded with the values, the rendered objects applied in the namespace" {
    run chart_install postgres devzone-postgres size=7Gi
    [[ "$status" -eq 0 ]] || false
    [[ "$(cat "$BATS_TEST_TMPDIR/helm.log")" == *"upgrade --install postgres"*"--set size=7Gi"* ]] || false
    [[ "$(cat "$LOG")" == *"-n devzone-postgres apply -f -"* ]] || false
    [[ "$(cat "$APPLIED")" == *"storage: 7Gi"* ]] || false
}

@test "chart_install: objects already there are adopted (annotations and managed-by label), not recreated" {
    echo "statefulset.apps/postgres" >"$EXISTANT"
    run chart_install postgres devzone-postgres size=5Gi
    [[ "$status" -eq 0 ]] || false
    [[ "$(cat "$LOG")" == *"annotate statefulset.apps/postgres meta.helm.sh/release-name=postgres meta.helm.sh/release-namespace=devzone-postgres"* ]] || false
    [[ "$(cat "$LOG")" == *"label statefulset.apps/postgres app.kubernetes.io/managed-by=Helm"* ]] || false
    [[ "$(cat "$LOG")" != *"delete"* ]] || false
}

@test "chart_install: nothing to adopt on a fresh namespace" {
    run chart_install mysql devzone-mysql claim=donnees
    [[ "$status" -eq 0 ]] || false
    [[ "$(cat "$LOG")" != *annotate* ]] || false
    [[ "$(cat "$BATS_TEST_TMPDIR/helm.log")" == *"--set claim=donnees"* ]] || false
}

@test "chart_install: a service without chart is refused (exit 2) before anything runs" {
    run chart_install nosuch devzone-nosuch
    [[ "$status" -eq 2 ]] || false
    [[ "$output" == *"chart charts/devzone-nosuch missing"* ]] || false
    [[ ! -s "$BATS_TEST_TMPDIR/helm.log" ]] || false
}
