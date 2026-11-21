#!/usr/bin/env bats
# MySQL of the catalog (#414): create/list/delete per project, status, relay.
# Fake kubectl, openssl, nohup: no cluster touched.

setup() {
    bats_require_minimum_version 1.5.0
    load commun
    load commun-helm
    relais_docker_isole
    kube_isole
    # shellcheck disable=SC2034
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    MYSQL="$BATS_TEST_DIRNAME/../../.devcontainer/catalog/mysql/mysql.sh"
    SECRETS="$BATS_TEST_TMPDIR/racine/workspace/.mysql"
    export HOME="$BATS_TEST_TMPDIR/home"
    export DEVZONE_RACINE="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_ETAT="$BATS_TEST_TMPDIR/modules"
    export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
    mkdir -p "$HOME" "$SECRETS" "$BATS_TEST_TMPDIR/bin"
    : >"$DEVZONE_KUBE_HOTE"
    : >"$BATS_TEST_TMPDIR/kubectl.log"
    : >"$BATS_TEST_TMPDIR/apply.log"
    : >"$BATS_TEST_TMPDIR/sql.log"
    printf 'cluster=kind-devzone\n' >"$DEVZONE_ETAT"
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
echo "kubectl $*" >>"$T/kubectl.log"
case "$*" in
    "config get-contexts -o name") echo "docker-desktop" ;;
    *"config view"*)
        nom=""
        for c in docker-desktop kind-devzone; do
            if [[ "$*" == *\"$c\"* ]]; then nom="$c"; break; fi
        done || false
        if [[ "$*" == *'.cluster.server'* ]]; then echo "https://127.0.0.1:6443"; else echo "${nom:-}"; fi || false
        ;;
    *"get --raw /readyz"*)
        [[ "$*" == *"--context docker-desktop"* ]] || exit 1 || false
        ;;
    *"get namespace devzone-mysql"*) [ -f "$T/ns" ]; exit $? ;;
    *"create namespace"*) touch "$T/ns" ;;
    *"label namespace"*) ;;
    *"get pvc -o jsonpath"*)
        if [[ "$*" == *"-n devzone-mysql"* ]] && [ -f "$T/pvcs" ]; then cat "$T/pvcs"; fi || false
        ;;
    *"readyReplicas"*) [ -f "$T/ready" ] && echo 1 || echo 0 ;;
    *"get statefulset mysql -o jsonpath"*)
        if [ -f "$T/claim" ]; then cat "$T/claim"; else echo donnees; fi
        ;;
    *"get statefulset mysql"*) [ -f "$T/sts" ]; exit $? ;;
    *"delete statefulset mysql"*) rm -f "$T/sts" ;;
    *"delete pvc"*) echo "$*" >>"$T/delete.log" ;;
    *"apply -f -"*)
        data="$(cat)"
        if printf '%s\n' "$data" | grep -q 'kind: StatefulSet'; then printf '%s\n' "$data" >>"$T/apply.log"; else printf '%s\n' "$data" >>"$T/np.log"; fi
        touch "$T/ns" ;;
    *"get secret mysql-admin -o jsonpath"* ) printf 'bWRwcm9vdA==' ;;
    *"get secret mysql-admin"*) [ -f "$T/secret" ]; exit $? ;;
    *"create secret generic mysql-admin"*) touch "$T/secret" ;;
    *"exec -i mysql-0"*) cat >>"$T/sql.log" ;;
    *"delete namespace devzone-mysql"*) rm -f "$T/ns" ;;
    *"port-forward"*) exec sleep 300 ;;
esac
exit 0
KUBE
    cat >"$BATS_TEST_TMPDIR/bin/openssl" <<'SSL'
#!/usr/bin/env bash
n="$(cat "$BATS_TEST_TMPDIR/openssl.n" 2>/dev/null || echo 0)"
n=$((n + 1)); echo "$n" >"$BATS_TEST_TMPDIR/openssl.n"
echo "mdpmysql$n"
SSL
    cat >"$BATS_TEST_TMPDIR/bin/nohup" <<'NOHUP'
#!/usr/bin/env bash
echo "nohup $*" >>"$BATS_TEST_TMPDIR/nohup.log"
exec sleep 300
NOHUP
    cat >"$BATS_TEST_TMPDIR/bin/npm" <<'NPM'
#!/usr/bin/env bash
echo "npm $*" >>"$BATS_TEST_TMPDIR/npm.log"
if [ "${1:-}" = ls ] && [ "${2:-}" = -g ]; then echo '{"dependencies":{}}'; fi || false
exit 0
NPM
    chmod +x "$BATS_TEST_TMPDIR"/bin/*
    helm_fake_install
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

teardown() {
    bash "$MYSQL" relay-stop >/dev/null 2>&1 || true
}

@test "create: invalid or reserved name refused (code 2)" {
    touch "$BATS_TEST_TMPDIR/ns"
    for nom in Task 1abc "a-b" "x;drop" mysql sys; do
        run bash "$MYSQL" create "$nom"
        [ "$status" -eq 2 ] || false
    done
    [ ! -s "$BATS_TEST_TMPDIR/sql.log" ] || false
}

@test "create: module disabled refused" {
    run bash "$MYSQL" create datayer
    [ "$status" -eq 2 ] || false
    [[ "$output" == *"devzone enable mysql"* ]] || false
}

@test "create: user, database, .env 600, password never shown, .password" {
    touch "$BATS_TEST_TMPDIR/ns"
    run bash "$MYSQL" create datayer
    [ "$status" -eq 0 ] || false
    grep -q "CREATE USER IF NOT EXISTS 'datayer'@'%'" "$BATS_TEST_TMPDIR/sql.log" || false
    grep -q "CREATE DATABASE IF NOT EXISTS datayer" "$BATS_TEST_TMPDIR/sql.log" || false
    grep -q "GRANT ALL ON datayer.* TO 'datayer'@'%'" "$BATS_TEST_TMPDIR/sql.log" || false
    grep -qx 'MYSQL_HOST=127.0.0.1' "$SECRETS/datayer.env" || false
    grep -qx 'MYSQL_PORT=3306' "$SECRETS/datayer.env" || false
    grep -qx 'MYSQL_USER=datayer' "$SECRETS/datayer.env" || false
    grep -qx 'MYSQL_PASSWORD=mdpmysql1' "$SECRETS/datayer.env" || false
    grep -qx 'MYSQL_URL=jdbc:mysql://127.0.0.1:3306/datayer' "$SECRETS/datayer.env" || false
    [ "$(stat -c %a "$SECRETS/datayer.env" 2>/dev/null || stat -f %Lp "$SECRETS/datayer.env")" = 600 ] || false
    [[ "$output" != *mdpmysql* ]] || false
    [[ "$output" == *"$SECRETS/datayer.env"* ]] || false
    grep -q $'^mysql:datayer\t127.0.0.1:3306\tdatayer\tmdpmysql1$' "$DEVZONE_RACINE/.password" || false
}

@test "create again: password kept, --new-password changes it" {
    touch "$BATS_TEST_TMPDIR/ns"
    bash "$MYSQL" create datayer
    grep -qx 'MYSQL_PASSWORD=mdpmysql1' "$SECRETS/datayer.env" || false
    bash "$MYSQL" create datayer
    grep -qx 'MYSQL_PASSWORD=mdpmysql1' "$SECRETS/datayer.env" || false
    bash "$MYSQL" create datayer --new-password
    grep -qx 'MYSQL_PASSWORD=mdpmysql2' "$SECRETS/datayer.env" || false
}

@test "delete: without a terminal refused, --yes deletes database and user" {
    touch "$BATS_TEST_TMPDIR/ns"
    bash "$MYSQL" create datayer
    : >"$BATS_TEST_TMPDIR/sql.log"
    run bash "$MYSQL" delete datayer </dev/null
    [ "$status" -eq 2 ] || false
    [ ! -s "$BATS_TEST_TMPDIR/sql.log" ] || false
    run bash "$MYSQL" delete datayer --yes
    [ "$status" -eq 0 ] || false
    grep -q "DROP DATABASE IF EXISTS datayer" "$BATS_TEST_TMPDIR/sql.log" || false
    grep -q "DROP USER IF EXISTS 'datayer'@'%'" "$BATS_TEST_TMPDIR/sql.log" || false
    [ ! -f "$SECRETS/datayer.env" ] || false
}

@test "status: disabled, relay stopped, then ready" {
    run bash "$MYSQL" status
    [ "$output" = "désactivé" ] || false
    touch "$BATS_TEST_TMPDIR/ns" "$BATS_TEST_TMPDIR/sts" "$BATS_TEST_TMPDIR/ready"
    run bash "$MYSQL" status
    [ "$output" = "prêt sur kind-devzone, relais arrêté : devzone apply" ] || false
    bash "$MYSQL" relay-start
    attendre_nohup 'svc/mysql 3306:3306$'
    run bash "$MYSQL" status
    [ "$output" = "prêt sur kind-devzone : 127.0.0.1:3306, 0 base(s)" ] || false
}

@test "install adopts an existing installation, root.env intact, no reinstallation" {
    touch "$BATS_TEST_TMPDIR/ns" "$BATS_TEST_TMPDIR/sts" "$BATS_TEST_TMPDIR/ready"
    printf 'MYSQL_HOST=127.0.0.1\nMYSQL_PORT=3306\nMYSQL_USER=root\nMYSQL_PASSWORD=mdproot\n' >"$SECRETS/root.env"
    : >"$BATS_TEST_TMPDIR/apply.log"
    run bash "$MYSQL" install
    [ "$status" -eq 0 ] || false
    [[ "$output" == *"adopted"* ]] || false
    [ ! -s "$BATS_TEST_TMPDIR/apply.log" ] || false
    [ "$(cat "$SECRETS/root.env")" = $'MYSQL_HOST=127.0.0.1\nMYSQL_PORT=3306\nMYSQL_USER=root\nMYSQL_PASSWORD=mdproot' ] || false
    [ "$(cat "$SECRETS/admin-password")" = mdproot ] || false
}

@test "delete-data --yes: namespace and volumes deleted, root.env kept" {
    touch "$BATS_TEST_TMPDIR/ns"
    printf 'MYSQL_PASSWORD=mdproot\n' >"$SECRETS/root.env"
    run bash "$MYSQL" delete-data --yes
    [ "$status" -eq 0 ] || false
    grep -q 'delete namespace devzone-mysql' "$BATS_TEST_TMPDIR/kubectl.log" || false
    [ -f "$SECRETS/root.env" ] || false
    [[ "$output" == *"✔ namespace devzone-mysql and volume deleted; workspace/.mysql/root.env kept"* ]] || false
}

@test "delete-data: without a terminal nor --yes, refusal and no delete" {
    touch "$BATS_TEST_TMPDIR/ns"
    run bash "$MYSQL" delete-data </dev/null
    [ "$status" -eq 2 ] || false
    [[ "$output" == *"confirmation needs a terminal: devzone mysql delete-data --yes"* ]] || false
    ! grep -q 'delete' "$BATS_TEST_TMPDIR/kubectl.log" 2>/dev/null || false
}

@test "delete-data in a terminal: Enter = abort, no delete" {
    touch "$BATS_TEST_TMPDIR/ns"
    DEVZONE_INTERACTIF=1 run bash "$MYSQL" delete-data <<<""
    [ "$status" -eq 0 ] || false
    [[ "$output" == *"Aborted"* ]] || false
    ! grep -q 'delete' "$BATS_TEST_TMPDIR/kubectl.log" 2>/dev/null || false
}

attendre_nohup() {
    local motif="$1" i=0
    while [ "$i" -lt 50 ]; do
        if grep -q -- "$motif" "$BATS_TEST_TMPDIR/nohup.log" 2>/dev/null; then return 0; fi
        i=$((i + 1))
        sleep 0.1
    done
    echo "nohup.log: line missing after 5 s: $motif" >&2
    return 1
}

@test "install: without an existing PVC, claim donnees" {
    run bash "$MYSQL" install
    [ "$status" -eq 0 ] || false
    grep -q 'name: donnees' "$BATS_TEST_TMPDIR/apply.log" || false
}

@test "install: one existing PVC, reuses its prefix" {
    printf 'data-mysql-0\n' >"$BATS_TEST_TMPDIR/pvcs"
    run bash "$MYSQL" install
    [ "$status" -eq 0 ] || false
    grep -q '        name: data' "$BATS_TEST_TMPDIR/apply.log" || false
    grep -q 'volumeMounts:' "$BATS_TEST_TMPDIR/apply.log" || false
}

@test "install: several PVCs, refusal with list and command" {
    printf 'data-mysql-0\ndonnees-mysql-0\n' >"$BATS_TEST_TMPDIR/pvcs"
    run bash "$MYSQL" install
    [ "$status" -eq 2 ] || false
    [[ "$output" == *"data-mysql-0"* ]] || false
    [[ "$output" == *"donnees-mysql-0"* ]] || false
    [[ "$output" == *"devzone mysql volume <name>"* ]] || false
    [ ! -s "$BATS_TEST_TMPDIR/apply.log" ] || false
}

@test "mysql volume: lists the PVCs and marks the mounted one" {
    touch "$BATS_TEST_TMPDIR/ns"
    printf 'data-mysql-0\ndonnees-mysql-0\n' >"$BATS_TEST_TMPDIR/pvcs"
    printf 'data' >"$BATS_TEST_TMPDIR/claim"
    run bash "$MYSQL" volume
    [ "$status" -eq 0 ] || false
    [[ "$output" == *"data-mysql-0 (mounted)"* ]] || false
    [[ "$output" == *"donnees-mysql-0"* ]] || false
    [[ "$output" != *"donnees-mysql-0 (mounted)"* ]] || false
}

@test "mysql volume <name>: reapplies the StatefulSet on this volume" {
    touch "$BATS_TEST_TMPDIR/ns" "$BATS_TEST_TMPDIR/sts"
    run bash "$MYSQL" volume data
    [ "$status" -eq 0 ] || false
    grep -q 'delete statefulset mysql' "$BATS_TEST_TMPDIR/kubectl.log" || false
    grep -q 'name: data' "$BATS_TEST_TMPDIR/apply.log" || false
}

@test "mysql volume --delete without --yes nor terminal: no delete" {
    touch "$BATS_TEST_TMPDIR/ns"
    printf 'data' >"$BATS_TEST_TMPDIR/claim"
    run bash "$MYSQL" volume --delete donnees </dev/null
    [ "$status" -eq 2 ] || false
    [ ! -f "$BATS_TEST_TMPDIR/delete.log" ] || false
}

@test "mysql volume --delete refused when the volume is mounted" {
    touch "$BATS_TEST_TMPDIR/ns"
    printf 'data' >"$BATS_TEST_TMPDIR/claim"
    run bash "$MYSQL" volume --delete data --yes
    [ "$status" -eq 2 ] || false
    [ ! -f "$BATS_TEST_TMPDIR/delete.log" ] || false
}

@test "mysql volume --delete <name> --yes: deletes the PVC" {
    touch "$BATS_TEST_TMPDIR/ns"
    printf 'data' >"$BATS_TEST_TMPDIR/claim"
    run bash "$MYSQL" volume --delete donnees --yes
    [ "$status" -eq 0 ] || false
    grep -q 'delete pvc donnees-mysql-0' "$BATS_TEST_TMPDIR/delete.log" || false
}

# ---- French names (#557): same result as the English name, with the warning ----

@test "mysql: English names give no warning" {
    touch "$BATS_TEST_TMPDIR/ns" "$BATS_TEST_TMPDIR/sts" "$BATS_TEST_TMPDIR/ready"
    printf 'MYSQL_PASSWORD=mdproot\n' >"$SECRETS/root.env"
    run --separate-stderr bash "$MYSQL" create datayer --new-password
    [ "$status" -eq 0 ] || false
    [[ "$stderr" != *"deprecated"* ]] || false
    run --separate-stderr bash "$MYSQL" status
    [ "$status" -eq 0 ] || false
    [[ "$stderr" != *"deprecated"* ]] || false
    run --separate-stderr bash "$MYSQL" list
    [ "$status" -eq 0 ] || false
    [[ "$stderr" != *"deprecated"* ]] || false
    run --separate-stderr bash "$MYSQL" delete datayer --yes
    [ "$status" -eq 0 ] || false
    [[ "$stderr" != *"deprecated"* ]] || false
    run --separate-stderr bash "$MYSQL" delete-data --yes
    [ "$status" -eq 0 ] || false
    [[ "$stderr" != *"deprecated"* ]] || false
}
