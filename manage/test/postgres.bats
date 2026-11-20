#!/usr/bin/env bats
# Module postgres (#280) and devzone cluster (cluster.sh): cluster choice,
# installation, databases per project, uninstall, cluster change. Fake kubectl,
# kind, openssl and nohup in the PATH: no cluster touched. kubectl keeps its
# state in files under $BATS_TEST_TMPDIR and logs its arguments (kubectl.log),
# and what it receives on stdin (apply.log, sql.log).

setup() {
    load commun
    load commun-helm
    kind_vide
    kube_isole
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    POSTGRES="$BATS_TEST_DIRNAME/../../.devcontainer/postgres/postgres.sh"
    export HOME="$BATS_TEST_TMPDIR/home"
    export DEVZONE_RACINE="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_ETAT="$BATS_TEST_TMPDIR/modules"
    export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
    export KIND_CLUSTERS="$BATS_TEST_TMPDIR/clusters"
    SECRETS="$DEVZONE_RACINE/workspace/.postgres"
    mkdir -p "$HOME" "$DEVZONE_RACINE/workspace" "$BATS_TEST_TMPDIR/bin"
    : >"$KIND_CLUSTERS"
    # Visible host cluster (kubernetes module active): docker-desktop
    : >"$DEVZONE_KUBE_HOTE"

    cat >"$BATS_TEST_TMPDIR/bin/kind" <<'KIND'
#!/usr/bin/env bash
echo "kind $*" >>"$BATS_TEST_TMPDIR/kind.log"
case "$1 $2" in
    "get clusters") cat "$KIND_CLUSTERS" ;;
    "create cluster") echo "${4:-}" >>"$KIND_CLUSTERS" ;;
    "delete cluster") grep -vx "${4:-}" "$KIND_CLUSTERS" >"$KIND_CLUSTERS.tmp" || true; mv "$KIND_CLUSTERS.tmp" "$KIND_CLUSTERS" ;;
esac
KIND
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"$BATS_TEST_TMPDIR/kubectl.log"
T="$BATS_TEST_TMPDIR"
case "$*" in
    *"config get-contexts -o name"*) echo "docker-desktop" ;;
    *"config view"*)
        name=""
        for c in docker-desktop kind-devzone; do
            if [[ "$*" == *\"$c\"* ]]; then name="$c"; break; fi
        done
        if [[ "$*" == *'.cluster.server'* ]]; then echo "https://127.0.0.1:6443"; else echo "$name"; fi
        ;;
    *"get --raw /readyz"*)
        case "$*" in *"--context ${FAUX_INJOIGNABLE:-aucun} "*) exit 1 ;; esac ;;
    *"get namespace devzone-postgres"*) [ -f "$T/ns" ]; exit $? ;;
    *"get namespaces -l"*) [ -z "${FAUX_OTHER_NS:-}" ] || echo "namespace/autre" ;;
    *"create namespace"*) printf 'kind: Namespace\nmetadata:\n  name: devzone-postgres\n' ;;
    *"apply -f -"*)
        cat >>"$T/apply.log"
        touch "$T/ns" ;;
    *"get secret postgres-admin -o jsonpath"*) printf 'YWRtaW4tZXhpc3Rpbmc=' ;;
    *"get secret postgres-admin"*) [ -f "$T/secret" ]; exit $? ;;
    *"create secret generic postgres-admin"*) touch "$T/secret" ;;
    *"rollout status"*) ;;
    *"readyReplicas"*) echo 1 ;;
    *"exec -i postgres-0"*"-c SELECT count"*) echo 2 ;;
    *"exec -i postgres-0"*"-c SELECT datname"*) printf 'taskmanager taskmanager\n' ;;
    *"exec -i postgres-0"*) cat >>"$T/sql.log" ;;
    *"delete namespace devzone-postgres"*) rm -f "$T/ns" "$T/secret" ;;
    *"port-forward"*) exec sleep 300 ;;
esac
exit 0
KUBE
    # Different password at each call: a kept password is seen
    cat >"$BATS_TEST_TMPDIR/bin/openssl" <<'SSL'
#!/usr/bin/env bash
n="$(cat "$BATS_TEST_TMPDIR/openssl.n" 2>/dev/null || echo 0)"
n=$((n + 1)); echo "$n" >"$BATS_TEST_TMPDIR/openssl.n"
echo "pwsecret$n"
SSL
    # nohup: the logged relay, then a sleep killed by relay-stop
    cat >"$BATS_TEST_TMPDIR/bin/nohup" <<'NOHUP'
#!/usr/bin/env bash
echo "nohup $*" >>"$BATS_TEST_TMPDIR/nohup.log"
exec sleep 300
NOHUP
    chmod +x "$BATS_TEST_TMPDIR"/bin/*
    helm_fake_install
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

teardown() {
    bash "$POSTGRES" relay-stop >/dev/null 2>&1 || true
}

active_on() {
    printf 'postgres=on\ncluster=%s\n' "$1" >"$DEVZONE_ETAT"
    touch "$BATS_TEST_TMPDIR/ns" "$BATS_TEST_TMPDIR/secret"
}

wait_nohup() {
    local pattern="$1" i=0
    while [ "$i" -lt 50 ]; do
        if grep -q -- "$pattern" "$BATS_TEST_TMPDIR/nohup.log" 2>/dev/null; then
            return 0
        fi
        i=$((i + 1))
        sleep 0.1
    done
    echo "nohup.log: line missing after 5 s: $pattern" >&2
    return 1
}

@test "postgres: module known, disabled by default" {
    run bash "$DEVZONE"
    [[ "$output" == *"○ module postgres"*"devzone enable postgres"* ]] || false
}

@test "enable without a terminal: dedicated kind created, PostgreSQL applied, relay started" {
    run bash "$DEVZONE" enable postgres </dev/null
    [ "$status" -eq 0 ]
    grep -qx 'cluster=kind-devzone' "$DEVZONE_ETAT"
    grep -q 'kind create cluster --name devzone' "$BATS_TEST_TMPDIR/kind.log"
    grep -q 'kubectl config set-context devzone --cluster=kind-devzone --user=kind-devzone' "$BATS_TEST_TMPDIR/kubectl.log"
    grep -q 'kubectl --context devzone -n devzone-postgres create secret generic postgres-admin' "$BATS_TEST_TMPDIR/kubectl.log"
    grep -q 'image: postgres:16' "$BATS_TEST_TMPDIR/apply.log"
    grep -q 'storage: 5Gi' "$BATS_TEST_TMPDIR/apply.log"
    wait_nohup 'port-forward --address 127.0.0.1'
    grep -q 'port-forward --address 127.0.0.1' "$BATS_TEST_TMPDIR/nohup.log"
    wait_nohup 'kind-devzone devzone-postgres svc/postgres 5432:5432$'
    grep -q 'kind-devzone devzone-postgres svc/postgres 5432:5432$' "$BATS_TEST_TMPDIR/nohup.log"
    [[ "$output" == *"127.0.0.1:5432"* ]] || false
}

@test "enable --context docker-desktop: no kind, everything on this context" {
    run bash "$DEVZONE" enable postgres --context docker-desktop </dev/null
    [ "$status" -eq 0 ]
    grep -qx 'cluster=docker-desktop' "$DEVZONE_ETAT"
    ! grep -q 'create cluster' "$BATS_TEST_TMPDIR/kind.log" 2>/dev/null || false
    grep -q 'kubectl config set-context devzone --cluster=docker-desktop --user=docker-desktop' "$BATS_TEST_TMPDIR/kubectl.log"
    grep -q 'kubectl --context devzone -n devzone-postgres apply -f -' "$BATS_TEST_TMPDIR/kubectl.log"
    ! grep -q 'kind-devzone' "$BATS_TEST_TMPDIR/kubectl.log" || false
}

@test "enable --context unknown or unreachable: refused with code 2, nothing installed, module disabled" {
    run bash "$DEVZONE" enable postgres --context inconnu </dev/null
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown or unreachable cluster: inconnu"* ]] || false
    grep -qx 'postgres=off' "$DEVZONE_ETAT"
    ! grep -q '^cluster=' "$DEVZONE_ETAT" || false
    [ ! -f "$BATS_TEST_TMPDIR/apply.log" ]

    FAUX_INJOIGNABLE=docker-desktop run bash "$DEVZONE" enable postgres --context docker-desktop </dev/null
    [ "$status" -eq 2 ]
}

@test "enable without kubernetes module: only the dedicated kind is possible" {
    rm -f "$DEVZONE_KUBE_HOTE"
    run bash "$DEVZONE" enable postgres --context docker-desktop </dev/null
    [ "$status" -eq 2 ]
}

@test "enable in a terminal: menu, choice 1 = host cluster" {
    DEVZONE_INTERACTIF=1 run bash "$DEVZONE" enable postgres <<<"1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"1) docker-desktop"*"2) kind-devzone"* ]] || false
    grep -qx 'cluster=docker-desktop' "$DEVZONE_ETAT"
}

@test "enable in a terminal: Enter = host cluster; choice out of the list refused" {
    DEVZONE_INTERACTIF=1 run bash "$DEVZONE" enable postgres <<<""
    [ "$status" -eq 0 ]
    grep -qx 'cluster=docker-desktop' "$DEVZONE_ETAT"

    rm -f "$DEVZONE_ETAT"
    DEVZONE_INTERACTIF=1 run bash "$DEVZONE" enable postgres <<<"9"
    [ "$status" -eq 2 ]
    grep -qx 'postgres=off' "$DEVZONE_ETAT"
}

@test "enable --context other than the chosen cluster: refused, devzone cluster shown" {
    printf 'cluster=kind-devzone\n' >"$DEVZONE_ETAT"
    run bash "$DEVZONE" enable postgres --context docker-desktop </dev/null
    [ "$status" -eq 2 ]
    [[ "$output" == *"devzone cluster docker-desktop"* ]] || false
}

@test "existing admin secret: never regenerated, copied as 600 without being displayed" {
    touch "$BATS_TEST_TMPDIR/secret"
    printf 'cluster=kind-devzone\n' >"$DEVZONE_ETAT"
    run bash "$POSTGRES" install
    [ "$status" -eq 0 ]
    ! grep -q 'create secret' "$BATS_TEST_TMPDIR/kubectl.log" || false
    [ "$(cat "$SECRETS/admin-password")" = admin-existing ]
    [ "$(stat -c %a "$SECRETS/admin-password" 2>/dev/null || stat -f %Lp "$SECRETS/admin-password")" = 600 ]
    [[ "$output" != *admin-existing* ]] || false
}

@test "create: invalid or reserved name refused (code 2)" {
    active_on kind-devzone
    for name in Task 1abc "a-b" "x;drop" postgres; do
        run bash "$POSTGRES" create "$name"
        [ "$status" -eq 2 ]
    done
    [ ! -f "$BATS_TEST_TMPDIR/sql.log" ]
}

@test "create: role, database, access closed to others, .env 600, password never displayed" {
    active_on docker-desktop
    run bash "$POSTGRES" create taskmanager
    [ "$status" -eq 0 ]
    grep -q "CREATE ROLE taskmanager LOGIN" "$BATS_TEST_TMPDIR/sql.log"
    grep -q "CREATE DATABASE taskmanager OWNER taskmanager" "$BATS_TEST_TMPDIR/sql.log"
    grep -q "REVOKE CONNECT ON DATABASE taskmanager FROM PUBLIC" "$BATS_TEST_TMPDIR/sql.log"
    grep -q 'kubectl --context devzone -n devzone-postgres exec -i postgres-0' "$BATS_TEST_TMPDIR/kubectl.log"
    ! grep -q pwsecret "$BATS_TEST_TMPDIR/kubectl.log" || false
    grep -qx 'DB_URL=jdbc:postgresql://127.0.0.1:5432/taskmanager' "$SECRETS/taskmanager.env"
    grep -qx 'DB_USER=taskmanager' "$SECRETS/taskmanager.env"
    grep -qx 'DB_PASSWORD=pwsecret1' "$SECRETS/taskmanager.env"
    [ "$(stat -c %a "$SECRETS/taskmanager.env" 2>/dev/null || stat -f %Lp "$SECRETS/taskmanager.env")" = 600 ]
    [[ "$output" != *pwsecret* ]] || false
    [[ "$output" == *"$SECRETS/taskmanager.env"* ]] || false
}

@test "create again: password kept; --new-password: changed" {
    active_on kind-devzone
    bash "$POSTGRES" create taskmanager
    bash "$POSTGRES" create taskmanager
    grep -qx 'DB_PASSWORD=pwsecret1' "$SECRETS/taskmanager.env"
    bash "$POSTGRES" create taskmanager --new-password
    grep -qx 'DB_PASSWORD=pwsecret2' "$SECRETS/taskmanager.env"
}

@test "create, --new-password, delete: .password follows the accounts" {
    active_on docker-desktop
    bash "$POSTGRES" create taskmanager
    grep -q $'^postgres:taskmanager\t127.0.0.1:5432/taskmanager\ttaskmanager\tpwsecret1$' "$DEVZONE_RACINE/.password"
    bash "$POSTGRES" create taskmanager --new-password
    grep -q $'^postgres:taskmanager\t127.0.0.1:5432/taskmanager\ttaskmanager\tpwsecret2$' "$DEVZONE_RACINE/.password"
    bash "$POSTGRES" delete taskmanager --yes
    [ ! -e "$DEVZONE_RACINE/.password" ]
}

@test "install, uninstall: .password follows the admin account" {
    run bash "$DEVZONE" enable postgres --context docker-desktop </dev/null
    [ "$status" -eq 0 ]
    grep -q $'^postgres\t127.0.0.1:5432\tpostgres\t' "$DEVZONE_RACINE/.password"
    run bash "$DEVZONE" disable postgres </dev/null
    [ "$status" -eq 0 ]
    [ ! -e "$DEVZONE_RACINE/.password" ]
}

@test "create, list, psql: module disabled → clear refusal" {
    printf 'cluster=kind-devzone\n' >"$DEVZONE_ETAT"
    run bash "$POSTGRES" create taskmanager
    [ "$status" -eq 2 ]
    [[ "$output" == *"devzone enable postgres"* ]] || false
    rm -f "$DEVZONE_ETAT"
    run bash "$POSTGRES" list
    [ "$status" -eq 2 ]
}

@test "list: databases and owners" {
    active_on kind-devzone
    run bash "$DEVZONE" postgres list
    [ "$status" -eq 0 ]
    [[ "$output" == *"taskmanager"*"owner taskmanager"* ]] || false
}

@test "delete: without a terminal or --yes refused; --yes: database, role and .env deleted" {
    active_on kind-devzone
    bash "$POSTGRES" create taskmanager
    : >"$BATS_TEST_TMPDIR/sql.log"
    run bash "$POSTGRES" delete taskmanager </dev/null
    [ "$status" -eq 2 ]
    [ ! -s "$BATS_TEST_TMPDIR/sql.log" ]
    run bash "$POSTGRES" delete taskmanager --yes
    [ "$status" -eq 0 ]
    grep -q "DROP DATABASE IF EXISTS taskmanager WITH (FORCE)" "$BATS_TEST_TMPDIR/sql.log"
    grep -q "DROP ROLE IF EXISTS taskmanager" "$BATS_TEST_TMPDIR/sql.log"
    [ ! -f "$SECRETS/taskmanager.env" ]
}

@test "delete in a terminal: Enter = abort" {
    active_on kind-devzone
    DEVZONE_INTERACTIF=1 run bash "$POSTGRES" delete taskmanager <<<""
    [ "$status" -eq 0 ]
    [[ "$output" == *"Abandon"* ]] || false
    [ ! -f "$BATS_TEST_TMPDIR/sql.log" ]
}

@test "disable: namespace and secrets deleted, empty dedicated kind deleted" {
    echo devzone >"$KIND_CLUSTERS"
    active_on kind-devzone
    mkdir -p "$SECRETS"
    run bash "$DEVZONE" disable postgres </dev/null
    [ "$status" -eq 0 ]
    grep -q 'kubectl config set-context devzone --cluster=kind-devzone --user=kind-devzone' "$BATS_TEST_TMPDIR/kubectl.log"
    # Namespace deleted by the administrator (limited account has no right)
    grep -q -- '--context kind-devzone delete namespace devzone-postgres' "$BATS_TEST_TMPDIR/kubectl.log"
    grep -q 'kind delete cluster --name devzone' "$BATS_TEST_TMPDIR/kind.log"
    [ ! -d "$SECRETS" ]
    grep -qx 'postgres=off' "$DEVZONE_ETAT"
}

@test "disable: dedicated kind kept if it carries another service; host cluster never deleted" {
    echo devzone >"$KIND_CLUSTERS"
    active_on kind-devzone
    FAUX_OTHER_NS=1 run bash "$DEVZONE" disable postgres </dev/null
    ! grep -q 'kind delete' "$BATS_TEST_TMPDIR/kind.log" || false

    active_on docker-desktop
    run bash "$DEVZONE" disable postgres </dev/null
    grep -q 'kubectl config set-context devzone --cluster=docker-desktop --user=docker-desktop' "$BATS_TEST_TMPDIR/kubectl.log"
    # Namespace deleted by the administrator (limited account has no right)
    grep -q -- '--context docker-desktop delete namespace devzone-postgres' "$BATS_TEST_TMPDIR/kubectl.log"
    ! grep -q 'kind delete' "$BATS_TEST_TMPDIR/kind.log" || false
}

@test "disable in a terminal: confirmation, Enter = nothing deleted" {
    active_on kind-devzone
    DEVZONE_INTERACTIF=1 run bash "$DEVZONE" disable postgres <<<""
    [[ "$output" == *"Abandon"* ]] || false
    grep -qx 'postgres=on' "$DEVZONE_ETAT"
    ! grep -q 'delete namespace' "$BATS_TEST_TMPDIR/kubectl.log" 2>/dev/null || false
}

@test "status: disabled, ready on the cluster with the number of databases, relay stopped" {
    run bash "$POSTGRES" status
    [ "$output" = "désactivé" ]
    active_on docker-desktop
    run bash "$POSTGRES" status
    [ "$output" = "prêt sur docker-desktop, relais arrêté : devzone apply" ]
    bash "$POSTGRES" relay-start
    run bash "$POSTGRES" status
    [ "$output" = "prêt sur docker-desktop : 127.0.0.1:5432, 2 base(s)" ]
    run bash "$DEVZONE"
    [[ "$output" == *"✔ module postgres"*"prêt sur docker-desktop"* ]] || false
}

@test "relay: started only once, stopped by relay-stop" {
    active_on kind-devzone
    bash "$POSTGRES" relay-start
    bash "$POSTGRES" relay-start
    wait_nohup 'port-forward'
    [ "$(grep -c port-forward "$BATS_TEST_TMPDIR/nohup.log")" -eq 1 ]
    pid="$(cat "$SECRETS/relais.pid")"
    kill -0 "$pid"
    bash "$POSTGRES" relay-stop
    sleep 0.2
    ! kill -0 "$pid" 2>/dev/null || false
    [ ! -f "$SECRETS/relais.pid" ]
}

@test "cluster: display, refused without --yes outside a terminal, move with --yes" {
    run bash "$DEVZONE" cluster
    [[ "$output" == *"aucun cluster choisi"* ]] || false

    active_on kind-devzone
    run bash "$DEVZONE" cluster
    [[ "$output" == *"kind-devzone (kind dédié"* ]] || false

    run bash "$DEVZONE" cluster docker-desktop </dev/null
    [ "$status" -eq 1 ]
    grep -qx 'cluster=kind-devzone' "$DEVZONE_ETAT"

    run bash "$DEVZONE" cluster docker-desktop --yes </dev/null
    [ "$status" -eq 0 ]
    grep -qx 'cluster=docker-desktop' "$DEVZONE_ETAT"
    # Namespace of the old cluster deleted by the administrator (#430)
    grep -q -- '--context kind-devzone delete namespace devzone-postgres' "$BATS_TEST_TMPDIR/kubectl.log"
    # Installation on the new cluster goes through the devzone context, linked to docker-desktop
    grep -q 'kubectl config set-context devzone --cluster=docker-desktop --user=docker-desktop' "$BATS_TEST_TMPDIR/kubectl.log"
    grep -q 'kubectl --context devzone -n devzone-postgres apply -f -' "$BATS_TEST_TMPDIR/kubectl.log"
}

@test "cluster: module disabled → choice only saved; same cluster → nothing" {
    run bash "$DEVZONE" cluster docker-desktop </dev/null
    [ "$status" -eq 0 ]
    grep -qx 'cluster=docker-desktop' "$DEVZONE_ETAT"
    [ ! -f "$BATS_TEST_TMPDIR/apply.log" ]
    run bash "$DEVZONE" cluster docker-desktop </dev/null
    [[ "$output" == *"déjà sur docker-desktop"* ]] || false
}

@test "apply: postgres active, ready without relay → relay restarted, no reinstall" {
    active_on kind-devzone
    run bash "$DEVZONE" apply
    [[ "$output" == *"relais relancé"* ]] || false
    [ ! -f "$BATS_TEST_TMPDIR/apply.log" ]
}

@test "postgres: English names give no warning" {
    active_on docker-desktop
    run --separate-stderr bash "$POSTGRES" create taskmanager --new-password
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"deprecated"* ]] || false
    run --separate-stderr bash "$POSTGRES" list
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"deprecated"* ]] || false
    run --separate-stderr bash "$POSTGRES" delete taskmanager --yes
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"deprecated"* ]] || false
}
