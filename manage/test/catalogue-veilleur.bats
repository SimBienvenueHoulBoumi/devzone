#!/usr/bin/env bats
# Veilleur du catalogue (#414) : garde-fou et un tour qui detecte un
# changement de date de .devzone.modules. Jamais de boucle en arriere-plan.

setup() {
    load commun
    relais_docker_isole
    kube_isole
    VEILLEUR="$BATS_TEST_DIRNAME/../../.devcontainer/catalogue/catalogue-veilleur.sh"
    CATALOGUE="$BATS_TEST_DIRNAME/../../.devcontainer/catalogue.sh"
    export HOME="$BATS_TEST_TMPDIR/home"
    export DEVZONE_RACINE="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_ETAT="$BATS_TEST_TMPDIR/modules"
    export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
    mkdir -p "$HOME" "$DEVZONE_RACINE/workspace" "$BATS_TEST_TMPDIR/bin"
    : >"$DEVZONE_KUBE_HOTE"
    : >"$DEVZONE_ETAT"
    : >"$BATS_TEST_TMPDIR/kubectl.log"
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
echo "kubectl $*" >>"$T/kubectl.log"
case "$*" in
    "config get-contexts -o name") echo "docker-desktop" ;;
    *"config view"*)
        for c in docker-desktop kind-devzone; do
            if [[ "$*" == *\"$c\"* ]]; then echo "$c"; break; fi || false
        done
        if [[ "$*" == *'.cluster.server'* ]]; then echo "https://127.0.0.1:6443"; fi || false
        ;;
    *"get --raw /readyz"*)
        [[ "$*" == *"--context docker-desktop"* ]] || exit 1 || false
        ;;
    *"apply -f -"*) cat >>"$T/apply.log" ;;
    *"create namespace"*) touch "$T/ns" ;;
    *"label namespace"*) ;;
    *"get namespace devzone-mysql"*) [ -f "$T/ns" ]; exit $? ;;
    *"readyReplicas"*) [ -f "$T/ready" ] && echo 1 || echo 0 ;;
    *"get statefulset mysql"*) [ -f "$T/sts" ]; exit $? ;;
    *"get secret mysql-admin"*) [ -f "$T/secret" ]; exit $? ;;
    *"create secret generic mysql-admin"*) touch "$T/secret" ;;
    *"rollout status"*) ;;
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
echo "mdpveilleur"
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
    bash "$BATS_TEST_DIRNAME/../../.devcontainer/catalogue/mysql/mysql.sh" relais-arreter >/dev/null 2>&1 || true
}

@test "veilleur : refuse sans DEVZONE_CATALOGUE_REEL" {
    run bash "$VEILLEUR" demarrer
    [ "$status" -eq 2 ] || false
    [[ "$output" == *"refusé ici"* ]] || false
}

@test "veilleur : refuse sous bats meme avec DEVZONE_CATALOGUE_REEL=oui" {
    DEVZONE_CATALOGUE_REEL=oui run bash "$VEILLEUR" demarrer
    [ "$status" -eq 2 ] || false
    [[ "$output" == *"refusé sous bats"* ]] || false
}

@test "veilleur : un tour applique quand .devzone.modules change" {
    touch "$BATS_TEST_TMPDIR/ns" "$BATS_TEST_TMPDIR/sts" "$BATS_TEST_TMPDIR/ready"
    printf 'cluster=kind-devzone\nmysql=on\n' >"$DEVZONE_ETAT"
    run bash "$VEILLEUR" tour
    [ "$status" -eq 0 ] || false
    premier="$(wc -l <"$BATS_TEST_TMPDIR/kubectl.log")"
    sleep 1.1
    touch "$DEVZONE_ETAT"
    run bash "$VEILLEUR" tour
    [ "$status" -eq 0 ] || false
    second="$(wc -l <"$BATS_TEST_TMPDIR/kubectl.log")"
    [ "$second" -gt "$premier" ] || false
}
