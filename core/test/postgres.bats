#!/usr/bin/env bats
# Module postgres (#280) et cluster de devzone (cluster.sh) : choix du
# cluster, installation, bases par projet, désinstallation, changement de
# cluster. Faux kubectl, kind, openssl et nohup dans le PATH : aucun cluster
# touché. kubectl tient son état dans des fichiers de $BATS_TEST_TMPDIR et
# journalise ses arguments (kubectl.log), ce qu'il reçoit sur stdin
# (apply.log, sql.log).

setup() {
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
    # Cluster de l'hôte visible (module kubernetes actif) : docker-desktop
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
    *"get --raw /readyz"*)
        case "$*" in *"--context ${FAUX_INJOIGNABLE:-aucun} "*) exit 1 ;; esac ;;
    *"get namespace devzone-postgres"*) [ -f "$T/ns" ]; exit $? ;;
    *"get namespaces -l"*) [ -z "${FAUX_AUTRES_NS:-}" ] || echo "namespace/autre" ;;
    *"create namespace"*) printf 'kind: Namespace\nmetadata:\n  name: devzone-postgres\n' ;;
    *"apply -f -"*)
        cat >>"$T/apply.log"
        touch "$T/ns" ;;
    *"get secret postgres-admin -o jsonpath"*) printf 'YWRtaW4tZXhpc3RhbnQ=' ;;
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
    # Mot de passe différent à chaque appel : un mot de passe gardé se voit
    cat >"$BATS_TEST_TMPDIR/bin/openssl" <<'SSL'
#!/usr/bin/env bash
n="$(cat "$BATS_TEST_TMPDIR/openssl.n" 2>/dev/null || echo 0)"
n=$((n + 1)); echo "$n" >"$BATS_TEST_TMPDIR/openssl.n"
echo "mdpsecret$n"
SSL
    # nohup : le relais journalisé, puis un sleep tué par relais-arreter
    cat >"$BATS_TEST_TMPDIR/bin/nohup" <<'NOHUP'
#!/usr/bin/env bash
echo "nohup $*" >>"$BATS_TEST_TMPDIR/nohup.log"
exec sleep 300
NOHUP
    chmod +x "$BATS_TEST_TMPDIR"/bin/*
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

teardown() {
    bash "$POSTGRES" relais-arreter >/dev/null 2>&1 || true
}

actif_sur() {
    printf 'postgres=on\ncluster=%s\n' "$1" >"$DEVZONE_ETAT"
    touch "$BATS_TEST_TMPDIR/ns" "$BATS_TEST_TMPDIR/secret"
}

@test "postgres : module connu, désactivé par défaut" {
    run bash "$DEVZONE"
    [[ "$output" == *"○ module postgres"*"devzone activer postgres"* ]] || false
}

@test "activer sans terminal : kind dédié créé, PostgreSQL appliqué, relais lancé" {
    run bash "$DEVZONE" activer postgres </dev/null
    [ "$status" -eq 0 ]
    grep -qx 'cluster=kind-devzone' "$DEVZONE_ETAT"
    grep -q 'kind create cluster --name devzone' "$BATS_TEST_TMPDIR/kind.log"
    grep -q 'kubectl --context kind-devzone -n devzone-postgres create secret generic postgres-admin' "$BATS_TEST_TMPDIR/kubectl.log"
    grep -q 'image: postgres:16' "$BATS_TEST_TMPDIR/apply.log"
    grep -q 'storage: 5Gi' "$BATS_TEST_TMPDIR/apply.log"
    grep -q 'port-forward --address 127.0.0.1' "$BATS_TEST_TMPDIR/nohup.log"
    grep -q 'kind-devzone devzone-postgres svc/postgres 5432:5432$' "$BATS_TEST_TMPDIR/nohup.log"
    [[ "$output" == *"127.0.0.1:5432"* ]] || false
}

@test "activer --contexte docker-desktop : pas de kind, tout sur ce contexte" {
    run bash "$DEVZONE" activer postgres --contexte docker-desktop </dev/null
    [ "$status" -eq 0 ]
    grep -qx 'cluster=docker-desktop' "$DEVZONE_ETAT"
    ! grep -q 'create cluster' "$BATS_TEST_TMPDIR/kind.log" 2>/dev/null || false
    grep -q 'kubectl --context docker-desktop apply -f -' "$BATS_TEST_TMPDIR/kubectl.log"
    ! grep -q 'kind-devzone' "$BATS_TEST_TMPDIR/kubectl.log" || false
}

@test "activer --contexte inconnu ou injoignable : refus code 2, rien installé, module inactif" {
    run bash "$DEVZONE" activer postgres --contexte inconnu </dev/null
    [ "$status" -eq 2 ]
    [[ "$output" == *"cluster inconnu ou injoignable : inconnu"* ]] || false
    grep -qx 'postgres=off' "$DEVZONE_ETAT"
    ! grep -q '^cluster=' "$DEVZONE_ETAT" || false
    [ ! -f "$BATS_TEST_TMPDIR/apply.log" ]

    FAUX_INJOIGNABLE=docker-desktop run bash "$DEVZONE" activer postgres --contexte docker-desktop </dev/null
    [ "$status" -eq 2 ]
}

@test "activer sans module kubernetes : seul le kind dédié est possible" {
    rm -f "$DEVZONE_KUBE_HOTE"
    run bash "$DEVZONE" activer postgres --contexte docker-desktop </dev/null
    [ "$status" -eq 2 ]
}

@test "activer en terminal : menu, choix 2 = cluster de l'hôte" {
    DEVZONE_INTERACTIF=1 run bash "$DEVZONE" activer postgres <<<"2"
    [ "$status" -eq 0 ]
    [[ "$output" == *"1) kind-devzone"*"2) docker-desktop"* ]] || false
    grep -qx 'cluster=docker-desktop' "$DEVZONE_ETAT"
}

@test "activer en terminal : Entrée = kind dédié ; choix hors liste refusé" {
    DEVZONE_INTERACTIF=1 run bash "$DEVZONE" activer postgres <<<""
    [ "$status" -eq 0 ]
    grep -qx 'cluster=kind-devzone' "$DEVZONE_ETAT"

    rm -f "$DEVZONE_ETAT"
    DEVZONE_INTERACTIF=1 run bash "$DEVZONE" activer postgres <<<"9"
    [ "$status" -eq 2 ]
    grep -qx 'postgres=off' "$DEVZONE_ETAT"
}

@test "activer --contexte autre que le cluster choisi : refus, devzone cluster indiqué" {
    printf 'cluster=kind-devzone\n' >"$DEVZONE_ETAT"
    run bash "$DEVZONE" activer postgres --contexte docker-desktop </dev/null
    [ "$status" -eq 2 ]
    [[ "$output" == *"devzone cluster docker-desktop"* ]] || false
}

@test "secret admin existant : jamais régénéré, copié en 600 sans être affiché" {
    touch "$BATS_TEST_TMPDIR/secret"
    printf 'cluster=kind-devzone\n' >"$DEVZONE_ETAT"
    run bash "$POSTGRES" installer
    [ "$status" -eq 0 ]
    ! grep -q 'create secret' "$BATS_TEST_TMPDIR/kubectl.log" || false
    [ "$(cat "$SECRETS/admin-password")" = admin-existant ]
    [ "$(stat -c %a "$SECRETS/admin-password" 2>/dev/null || stat -f %Lp "$SECRETS/admin-password")" = 600 ]
    [[ "$output" != *admin-existant* ]] || false
}

@test "creer : nom invalide ou réservé refusé (code 2)" {
    actif_sur kind-devzone
    for nom in Task 1abc "a-b" "x;drop" postgres; do
        run bash "$POSTGRES" creer "$nom"
        [ "$status" -eq 2 ]
    done
    [ ! -f "$BATS_TEST_TMPDIR/sql.log" ]
}

@test "creer : rôle, base, accès fermés aux autres, .env 600, mot de passe jamais affiché" {
    actif_sur docker-desktop
    run bash "$POSTGRES" creer taskmanager
    [ "$status" -eq 0 ]
    grep -q "CREATE ROLE taskmanager LOGIN" "$BATS_TEST_TMPDIR/sql.log"
    grep -q "CREATE DATABASE taskmanager OWNER taskmanager" "$BATS_TEST_TMPDIR/sql.log"
    grep -q "REVOKE CONNECT ON DATABASE taskmanager FROM PUBLIC" "$BATS_TEST_TMPDIR/sql.log"
    grep -q 'kubectl --context docker-desktop -n devzone-postgres exec -i postgres-0' "$BATS_TEST_TMPDIR/kubectl.log"
    ! grep -q mdpsecret "$BATS_TEST_TMPDIR/kubectl.log" || false
    grep -qx 'DB_URL=jdbc:postgresql://127.0.0.1:5432/taskmanager' "$SECRETS/taskmanager.env"
    grep -qx 'DB_USER=taskmanager' "$SECRETS/taskmanager.env"
    grep -qx 'DB_PASSWORD=mdpsecret1' "$SECRETS/taskmanager.env"
    [ "$(stat -c %a "$SECRETS/taskmanager.env" 2>/dev/null || stat -f %Lp "$SECRETS/taskmanager.env")" = 600 ]
    [[ "$output" != *mdpsecret* ]] || false
    [[ "$output" == *"$SECRETS/taskmanager.env"* ]] || false
}

@test "creer relancé : mot de passe gardé ; --nouveau-mdp : changé" {
    actif_sur kind-devzone
    bash "$POSTGRES" creer taskmanager
    bash "$POSTGRES" creer taskmanager
    grep -qx 'DB_PASSWORD=mdpsecret1' "$SECRETS/taskmanager.env"
    bash "$POSTGRES" creer taskmanager --nouveau-mdp
    grep -qx 'DB_PASSWORD=mdpsecret2' "$SECRETS/taskmanager.env"
}

@test "creer, liste, psql : module inactif → refus clair" {
    printf 'cluster=kind-devzone\n' >"$DEVZONE_ETAT"
    run bash "$POSTGRES" creer taskmanager
    [ "$status" -eq 2 ]
    [[ "$output" == *"devzone activer postgres"* ]] || false
    rm -f "$DEVZONE_ETAT"
    run bash "$POSTGRES" liste
    [ "$status" -eq 2 ]
}

@test "liste : bases et propriétaires" {
    actif_sur kind-devzone
    run bash "$DEVZONE" postgres liste
    [ "$status" -eq 0 ]
    [[ "$output" == *"taskmanager"*"propriétaire taskmanager"* ]] || false
}

@test "supprimer : sans terminal ni --oui refusé ; --oui : base, rôle et .env supprimés" {
    actif_sur kind-devzone
    bash "$POSTGRES" creer taskmanager
    : >"$BATS_TEST_TMPDIR/sql.log"
    run bash "$POSTGRES" supprimer taskmanager </dev/null
    [ "$status" -eq 2 ]
    [ ! -s "$BATS_TEST_TMPDIR/sql.log" ]
    run bash "$POSTGRES" supprimer taskmanager --oui
    [ "$status" -eq 0 ]
    grep -q "DROP DATABASE IF EXISTS taskmanager WITH (FORCE)" "$BATS_TEST_TMPDIR/sql.log"
    grep -q "DROP ROLE IF EXISTS taskmanager" "$BATS_TEST_TMPDIR/sql.log"
    [ ! -f "$SECRETS/taskmanager.env" ]
}

@test "supprimer en terminal : Entrée = abandon" {
    actif_sur kind-devzone
    DEVZONE_INTERACTIF=1 run bash "$POSTGRES" supprimer taskmanager <<<""
    [ "$status" -eq 0 ]
    [[ "$output" == *"Abandon"* ]] || false
    [ ! -f "$BATS_TEST_TMPDIR/sql.log" ]
}

@test "désactiver : namespace et secrets supprimés, kind dédié vide supprimé" {
    echo devzone >"$KIND_CLUSTERS"
    actif_sur kind-devzone
    mkdir -p "$SECRETS"
    run bash "$DEVZONE" desactiver postgres </dev/null
    [ "$status" -eq 0 ]
    grep -q 'kubectl --context kind-devzone delete namespace devzone-postgres' "$BATS_TEST_TMPDIR/kubectl.log"
    grep -q 'kind delete cluster --name devzone' "$BATS_TEST_TMPDIR/kind.log"
    [ ! -d "$SECRETS" ]
    grep -qx 'postgres=off' "$DEVZONE_ETAT"
}

@test "désactiver : kind dédié gardé s'il porte un autre service ; cluster de l'hôte jamais supprimé" {
    echo devzone >"$KIND_CLUSTERS"
    actif_sur kind-devzone
    FAUX_AUTRES_NS=1 run bash "$DEVZONE" desactiver postgres </dev/null
    ! grep -q 'kind delete' "$BATS_TEST_TMPDIR/kind.log" || false

    actif_sur docker-desktop
    run bash "$DEVZONE" desactiver postgres </dev/null
    grep -q 'kubectl --context docker-desktop delete namespace devzone-postgres' "$BATS_TEST_TMPDIR/kubectl.log"
    ! grep -q 'kind delete' "$BATS_TEST_TMPDIR/kind.log" || false
}

@test "désactiver en terminal : confirmation, Entrée = rien supprimé" {
    actif_sur kind-devzone
    DEVZONE_INTERACTIF=1 run bash "$DEVZONE" desactiver postgres <<<""
    [[ "$output" == *"Abandon"* ]] || false
    grep -qx 'postgres=on' "$DEVZONE_ETAT"
    ! grep -q 'delete namespace' "$BATS_TEST_TMPDIR/kubectl.log" 2>/dev/null || false
}

@test "état : désactivé, prêt sur le cluster avec le nombre de bases, relais arrêté" {
    run bash "$POSTGRES" etat
    [ "$output" = "désactivé" ]
    actif_sur docker-desktop
    run bash "$POSTGRES" etat
    [ "$output" = "prêt sur docker-desktop, relais arrêté : devzone appliquer" ]
    bash "$POSTGRES" relais-lancer
    run bash "$POSTGRES" etat
    [ "$output" = "prêt sur docker-desktop : 127.0.0.1:5432, 2 base(s)" ]
    run bash "$DEVZONE"
    [[ "$output" == *"✔ module postgres"*"prêt sur docker-desktop"* ]] || false
}

@test "relais : lancé une seule fois, arrêté par relais-arreter" {
    actif_sur kind-devzone
    bash "$POSTGRES" relais-lancer
    bash "$POSTGRES" relais-lancer
    [ "$(grep -c port-forward "$BATS_TEST_TMPDIR/nohup.log")" -eq 1 ]
    pid="$(cat "$SECRETS/relais.pid")"
    kill -0 "$pid"
    bash "$POSTGRES" relais-arreter
    sleep 0.2
    ! kill -0 "$pid" 2>/dev/null || false
    [ ! -f "$SECRETS/relais.pid" ]
}

@test "cluster : affichage, refus sans --oui hors terminal, déplacement avec --oui" {
    run bash "$DEVZONE" cluster
    [[ "$output" == *"aucun cluster choisi"* ]] || false

    actif_sur kind-devzone
    run bash "$DEVZONE" cluster
    [[ "$output" == *"kind-devzone (kind dédié"* ]] || false

    run bash "$DEVZONE" cluster docker-desktop </dev/null
    [ "$status" -eq 1 ]
    grep -qx 'cluster=kind-devzone' "$DEVZONE_ETAT"

    run bash "$DEVZONE" cluster docker-desktop --oui </dev/null
    [ "$status" -eq 0 ]
    grep -qx 'cluster=docker-desktop' "$DEVZONE_ETAT"
    grep -q 'kubectl --context kind-devzone delete namespace devzone-postgres' "$BATS_TEST_TMPDIR/kubectl.log"
    grep -q 'kubectl --context docker-desktop apply -f -' "$BATS_TEST_TMPDIR/kubectl.log"
}

@test "cluster : module inactif → choix seulement enregistré ; même cluster → rien" {
    run bash "$DEVZONE" cluster docker-desktop </dev/null
    [ "$status" -eq 0 ]
    grep -qx 'cluster=docker-desktop' "$DEVZONE_ETAT"
    [ ! -f "$BATS_TEST_TMPDIR/apply.log" ]
    run bash "$DEVZONE" cluster docker-desktop </dev/null
    [[ "$output" == *"déjà sur docker-desktop"* ]] || false
}

@test "appliquer : postgres actif, prêt sans relais → relais relancé, pas de réinstallation" {
    actif_sur kind-devzone
    run bash "$DEVZONE" appliquer
    [[ "$output" == *"relais relancé"* ]] || false
    [ ! -f "$BATS_TEST_TMPDIR/apply.log" ]
}
