#!/usr/bin/env bats
# Catalog watcher (#414): guard, and one tick that detects a change of the
# date of .devzone.modules. Never a loop in the background.

setup() {
    load commun
    kube_isole
    VEILLEUR="$BATS_TEST_DIRNAME/../../.devcontainer/catalog/catalog-watcher.sh"
    CATALOGUE="$BATS_TEST_DIRNAME/../../.devcontainer/catalog.sh"
    export HOME="$BATS_TEST_TMPDIR/home"
    export DEVZONE_ROOT="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_STATE="$BATS_TEST_TMPDIR/modules"
    export DEVZONE_KUBE_HOST="$BATS_TEST_TMPDIR/hote.config"
    mkdir -p "$HOME" "$DEVZONE_ROOT/workspace" "$BATS_TEST_TMPDIR/bin"
    : >"$DEVZONE_KUBE_HOST"
    : >"$DEVZONE_STATE"
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
    DEVZONE_STATE="$DEVZONE_STATE" DEVZONE_ROOT="$DEVZONE_ROOT" bash "$BATS_TEST_DIRNAME/../../.devcontainer/devzone" mysql relay-stop >/dev/null 2>&1 || true
}

@test "watcher: refused without DEVZONE_CATALOG_REAL" {
    run bash "$VEILLEUR" demarrer
    [ "$status" -eq 2 ] || false
    [[ "$output" == *"refused here"* ]] || false
}

@test "watcher: refused under bats even with DEVZONE_CATALOG_REAL=yes" {
    DEVZONE_CATALOG_REAL=yes run bash "$VEILLEUR" demarrer
    [ "$status" -eq 2 ] || false
    [[ "$output" == *"refused under bats"* ]] || false
}

@test "watcher: root deduced = repository, two levels above the script" {
    unset DEVZONE_ROOT DEVZONE_STATE DEVZONE_CATALOG_WATCHER_DIR
    depot="$BATS_TEST_TMPDIR/depot"
    mkdir -p "$depot/.devcontainer/catalog"
    cp "$VEILLEUR" "$depot/.devcontainer/catalog/catalog-watcher.sh"
    cat >"$depot/.devcontainer/catalog.sh" <<'CATALOGUE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$BATS_TEST_TMPDIR/catalogue.log"
CATALOGUE
    : >"$depot/.devzone.modules"
    run bash "$depot/.devcontainer/catalog/catalog-watcher.sh" tour
    [ "$status" -eq 0 ] || false
    [ -f "$depot/.devzone.catalog-watcher/dernier" ] || false
    [ "$(cat "$BATS_TEST_TMPDIR/catalogue.log")" = "apply" ] || false
}

@test "watcher: start whose loop dies at once returns a non-zero code" {
    base="$BATS_TEST_TMPDIR/veilleur"
    mkdir -p "$base"
    cat >"$BATS_TEST_TMPDIR/bin/nohup" <<NOHUP
#!/usr/bin/env bash
mkdir -p "$base/lock"
echo \$\$ >"$base/lock/pid"
exit 0
NOHUP
    chmod +x "$BATS_TEST_TMPDIR/bin/nohup"
    run env -u BATS_TEST_TMPDIR \
        DEVZONE_CATALOG_REAL=yes \
        DEVZONE_CATALOG_WATCHER_DIR="$base" \
        bash "$VEILLEUR" demarrer
    [ "$status" -ne 0 ] || false
    [[ "$output" == *"cannot start"* ]] || false
}

@test "watcher: a tick applies when .devzone.modules changes" {
    touch "$BATS_TEST_TMPDIR/ns" "$BATS_TEST_TMPDIR/sts" "$BATS_TEST_TMPDIR/ready"
    printf 'cluster=kind-devzone\nmysql=on\n' >"$DEVZONE_STATE"
    run bash "$VEILLEUR" tour
    [ "$status" -eq 0 ] || false
    premier="$(wc -l <"$BATS_TEST_TMPDIR/kubectl.log")"
    sleep 1.1
    touch "$DEVZONE_STATE"
    run bash "$VEILLEUR" tour
    [ "$status" -eq 0 ] || false
    second="$(wc -l <"$BATS_TEST_TMPDIR/kubectl.log")"
    [ "$second" -gt "$premier" ] || false
}
