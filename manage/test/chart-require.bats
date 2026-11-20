#!/usr/bin/env bats
# chart_require (#554): a service whose chart charts/devzone-<svc> is absent or
# does not name itself devzone-<svc> is refused (code 2) before anything is
# applied. The entry points are sourced with stubs that only log: the log
# stays empty when the chart is refused.

setup() {
    RACINE="$BATS_TEST_TMPDIR/racine"
    LOG="$BATS_TEST_TMPDIR/log"
    export RACINE LOG
    mkdir -p "$RACINE/charts/devzone-postgres" "$RACINE/charts/devzone-mysql" "$RACINE/charts/devzone-argocd"
    : >"$LOG"
    printf 'name: devzone-postgres\n' >"$RACINE/charts/devzone-postgres/Chart.yaml"
    printf 'name: devzone-mysql\n' >"$RACINE/charts/devzone-mysql/Chart.yaml"
    # argocd: folder without Chart.yaml, so absent
    export CATALOGUE_ARGOCD_WIRED=1
    # shellcheck disable=SC1091
    . "$BATS_TEST_DIRNAME/../../.devcontainer/argocd/services.sh"
    # shellcheck disable=SC1091
    . "$BATS_TEST_DIRNAME/../../.devcontainer/argocd/catalog-argocd.sh"
    services_state_of() { echo on; }
    services_namespace_prepare() { echo "namespace $1" >>"$LOG"; }
    services_secret_postgres() { echo "secret postgres" >>"$LOG"; }
    services_secret_mysql() { echo "secret mysql" >>"$LOG"; }
    gitops_apply_application() { echo "apply $1" >>"$LOG"; }
    argocd_revision() { echo v1.0.0; }
    DEVZONE_REPO_URL=https://example.invalid/devzone.git
    SERVICES_LIST="postgres mysql"
}

@test "chart_require: a chart naming itself devzone-<svc> passes" {
    run chart_require postgres
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "chart_require: a chart named otherwise, or absent, is refused with code 2" {
    printf 'name: pg\n' >"$RACINE/charts/devzone-postgres/Chart.yaml"
    run chart_require postgres
    [ "$status" -eq 2 ]
    [[ "$output" == *"✖ postgres : chart charts/devzone-postgres missing or misnamed"* ]] || false
    run chart_require argocd
    [ "$status" -eq 2 ]
    [[ "$output" == *"✖ argocd : chart charts/devzone-argocd missing or misnamed"* ]] || false
}

@test "services_reconcile: a misnamed chart applies nothing and the other service goes on" {
    printf 'name: pg\n' >"$RACINE/charts/devzone-postgres/Chart.yaml"
    run services_reconcile
    [ "$status" -eq 2 ]
    [[ "$output" == *"✖ postgres : chart charts/devzone-postgres missing or misnamed"* ]] || false
    [ "$(grep -c postgres "$LOG")" -eq 0 ]
    grep -q 'apply devzone-mysql' "$LOG"
}

@test "services_application_apply: a misnamed chart declares no Application" {
    printf 'name: pg\n' >"$RACINE/charts/devzone-postgres/Chart.yaml"
    run services_application_apply postgres
    [ "$status" -eq 2 ]
    [ ! -s "$LOG" ]
}

@test "services_reconcile: correct charts go through the namespace, the secret, the Application" {
    SERVICES_LIST="postgres"
    run services_reconcile
    [ "$status" -eq 0 ]
    grep -q 'namespace postgres' "$LOG"
    grep -q 'secret postgres' "$LOG"
    grep -q 'apply devzone-postgres' "$LOG"
}

@test "catalogue_argocd_apply: a misnamed chart refuses before the Application" {
    printf 'name: pg\n' >"$RACINE/charts/devzone-postgres/Chart.yaml"
    run catalogue_argocd_apply postgres devzone-postgres postgres:16 5432 256Mi 5Gi
    [ "$status" -eq 2 ]
    [[ "$output" == *"✖ postgres : chart charts/devzone-postgres missing or misnamed"* ]] || false
    [ ! -s "$LOG" ]
}

@test "argocd_install: a chart absent is refused before any kubectl or helm call" {
    # shellcheck disable=SC1091
    . "$BATS_TEST_DIRNAME/../../manage/scripts/argocd-workspace.sh"
    # Stubs defined after the source: argocd-workspace.sh defines ak itself
    ak() { echo "ak $*" >>"$LOG"; }
    helm() { echo "helm $*" >>"$LOG"; }
    argocd_memory_ok() { return 0; }
    run argocd_install
    [ "$status" -eq 2 ]
    [[ "$output" == *"✖ argocd : chart charts/devzone-argocd missing or misnamed"* ]] || false
    [ ! -s "$LOG" ]
}
