#!/usr/bin/env bats
# Services of the container held by Argo CD (#559, step 5): enable and disable
# of postgres and mysql with the module argocd held go through Argo CD (exit
# 0), the other cases go on as before (exit 3); argocd off releases the
# Applications with their finalizer dropped first, so the resources stay.
# The hook is sourced with stubs that log the calls: no cluster is reached.

setup() {
    DEVZONE_ROOT="$BATS_TEST_TMPDIR/racine"
    LOG="$BATS_TEST_TMPDIR/log"
    export DEVZONE_ROOT LOG
    mkdir -p "$DEVZONE_ROOT/.devcontainer/catalog/mysql"
    cp "$BATS_TEST_DIRNAME/../../.devcontainer/catalog/mysql/app.conf" "$DEVZONE_ROOT/.devcontainer/catalog/mysql/app.conf"
    : >"$LOG"
    HELD=yes
    APP_PRESENT=yes
    APPS_PRESENT=""
    PVCS=""
    RECONCILE_RC=0
    # shellcheck disable=SC1091
    . "$BATS_TEST_DIRNAME/../../.devcontainer/argocd/services-hook.sh"
    catalogue_argocd_load() { :; }
    catalogue_argocd_active() { echo "active $1" >>"$LOG"; [ "$HELD" = yes ]; }
    catalogue_argocd_application_exists() { [ "$APP_PRESENT" = yes ]; }
    services_note() { echo "note $1 $2" >>"$LOG"; }
    services_reconcile() { echo "reconcile" >>"$LOG"; return "$RECONCILE_RC"; }
    hook_wait() { echo "wait $1" >>"$LOG"; }
    hook_relay() { echo "relay $1" >>"$LOG"; }
    gitops_delete_application() { echo "delete $1 ${2:-cascade}" >>"$LOG"; }
    argocd_revision() { echo v1.0.0; }
    argocd_kubectl() {
        local a last=""
        echo "kubectl $*" >>"$LOG"
        for a in "$@"; do last="$a"; done
        case "$*" in
            *"get application.argoproj.io"*)
                case " $APPS_PRESENT " in *" $last "*) return 0 ;; *) return 1 ;; esac
                ;;
            *"get pvc"*)
                for a in $PVCS; do echo "$a"; done
                ;;
            *"get secret"*) return 1 ;;
        esac
        return 0
    }
}

@test "postgres on, module held: through Argo CD, exit 0, in order" {
    run hook_main postgres on
    [[ "$status" -eq 0 ]] || false
    [[ "$(cat "$LOG")" == "$(printf 'active postgres\nnote postgres on\nreconcile\nwait postgres\nrelay postgres')" ]] || false
}

@test "postgres on, module not held: exit 3, helm direct as before" {
    HELD=no
    run hook_main postgres on
    [[ "$status" -eq 3 ]] || false
    [[ "$(cat "$LOG")" == "active postgres" ]] || false
}

@test "a failing reconcile is a failure (exit 1), no wait and no relay" {
    RECONCILE_RC=1
    run hook_main mysql on
    [[ "$status" -eq 1 ]] || false
    [[ "$(cat "$LOG")" != *relay* ]] || false
    [[ "$(cat "$LOG")" != *wait* ]] || false
}

@test "gitlab is not held by this hook: exit 3, nothing logged" {
    run hook_main gitlab on
    [[ "$status" -eq 3 ]] || false
    [[ ! -s "$LOG" ]] || false
}

@test "postgres off with its Application: [services] off, Application deleted with cascade, exit 3" {
    run hook_main postgres off
    [[ "$status" -eq 3 ]] || false
    [[ "$(cat "$LOG")" == "$(printf 'note postgres off\ndelete devzone-postgres cascade')" ]] || false
}

@test "postgres off without Application: exit 3, nothing deleted" {
    APP_PRESENT=no
    run hook_main postgres off
    [[ "$status" -eq 3 ]] || false
    [[ ! -s "$LOG" ]] || false
}

@test "argocd off: finalizers dropped before the keep deletion, gitlab kept, mysql absent" {
    APPS_PRESENT="devzone-postgres devzone-gitlab"
    run hook_main argocd off
    [[ "$status" -eq 3 ]] || false
    [[ "$(grep -n 'patch application.argoproj.io devzone-postgres' "$LOG" | cut -d: -f1)" -lt "$(grep -n '^delete devzone-postgres keep' "$LOG" | cut -d: -f1)" ]] || false
    [[ "$(cat "$LOG")" == *"delete devzone-gitlab keep"* ]] || false
    [[ "$(cat "$LOG")" == *"note postgres off"* ]] || false
    [[ "$(cat "$LOG")" != *"delete devzone-mysql"* ]] || false
    [[ "$(cat "$LOG")" != *"patch application.argoproj.io devzone-mysql"* ]] || false
    [[ "$(cat "$LOG")" != *"delete devzone-gitlab cascade"* ]] || false
}

@test "services_chart_mysql: values of app.conf and the claim of the one existing volume" {
    PVCS="donnees-mysql-0"
    run services_chart_mysql
    [[ "$status" -eq 0 ]] || false
    [[ "$output" == "image=mysql:8.4 port=3306 memory=1Gi size=5Gi claim=donnees" ]] || false
}

@test "services_chart_mysql: no volume, chart defaults" {
    run services_chart_mysql
    [[ "$status" -eq 0 ]] || false
    [[ "$output" == "image=mysql:8.4 port=3306 memory=1Gi size=5Gi" ]] || false
}

@test "services_chart_mysql: several volumes refused (exit 2)" {
    PVCS="a-mysql-0 b-mysql-0"
    run services_chart_mysql
    [[ "$status" -eq 2 ]] || false
}

@test "services_secret_postgres: created apart, mirrored with mode 600, never printed" {
    run services_secret_postgres
    [[ "$status" -eq 0 ]] || false
    [[ -z "$output" ]] || false
    [[ "$(cat "$LOG")" == *"create secret generic postgres-admin"* ]] || false
    [[ -s "$DEVZONE_ROOT/workspace/.postgres/admin-password" ]] || false
    [[ "$(stat -c %a "$DEVZONE_ROOT/workspace/.postgres/admin-password")" == 600 ]] || false
}
