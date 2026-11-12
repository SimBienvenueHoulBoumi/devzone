#!/usr/bin/env bats
# Catalogue d'applications (#414) : synchroniser, appliquer, lister, resume,
# json. Faux kubectl, kind, openssl, nohup : aucun cluster touché.

setup() {
    load commun
    relais_docker_isole
    kube_isole
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    CATALOGUE="$BATS_TEST_DIRNAME/../../.devcontainer/catalogue.sh"
    MYSQL="$BATS_TEST_DIRNAME/../../.devcontainer/catalogue/mysql/mysql.sh"
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
    # Faux getent : le service <app>.<namespace>.svc du cluster est resolvable
    # tant que le marqueur $T/svc existe (presence par le DNS du cluster, #515)
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
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

teardown() {
    bash "$MYSQL" relais-arreter >/dev/null 2>&1 || true
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

@test "synchroniser : mysql=off ajouté une fois, ligne existante respectée" {
    printf 'autre=off\n' >"$DEVZONE_ETAT"
    run bash "$CATALOGUE" synchroniser
    [ "$status" -eq 0 ] || false
    grep -qx 'mysql=off' "$DEVZONE_ETAT" || false
    grep -qF '# Applications du catalogue : passer à on pour installer (devzone catalogue)' "$DEVZONE_ETAT" || false
    run bash "$CATALOGUE" synchroniser
    [ "$status" -eq 0 ] || false
    [ "$(grep -c '^mysql=' "$DEVZONE_ETAT")" -eq 1 ] || false
    [ "$(grep -cF '# Applications du catalogue' "$DEVZONE_ETAT")" -eq 1 ] || false
}

@test "synchroniser respecte une ligne existante (mysql=on garde sa valeur)" {
    printf 'mysql=on\n' >"$DEVZONE_ETAT"
    run bash "$CATALOGUE" synchroniser
    [ "$status" -eq 0 ] || false
    grep -qx 'mysql=on' "$DEVZONE_ETAT" || false
}

@test "synchroniser concurrent : mysql=off ajouté une fois, ligne existante respectée" {
    printf 'ia=on\nautre=off\n' >"$DEVZONE_ETAT"
    bash "$CATALOGUE" synchroniser & pid_a=$!
    bash "$CATALOGUE" synchroniser & pid_b=$!
    wait "$pid_a"
    wait "$pid_b"
    grep -qx 'mysql=off' "$DEVZONE_ETAT" || false
    grep -qx 'ia=on' "$DEVZONE_ETAT" || false
    [ "$(grep -c '^mysql=' "$DEVZONE_ETAT")" -eq 1 ] || false
}

@test "appliquer : mysql=on installe (manifest, secret, relais 127.0.0.1:3306)" {
    printf 'cluster=kind-devzone\nmysql=on\n' >"$DEVZONE_ETAT"
    run bash "$DEVZONE" appliquer
    [ "$status" -eq 0 ] || false
    grep -q 'image: mysql:8.4' "$BATS_TEST_TMPDIR/apply.log" || false
    grep -q 'storage: 5Gi' "$BATS_TEST_TMPDIR/apply.log" || false
    grep -q 'namespace devzone-mysql' "$BATS_TEST_TMPDIR/apply.log" || false
    grep -q 'create secret generic mysql-admin' "$BATS_TEST_TMPDIR/kubectl.log" || false
    attendre_nohup 'svc/mysql 3306:3306$'
    grep -q 'svc/mysql 3306:3306$' "$BATS_TEST_TMPDIR/nohup.log" || false
    [ -s "$SECRETS/admin-password" ] || false
    [ "$(stat -c %a "$SECRETS/admin-password" 2>/dev/null || stat -f %Lp "$SECRETS/admin-password")" = 600 ] || false
    [[ "$output" == *"127.0.0.1:3306"* ]] || false
    [[ "$output" != *mdpcatalogue* ]] || false
}

@test "appliquer : mysql=on réutilise le PVC du namespace devzone-mysql" {
    printf 'cluster=kind-devzone\nmysql=on\n' >"$DEVZONE_ETAT"
    printf 'data-mysql-0\n' >"$BATS_TEST_TMPDIR/pvcs"
    run bash "$DEVZONE" appliquer
    [ "$status" -eq 0 ] || false
    grep -q 'name: data' "$BATS_TEST_TMPDIR/apply.log" || false
    [[ "$(cat "$BATS_TEST_TMPDIR/apply.log")" != *"name: donnees"* ]] || false
}

@test "appliquer : deux PVC mysql, refus avec liste et commande" {
    printf 'cluster=kind-devzone\nmysql=on\n' >"$DEVZONE_ETAT"
    printf 'data-mysql-0\ndonnees-mysql-0\n' >"$BATS_TEST_TMPDIR/pvcs"
    run bash "$DEVZONE" appliquer
    [ "$status" -ne 0 ] || false
    [[ "$output" == *"data-mysql-0"* ]] || false
    [[ "$output" == *"donnees-mysql-0"* ]] || false
    [[ "$output" == *"devzone mysql volume"* ]] || false
    [ ! -s "$BATS_TEST_TMPDIR/apply.log" ] || false
}

@test "catalogue appliquer : mysql=on réutilise le PVC du namespace" {
    printf 'cluster=kind-devzone\nmysql=on\n' >"$DEVZONE_ETAT"
    printf 'data-mysql-0\n' >"$BATS_TEST_TMPDIR/pvcs"
    run bash "$CATALOGUE" appliquer
    [ "$status" -eq 0 ] || false
    grep -q 'name: data' "$BATS_TEST_TMPDIR/apply.log" || false
    [[ "$(cat "$BATS_TEST_TMPDIR/apply.log")" != *"name: donnees"* ]] || false
}

@test "appliquer : mysql deja present et present, pas de reinstallation, relais relance" {
    touch "$BATS_TEST_TMPDIR/ns" "$BATS_TEST_TMPDIR/sts" "$BATS_TEST_TMPDIR/ready" "$BATS_TEST_TMPDIR/secret"
    printf 'cluster=kind-devzone\nmysql=on\n' >"$DEVZONE_ETAT"
    run bash "$DEVZONE" appliquer
    [ "$status" -eq 0 ] || false
    [ ! -s "$BATS_TEST_TMPDIR/apply.log" ] || false
    attendre_nohup 'svc/mysql 3306:3306$'
    grep -q 'svc/mysql 3306:3306$' "$BATS_TEST_TMPDIR/nohup.log" || false
}

@test "appliquer : mysql=on sans cluster choisi refuse" {
    printf 'mysql=on\n' >"$DEVZONE_ETAT"
    run bash "$DEVZONE" appliquer
    [ "$status" -ne 0 ] || false
    [[ "$output" == *"aucun cluster choisi"* ]] || false
    [ -f "$DEVZONE_ETAT-echec-mysql" ] || false
}

@test "appliquer : echec d'application marque l'echec et affiche ✖ au recapitulatif" {
    touch "$BATS_TEST_TMPDIR/APPLY_ECHEC"
    printf 'cluster=kind-devzone\nmysql=on\n' >"$DEVZONE_ETAT"
    run bash "$DEVZONE" appliquer
    [ "$status" -ne 0 ] || false
    [ -f "$DEVZONE_ETAT-echec-mysql" ] || false
    run bash "$DEVZONE"
    [ "$status" -eq 0 ] || false
    [[ "$output" == *"✖ module mysql"* ]] || false
    [[ "$output" == *"✖ application mysql en échec"* ]] || false
    [[ "$output" == *"devzone appliquer"* ]] || false
}

@test "resume : application installée, relais arrêté, avertit et propose devzone reparer" {
    touch "$BATS_TEST_TMPDIR/ns" "$BATS_TEST_TMPDIR/sts" "$BATS_TEST_TMPDIR/ready"
    printf 'cluster=kind-devzone\nmysql=on\n' >"$DEVZONE_ETAT"
    run bash "$DEVZONE"
    [ "$status" -eq 0 ] || false
    ligne="$(printf '%s\n' "$output" | grep 'application mysql' || true)"
    ligne="${ligne#"${ligne%%[![:space:]]*}"}"
    [[ "$ligne" == "⚠ application mysql"* ]] || false
    [[ "$ligne" == *"devzone reparer"* ]] || false
    [[ "$ligne" != *"✔"* ]] || false
}

@test "resume : DEVZONE_WORKSPACE=kubernetes → installée via le cluster, accès devzone workspace ports" {
    export DEVZONE_WORKSPACE=kubernetes
    touch "$BATS_TEST_TMPDIR/svc"
    printf 'cluster=kind-devzone\nmysql=on\n' >"$DEVZONE_ETAT"
    run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"installée : local access: devzone workspace ports"* ]] || false
    ! grep -q 'get statefulset' "$BATS_TEST_TMPDIR/kubectl.log" 2>/dev/null || false
}

@test "resume : DEVZONE_WORKSPACE=kubernetes → service absent → application attendue" {
    export DEVZONE_WORKSPACE=kubernetes
    printf 'cluster=kind-devzone\nmysql=on\n' >"$DEVZONE_ETAT"
    run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"attendue : devzone appliquer"* ]] || false
    ! grep -q 'get statefulset' "$BATS_TEST_TMPDIR/kubectl.log" 2>/dev/null || false
}

@test "desactiver mysql : sans --oui ni terminal, volume garde, aucun delete namespace" {
    mkdir -p "$SECRETS"
    printf 'MYSQL_PASSWORD=mdproot\n' >"$SECRETS/root.env"
    touch "$BATS_TEST_TMPDIR/ns" "$BATS_TEST_TMPDIR/sts" "$BATS_TEST_TMPDIR/secret"
    printf 'cluster=kind-devzone\nmysql=on\n' >"$DEVZONE_ETAT"
    run bash "$DEVZONE" desactiver mysql
    [ "$status" -eq 0 ] || false
    grep -q 'delete statefulset/mysql service/mysql' "$BATS_TEST_TMPDIR/kubectl.log" || false
    ! grep -q 'delete namespace devzone-mysql' "$BATS_TEST_TMPDIR/kubectl.log" 2>/dev/null || false
    grep -qx 'mysql=off' "$DEVZONE_ETAT" || false
    [ "$(cat "$SECRETS/root.env")" = "MYSQL_PASSWORD=mdproot" ] || false
    [[ "$output" == *"✔ mysql retiré du cluster ; volume donnees-mysql-0 et bases gardés : devzone mysql volume"* ]] || false
}

@test "desactiver mysql --oui : confirmation donnée, namespace et volumes supprimés" {
    touch "$BATS_TEST_TMPDIR/ns" "$BATS_TEST_TMPDIR/sts" "$BATS_TEST_TMPDIR/secret"
    printf 'cluster=kind-devzone\nmysql=on\n' >"$DEVZONE_ETAT"
    run bash "$DEVZONE" desactiver mysql --oui
    [ "$status" -eq 0 ] || false
    grep -q 'delete statefulset/mysql service/mysql' "$BATS_TEST_TMPDIR/kubectl.log" || false
    grep -q 'delete namespace devzone-mysql' "$BATS_TEST_TMPDIR/kubectl.log" || false
    grep -qx 'mysql=off' "$DEVZONE_ETAT" || false
    [[ "$output" == *"✔ namespace devzone-mysql et volume supprimés ; workspace/.mysql/root.env gardé"* ]] || false
}

@test "desactiver mysql en terminal : N retire le serveur et garde le volume" {
    mkdir -p "$SECRETS"
    printf 'MYSQL_PASSWORD=mdproot\n' >"$SECRETS/root.env"
    touch "$BATS_TEST_TMPDIR/ns" "$BATS_TEST_TMPDIR/sts" "$BATS_TEST_TMPDIR/secret"
    printf 'cluster=kind-devzone\nmysql=on\n' >"$DEVZONE_ETAT"
    DEVZONE_INTERACTIF=1 run bash "$DEVZONE" desactiver mysql <<<"n"
    [ "$status" -eq 0 ] || false
    grep -q 'delete statefulset/mysql service/mysql' "$BATS_TEST_TMPDIR/kubectl.log" || false
    ! grep -q 'delete namespace devzone-mysql' "$BATS_TEST_TMPDIR/kubectl.log" 2>/dev/null || false
    grep -qx 'mysql=off' "$DEVZONE_ETAT" || false
    [[ "$output" == *"Désactiver mysql retire le serveur"* ]] || false
    [[ "$output" == *"volume donnees-mysql-0 et bases gardés"* ]] || false
    [ "$(cat "$SECRETS/root.env")" = "MYSQL_PASSWORD=mdproot" ] || false
}

@test "desactiver mysql en terminal : o supprime aussi le namespace" {
    touch "$BATS_TEST_TMPDIR/ns" "$BATS_TEST_TMPDIR/sts" "$BATS_TEST_TMPDIR/secret"
    printf 'cluster=kind-devzone\nmysql=on\n' >"$DEVZONE_ETAT"
    DEVZONE_INTERACTIF=1 run bash "$DEVZONE" desactiver mysql <<<"o"
    [ "$status" -eq 0 ] || false
    grep -q 'delete statefulset/mysql service/mysql' "$BATS_TEST_TMPDIR/kubectl.log" || false
    grep -q 'delete namespace devzone-mysql' "$BATS_TEST_TMPDIR/kubectl.log" || false
    grep -qx 'mysql=off' "$DEVZONE_ETAT" || false
    [[ "$output" == *"✔ namespace devzone-mysql et volume supprimés ; workspace/.mysql/root.env gardé"* ]] || false
}

@test "activer mysql : ecrit la ligne puis applique (changer pour application du catalogue)" {
    printf 'cluster=kind-devzone\nmysql=off\n' >"$DEVZONE_ETAT"
    run bash "$DEVZONE" activer mysql
    [ "$status" -eq 0 ] || false
    grep -qx 'mysql=on' "$DEVZONE_ETAT" || false
    grep -q 'image: mysql:8.4' "$BATS_TEST_TMPDIR/apply.log" || false
}

@test "devzone catalogue liste les applications" {
    run bash "$DEVZONE" catalogue
    [ "$status" -eq 0 ] || false
    [[ "$output" == *"mysql"* ]] || false
    [[ "$output" == *"disponible"* ]] || false
}

@test "etat --json contient une rubrique applications" {
    run bash "$DEVZONE" etat --json
    [ "$status" -eq 0 ] || false
    printf '%s' "$output" | jq -e '.applications | type == "array"' >/dev/null || false
}

@test "resume : avertit d'un volume mysql non utilisé" {
    touch "$BATS_TEST_TMPDIR/ns" "$BATS_TEST_TMPDIR/sts" "$BATS_TEST_TMPDIR/ready"
    printf 'cluster=kind-devzone\nmysql=on\n' >"$DEVZONE_ETAT"
    printf 'data' >"$BATS_TEST_TMPDIR/claim"
    printf 'data-mysql-0\nancien-mysql-0\n' >"$BATS_TEST_TMPDIR/pvcs"
    run bash "$DEVZONE"
    [ "$status" -eq 0 ] || false
    [[ "$output" == *"⚠ volume ancien-mysql-0 non utilisé : devzone mysql volume"* ]] || false
    [[ "$output" != *"data-mysql-0 non utilisé"* ]] || false
}
