#!/usr/bin/env bats
# Application catalog (#414): sync, apply, list, resume, json.
# Fake kubectl, kind, openssl, nohup: no cluster touched.

setup() {
    load commun
    load commun-helm
    relais_docker_isole
    kube_isole
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    CATALOGUE="$BATS_TEST_DIRNAME/../../.devcontainer/catalog.sh"
    MYSQL="$BATS_TEST_DIRNAME/../../.devcontainer/catalog/mysql/mysql.sh"
    SECRETS="$BATS_TEST_TMPDIR/racine/workspace/.mysql"
    export HOME="$BATS_TEST_TMPDIR/home"
    export DEVZONE_RACINE="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_ETAT="$BATS_TEST_TMPDIR/modules"
    export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
    mkdir -p "$HOME" "$DEVZONE_RACINE/workspace" "$BATS_TEST_TMPDIR/bin"
    : >"$DEVZONE_KUBE_HOTE"
    : >"$BATS_TEST_TMPDIR/kubectl.log"
    : >"$BATS_TEST_TMPDIR/apply.log"
    : >"$BATS_TEST_TMPDIR/np.log"
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
    *"apply -f -"*)
        [ -f "$T/APPLY_ECHEC" ] && exit 1 || false
        data="$(cat)"
        if printf '%s\n' "$data" | grep -q 'kind: StatefulSet'; then printf '%s\n' "$data" >>"$T/apply.log"; else printf '%s\n' "$data" >>"$T/np.log"; fi
        touch "$T/ns" ;;
    *"apply -f "*)
        [ -f "$T/APPLY_ECHEC" ] && exit 1 || false
        data="$(cat "${@: -1}")"
        if printf '%s\n' "$data" | grep -q 'kind: StatefulSet'; then printf '%s\n' "$data" >>"$T/apply.log"; else printf '%s\n' "$data" >>"$T/np.log"; fi
        touch "$T/ns" ;;
    *"get secret mysql-admin -o jsonpath"* ) printf 'bWRwY2F0YWxvZ3Vl' ;;
    *"get secret mysql-admin"*) [ -f "$T/secret" ]; exit $? ;;
    *"create secret generic mysql-admin"*) touch "$T/secret" ;;
    *"rollout status"*) ;;
    *"delete statefulset mysql"*) rm -f "$T/sts" ;;
    *"delete service mysql"*) ;;
    *"delete secret mysql-admin"*) rm -f "$T/secret" ;;
    *"delete namespace devzone-mysql"*) rm -f "$T/ns" ;;
    *"port-forward"*) exec sleep 300 ;;
esac
exit 0
KUBE
    cat >"$BATS_TEST_TMPDIR/bin/kind" <<'KIND'
#!/usr/bin/env bash
echo "kind $*" >>"$BATS_TEST_TMPDIR/kind.log"
exit 0
KIND
    cat >"$BATS_TEST_TMPDIR/bin/openssl" <<'SSL'
#!/usr/bin/env bash
echo "mdpcatalogue"
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
    # Fake getent: the service <app>.<namespace>.svc of the cluster resolves
    # as long as the marker $T/svc exists (presence by the cluster DNS, #515)
    cat >"$BATS_TEST_TMPDIR/bin/getent" <<'GETENT'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
case "$2" in
    *.devzone-mysql.svc)
        [ -f "$T/svc" ] && exit 0
        ;;
esac
exit 2
GETENT
    chmod +x "$BATS_TEST_TMPDIR"/bin/*
    helm_fake_install
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

teardown() {
    bash "$MYSQL" relay-stop >/dev/null 2>&1 || true
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

@test "sync: mysql=off added once, existing line kept" {
    printf 'autre=off\n' >"$DEVZONE_ETAT"
    run bash "$CATALOGUE" sync
    [ "$status" -eq 0 ] || false
    grep -qx 'mysql=off' "$DEVZONE_ETAT" || false
    grep -qF '# Applications du catalogue : passer à on pour installer (devzone catalog)' "$DEVZONE_ETAT" || false
    run bash "$CATALOGUE" sync
    [ "$status" -eq 0 ] || false
    [ "$(grep -c '^mysql=' "$DEVZONE_ETAT")" -eq 1 ] || false
    [ "$(grep -cF '# Applications du catalogue' "$DEVZONE_ETAT")" -eq 1 ] || false
}

@test "sync keeps an existing line (mysql=on keeps its value)" {
    printf 'mysql=on\n' >"$DEVZONE_ETAT"
    run bash "$CATALOGUE" sync
    [ "$status" -eq 0 ] || false
    grep -qx 'mysql=on' "$DEVZONE_ETAT" || false
}

@test "sync concurrent: mysql=off added once, existing line kept" {
    printf 'ia=on\nautre=off\n' >"$DEVZONE_ETAT"
    bash "$CATALOGUE" sync & pid_a=$!
    bash "$CATALOGUE" sync & pid_b=$!
    wait "$pid_a"
    wait "$pid_b"
    grep -qx 'mysql=off' "$DEVZONE_ETAT" || false
    grep -qx 'ia=on' "$DEVZONE_ETAT" || false
    [ "$(grep -c '^mysql=' "$DEVZONE_ETAT")" -eq 1 ] || false
}

@test "apply: mysql=on installs (manifest, secret, relay 127.0.0.1:3306)" {    printf 'cluster=kind-devzone\nmysql=on\n' >"$DEVZONE_ETAT"
    run bash "$DEVZONE" apply
    [ "$status" -eq 0 ] || false
    grep -q 'image: mysql:8.4' "$BATS_TEST_TMPDIR/apply.log" || false
    grep -q 'storage: 5Gi' "$BATS_TEST_TMPDIR/apply.log" || false
    grep -q -- '-n devzone-mysql apply -f -' "$BATS_TEST_TMPDIR/kubectl.log" || false
    grep -q 'create secret generic mysql-admin' "$BATS_TEST_TMPDIR/kubectl.log" || false
    attendre_nohup 'svc/mysql 3306:3306$'
    grep -q 'svc/mysql 3306:3306$' "$BATS_TEST_TMPDIR/nohup.log" || false
    [ -s "$SECRETS/admin-password" ] || false
    [ "$(stat -c %a "$SECRETS/admin-password" 2>/dev/null || stat -f %Lp "$SECRETS/admin-password")" = 600 ] || false
    [[ "$output" == *"127.0.0.1:3306"* ]] || false
    [[ "$output" != *mdpcatalogue* ]] || false
}

@test "apply: mysql=on reuses the PVC of the devzone-mysql namespace" {
    printf 'cluster=kind-devzone\nmysql=on\n' >"$DEVZONE_ETAT"
    printf 'data-mysql-0\n' >"$BATS_TEST_TMPDIR/pvcs"
    run bash "$DEVZONE" apply
    [ "$status" -eq 0 ] || false
    grep -q 'name: data' "$BATS_TEST_TMPDIR/apply.log" || false
    [[ "$(cat "$BATS_TEST_TMPDIR/apply.log")" != *"name: donnees"* ]] || false
}

@test "apply: two mysql PVCs, refusal with list and command" {
    printf 'cluster=kind-devzone\nmysql=on\n' >"$DEVZONE_ETAT"
    printf 'data-mysql-0\ndonnees-mysql-0\n' >"$BATS_TEST_TMPDIR/pvcs"
    run bash "$DEVZONE" apply
    [ "$status" -ne 0 ] || false
    [[ "$output" == *"data-mysql-0"* ]] || false
    [[ "$output" == *"donnees-mysql-0"* ]] || false
    [[ "$output" == *"devzone mysql volume"* ]] || false
    [ ! -s "$BATS_TEST_TMPDIR/apply.log" ] || false
}

@test "catalog apply: mysql=on reuses the PVC of the namespace" {
    printf 'cluster=kind-devzone\nmysql=on\n' >"$DEVZONE_ETAT"
    printf 'data-mysql-0\n' >"$BATS_TEST_TMPDIR/pvcs"
    run bash "$CATALOGUE" apply
    [ "$status" -eq 0 ] || false
    grep -q 'name: data' "$BATS_TEST_TMPDIR/apply.log" || false
    [[ "$(cat "$BATS_TEST_TMPDIR/apply.log")" != *"name: donnees"* ]] || false
}

@test "apply: mysql already present, no reinstallation, relay restarted" {
    touch "$BATS_TEST_TMPDIR/ns" "$BATS_TEST_TMPDIR/sts" "$BATS_TEST_TMPDIR/ready" "$BATS_TEST_TMPDIR/secret"
    printf 'cluster=kind-devzone\nmysql=on\n' >"$DEVZONE_ETAT"
    run bash "$DEVZONE" apply
    [ "$status" -eq 0 ] || false
    [ ! -s "$BATS_TEST_TMPDIR/apply.log" ] || false
    attendre_nohup 'svc/mysql 3306:3306$'
    grep -q 'svc/mysql 3306:3306$' "$BATS_TEST_TMPDIR/nohup.log" || false
}

@test "apply: mysql=on without a chosen cluster refused" {
    printf 'mysql=on\n' >"$DEVZONE_ETAT"
    run bash "$DEVZONE" apply
    [ "$status" -ne 0 ] || false
    [[ "$output" == *"no cluster chosen"* ]] || false
    [ -f "$DEVZONE_ETAT-echec-mysql" ] || false
}

@test "apply: a failure marks the failure and shows ✖ in the summary" {
    touch "$BATS_TEST_TMPDIR/APPLY_ECHEC"
    printf 'cluster=kind-devzone\nmysql=on\n' >"$DEVZONE_ETAT"
    run bash "$DEVZONE" apply
    [ "$status" -ne 0 ] || false
    [ -f "$DEVZONE_ETAT-echec-mysql" ] || false
    run bash "$DEVZONE"
    [ "$status" -eq 0 ] || false
    [[ "$output" == *"✖ module mysql"* ]] || false
    [[ "$output" == *"✖ application mysql failed"* ]] || false
    [[ "$output" == *"devzone apply"* ]] || false
}

@test "resume: application installed, relay stopped, warns and proposes devzone repair" {
    touch "$BATS_TEST_TMPDIR/ns" "$BATS_TEST_TMPDIR/sts" "$BATS_TEST_TMPDIR/ready"
    printf 'cluster=kind-devzone\nmysql=on\n' >"$DEVZONE_ETAT"
    run bash "$DEVZONE"
    [ "$status" -eq 0 ] || false
    ligne="$(printf '%s\n' "$output" | grep 'application mysql' || true)"
    ligne="${ligne#"${ligne%%[![:space:]]*}"}"
    [[ "$ligne" == "⚠ application mysql"* ]] || false
    [[ "$ligne" == *"devzone repair"* ]] || false
    [[ "$ligne" != *"✔"* ]] || false
}

@test "resume: DEVZONE_WORKSPACE=kubernetes → installed via the cluster, access devzone workspace ports" {
    export DEVZONE_WORKSPACE=kubernetes
    touch "$BATS_TEST_TMPDIR/svc"
    printf 'cluster=kind-devzone\nmysql=on\n' >"$DEVZONE_ETAT"
    run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"installed: local access: devzone workspace ports"* ]] || false
    ! grep -q 'get statefulset' "$BATS_TEST_TMPDIR/kubectl.log" 2>/dev/null || false
}

@test "resume: DEVZONE_WORKSPACE=kubernetes → service absent → application expected" {
    export DEVZONE_WORKSPACE=kubernetes
    printf 'cluster=kind-devzone\nmysql=on\n' >"$DEVZONE_ETAT"
    run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"expected: devzone apply"* ]] || false
    ! grep -q 'get statefulset' "$BATS_TEST_TMPDIR/kubectl.log" 2>/dev/null || false
}

@test "disable mysql: without --yes nor terminal, volume kept, no namespace delete" {
    mkdir -p "$SECRETS"
    printf 'MYSQL_PASSWORD=mdproot\n' >"$SECRETS/root.env"
    touch "$BATS_TEST_TMPDIR/ns" "$BATS_TEST_TMPDIR/sts" "$BATS_TEST_TMPDIR/secret"
    printf 'cluster=kind-devzone\nmysql=on\n' >"$DEVZONE_ETAT"
    run bash "$DEVZONE" disable mysql
    [ "$status" -eq 0 ] || false
    grep -q 'delete statefulset/mysql service/mysql' "$BATS_TEST_TMPDIR/kubectl.log" || false
    ! grep -q 'delete namespace devzone-mysql' "$BATS_TEST_TMPDIR/kubectl.log" 2>/dev/null || false
    grep -qx 'mysql=off' "$DEVZONE_ETAT" || false
    [ "$(cat "$SECRETS/root.env")" = "MYSQL_PASSWORD=mdproot" ] || false
    [[ "$output" == *"✔ mysql removed from the cluster; volume donnees-mysql-0 and databases kept: devzone mysql volume"* ]] || false
}

@test "disable mysql --yes: same deletion, no warning (#557)" {
    touch "$BATS_TEST_TMPDIR/ns" "$BATS_TEST_TMPDIR/sts" "$BATS_TEST_TMPDIR/secret"
    printf 'cluster=kind-devzone\nmysql=on\n' >"$DEVZONE_ETAT"
    run --separate-stderr bash "$DEVZONE" disable mysql --yes
    [ "$status" -eq 0 ] || false
    grep -q 'delete namespace devzone-mysql' "$BATS_TEST_TMPDIR/kubectl.log" || false
    grep -qx 'mysql=off' "$DEVZONE_ETAT" || false
    [[ "$output" == *"✔ namespace devzone-mysql and volume deleted; workspace/.mysql/root.env kept"* ]] || false
    [[ "$stderr" != *"deprecated"* ]] || false
}

@test "disable mysql in a terminal: N removes the server and keeps the volume" {
    mkdir -p "$SECRETS"
    printf 'MYSQL_PASSWORD=mdproot\n' >"$SECRETS/root.env"
    touch "$BATS_TEST_TMPDIR/ns" "$BATS_TEST_TMPDIR/sts" "$BATS_TEST_TMPDIR/secret"
    printf 'cluster=kind-devzone\nmysql=on\n' >"$DEVZONE_ETAT"
    DEVZONE_INTERACTIF=1 run bash "$DEVZONE" disable mysql <<<"n"
    [ "$status" -eq 0 ] || false
    grep -q 'delete statefulset/mysql service/mysql' "$BATS_TEST_TMPDIR/kubectl.log" || false
    ! grep -q 'delete namespace devzone-mysql' "$BATS_TEST_TMPDIR/kubectl.log" 2>/dev/null || false
    grep -qx 'mysql=off' "$DEVZONE_ETAT" || false
    [[ "$output" == *"Disabling mysql removes the server"* ]] || false
    [[ "$output" == *"volume donnees-mysql-0 and databases kept"* ]] || false
    [ "$(cat "$SECRETS/root.env")" = "MYSQL_PASSWORD=mdproot" ] || false
}

@test "disable mysql in a terminal: o also deletes the namespace" {
    touch "$BATS_TEST_TMPDIR/ns" "$BATS_TEST_TMPDIR/sts" "$BATS_TEST_TMPDIR/secret"
    printf 'cluster=kind-devzone\nmysql=on\n' >"$DEVZONE_ETAT"
    DEVZONE_INTERACTIF=1 run bash "$DEVZONE" disable mysql <<<"o"
    [ "$status" -eq 0 ] || false
    grep -q 'delete statefulset/mysql service/mysql' "$BATS_TEST_TMPDIR/kubectl.log" || false
    grep -q 'delete namespace devzone-mysql' "$BATS_TEST_TMPDIR/kubectl.log" || false
    grep -qx 'mysql=off' "$DEVZONE_ETAT" || false
    [[ "$output" == *"✔ namespace devzone-mysql and volume deleted; workspace/.mysql/root.env kept"* ]] || false
}

@test "enable mysql: writes the line then applies (switch to catalog application)" {
    printf 'cluster=kind-devzone\nmysql=off\n' >"$DEVZONE_ETAT"
    run bash "$DEVZONE" enable mysql
    [ "$status" -eq 0 ] || false
    grep -qx 'mysql=on' "$DEVZONE_ETAT" || false
    grep -q 'image: mysql:8.4' "$BATS_TEST_TMPDIR/apply.log" || false
}

@test "devzone catalog lists the applications" {
    run bash "$DEVZONE" catalog
    [ "$status" -eq 0 ] || false
    [[ "$output" == *"mysql"* ]] || false
    [[ "$output" == *"available"* ]] || false
}

@test "status --json has an applications section" {
    run bash "$DEVZONE" status --json
    [ "$status" -eq 0 ] || false
    printf '%s' "$output" | jq -e '.applications | type == "array"' >/dev/null || false
}

@test "resume: warns about an unused mysql volume" {
    touch "$BATS_TEST_TMPDIR/ns" "$BATS_TEST_TMPDIR/sts" "$BATS_TEST_TMPDIR/ready"
    printf 'cluster=kind-devzone\nmysql=on\n' >"$DEVZONE_ETAT"
    printf 'data' >"$BATS_TEST_TMPDIR/claim"
    printf 'data-mysql-0\nancien-mysql-0\n' >"$BATS_TEST_TMPDIR/pvcs"
    run bash "$DEVZONE"
    [ "$status" -eq 0 ] || false
    [[ "$output" == *"⚠ volume ancien-mysql-0 not used : devzone mysql volume"* ]] || false
    [[ "$output" != *"data-mysql-0 not used"* ]] || false
}
