#!/usr/bin/env bats
# MySQL du catalogue (#414) : creer/liste/supprimer par projet, etat, relais.
# Faux kubectl, openssl, nohup : aucun cluster touche.

setup() {
    load commun
    relais_docker_isole
    kube_isole
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    MYSQL="$BATS_TEST_DIRNAME/../../.devcontainer/catalogue/mysql/mysql.sh"
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
    *"readyReplicas"*) [ -f "$T/ready" ] && echo 1 || echo 0 ;;
    *"get statefulset mysql"*) [ -f "$T/sts" ]; exit $? ;;
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
    n=0
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
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

teardown() {
    bash "$MYSQL" relais-arreter >/dev/null 2>&1 || true
}

@test "creer : nom invalide ou reserve refuse (code 2)" {
    touch "$BATS_TEST_TMPDIR/ns"
    for nom in Task 1abc "a-b" "x;drop" mysql sys; do
        run bash "$MYSQL" creer "$nom"
        [ "$status" -eq 2 ] || false
    done
    [ ! -s "$BATS_TEST_TMPDIR/sql.log" ] || false
}

@test "creer : module inactif refuse" {
    run bash "$MYSQL" creer datayer
    [ "$status" -eq 2 ] || false
    [[ "$output" == *"devzone activer mysql"* ]] || false
}

@test "creer : utilisateur, base, .env 600, mot de passe jamais affiche, .password" {
    touch "$BATS_TEST_TMPDIR/ns"
    run bash "$MYSQL" creer datayer
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

@test "creer relance : mot de passe garde, --nouveau-mdp change" {
    touch "$BATS_TEST_TMPDIR/ns"
    bash "$MYSQL" creer datayer
    grep -qx 'MYSQL_PASSWORD=mdpmysql1' "$SECRETS/datayer.env" || false
    bash "$MYSQL" creer datayer
    grep -qx 'MYSQL_PASSWORD=mdpmysql1' "$SECRETS/datayer.env" || false
    bash "$MYSQL" creer datayer --nouveau-mdp
    grep -qx 'MYSQL_PASSWORD=mdpmysql2' "$SECRETS/datayer.env" || false
}

@test "supprimer : sans terminal refuse, --oui supprime base et utilisateur" {
    touch "$BATS_TEST_TMPDIR/ns"
    bash "$MYSQL" creer datayer
    : >"$BATS_TEST_TMPDIR/sql.log"
    run bash "$MYSQL" supprimer datayer </dev/null
    [ "$status" -eq 2 ] || false
    [ ! -s "$BATS_TEST_TMPDIR/sql.log" ] || false
    run bash "$MYSQL" supprimer datayer --oui
    [ "$status" -eq 0 ] || false
    grep -q "DROP DATABASE IF EXISTS datayer" "$BATS_TEST_TMPDIR/sql.log" || false
    grep -q "DROP USER IF EXISTS 'datayer'@'%'" "$BATS_TEST_TMPDIR/sql.log" || false
    [ ! -f "$SECRETS/datayer.env" ] || false
}

@test "etat : desactive, relais arrete, puis prêt" {
    run bash "$MYSQL" etat
    [ "$output" = "désactivé" ] || false
    touch "$BATS_TEST_TMPDIR/ns" "$BATS_TEST_TMPDIR/sts" "$BATS_TEST_TMPDIR/ready"
    run bash "$MYSQL" etat
    [ "$output" = "prêt sur kind-devzone, relais arrêté : devzone appliquer" ] || false
    bash "$MYSQL" relais-lancer
    attendre_nohup 'svc/mysql 3306:3306$'
    run bash "$MYSQL" etat
    [ "$output" = "prêt sur kind-devzone : 127.0.0.1:3306, 0 base(s)" ] || false
}

@test "installer adopte une installation existante, root.env intact, pas de reinstallation" {
    touch "$BATS_TEST_TMPDIR/ns" "$BATS_TEST_TMPDIR/sts" "$BATS_TEST_TMPDIR/ready"
    printf 'MYSQL_HOST=127.0.0.1\nMYSQL_PORT=3306\nMYSQL_USER=root\nMYSQL_PASSWORD=mdproot\n' >"$SECRETS/root.env"
    : >"$BATS_TEST_TMPDIR/apply.log"
    run bash "$MYSQL" installer
    [ "$status" -eq 0 ] || false
    [[ "$output" == *"adoptée"* ]] || false
    [ ! -s "$BATS_TEST_TMPDIR/apply.log" ] || false
    [ "$(cat "$SECRETS/root.env")" = $'MYSQL_HOST=127.0.0.1\nMYSQL_PORT=3306\nMYSQL_USER=root\nMYSQL_PASSWORD=mdproot' ] || false
    [ "$(cat "$SECRETS/admin-password")" = mdproot ] || false
}

@test "desinstaller : namespace supprime, donnees gardees" {
    touch "$BATS_TEST_TMPDIR/ns"
    printf 'MYSQL_PASSWORD=mdproot\n' >"$SECRETS/root.env"
    run bash "$MYSQL" desinstaller
    [ "$status" -eq 0 ] || false
    grep -q 'delete namespace devzone-mysql' "$BATS_TEST_TMPDIR/kubectl.log" || false
    [ -f "$SECRETS/root.env" ] || false
    [[ "$output" == *"gardées"* ]] || false
}

attendre_nohup() {
    local motif="$1" i=0
    while [ "$i" -lt 50 ]; do
        if grep -q -- "$motif" "$BATS_TEST_TMPDIR/nohup.log" 2>/dev/null; then return 0; fi
        i=$((i + 1))
        sleep 0.1
    done
    echo "nohup.log : ligne absente après 5 s : $motif" >&2
    return 1
}
