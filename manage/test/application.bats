#!/usr/bin/env bats
# Single application (#341): devzone repairs, installs metrics-server
# and switches the working cluster. Copy of devzone in $BATS_TEST_TMPDIR with
# fake scripts: no real script, cluster or socket touched.

setup() {
    load commun
    kube_isole
    RACINE_TEST="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    T="$BATS_TEST_TMPDIR"
    APP="$T/app/devzone"
    export DEVZONE_ROOT="$T/racine"
    export DEVZONE_STATE="$T/modules"
    mkdir -p "$T/app/postgres" "$T/app/catalog/mysql" "$T/bin" "$DEVZONE_ROOT"
    cp "$RACINE_TEST/.devcontainer/devzone" "$APP"
    cp "$RACINE_TEST"/.devcontainer/devzone-*.sh "$T/app/"
    cp "$RACINE_TEST/.devcontainer/help.sh" "$T/app/help.sh"
    cp "$RACINE_TEST/.devcontainer/cluster.sh" "$T/app/cluster.sh"
    cp "$RACINE_TEST/.devcontainer/kube-account.sh" "$T/app/kube-account.sh"
    mkdir -p "$T/app/ai"
    cp "$RACINE_TEST/.devcontainer/ai/host-models.sh" "$T/app/ai/host-models.sh"
    cp "$RACINE_TEST/.devcontainer/ai/host-check.sh" "$T/app/ai/host-check.sh"
    cp "$RACINE_TEST/.devcontainer/ai/host-check.message" "$T/app/ai/host-check.message"
    mkdir -p "$T/app/bin"
    cp "$RACINE_TEST"/.devcontainer/bin/devzone-pod-linux-* "$T/app/bin/" 2>/dev/null || true
    chmod +x "$APP"
    export PATH="$T/bin:$PATH"

    cat >"$T/app/ports.sh" <<'PORTS'
#!/usr/bin/env bash
printf 'ports %s\n' "$*" >>"$BATS_TEST_TMPDIR/actions.log"
PORTS
    cat >"$T/app/password.sh" <<'PASSWORD'
#!/usr/bin/env bash
printf 'password %s\n' "$*" >>"$BATS_TEST_TMPDIR/actions.log"
[ ! -f "$BATS_TEST_TMPDIR/failed-password" ] || { echo "credentials unavailable"; exit 1; }
PASSWORD
    cat >"$T/app/catalog/catalog-watcher.sh" <<'VEILLEUR'
#!/usr/bin/env bash
printf 'catalog-watcher %s\n' "$*" >>"$BATS_TEST_TMPDIR/actions.log"
VEILLEUR
    cat >"$T/app/metrics-server.sh" <<'METRICS'
#!/usr/bin/env bash
printf 'metrics %s\n' "$*" >>"$BATS_TEST_TMPDIR/actions.log"
METRICS
    chmod +x "$T/app"/*.sh "$T/app/catalog/catalog-watcher.sh"
    cat >"$T/bin/devzone" <<'DEVZONE'
#!/usr/bin/env bash
echo "devzone $*" >>"$BATS_TEST_TMPDIR/devzone.log"
printf 'devzone %s\n' "$*" >>"$BATS_TEST_TMPDIR/actions.log"
case "$*" in
    "cluster clean"*) exit 0 ;;
    "account token"*) exit 0 ;;
    "account fresh"*) exit 0 ;;
    "passwords regenerate")
        [ ! -f "$BATS_TEST_TMPDIR/failed-password" ] || { echo "credentials unavailable" >&2; exit 1; }
        ;;
    gitlab\ *) exit 0 ;;
    postgres\ *|mysql\ *) exit 0 ;;
esac
exit 0
DEVZONE
    chmod +x "$T/bin/devzone"
}

faux_kubectl() {
    cat >"$T/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
printf 'kubectl %s\n' "$*" >>"$T/kubectl.log"
case "$*" in
    "config get-contexts -o name")
        printf '%s\n' docker-desktop prod
        ;;
    *"config view"*)
        echo x
        ;;
esac
KUBE
    chmod +x "$T/bin/kubectl"
}

@test "design: devzone is the application and the docs no longer expose the scripts" {
    aide="$(bash "$APP" --help)"
    for commande in repair metrics use; do
        [[ "$aide" == *"devzone $commande"* ]] || { echo "help: $commande missing"; false; }
    done
    for doc in README.md manage/docs/reference.md; do
        contenu="$(awk '/^## For contributors/{exit} {print}' "$RACINE_TEST/$doc")"
        [[ "$contenu" != *"bash .devcontainer/"* ]] || { echo "$doc: direct script"; false; }
        [[ "$contenu" != *"kubectl config use-context"* ]] || { echo "$doc: direct kubectl"; false; }
        if grep -qE 'DEVZONE_[A-Z_]+=' <<<"$contenu"; then
            echo "$doc: internal variable"
            false
        fi
    done
}

@test "repair: each repaired element and code 0" {
    run bash "$APP" repair
    [ "$status" -eq 0 ]
    [[ "$output" == *"✔ catalog watcher"* ]] || false
    [[ "$output" == *"✔ credentials"* ]] || false
    [[ "$(cat "$T/actions.log")" == *"catalog-watcher start"* ]] || false
    [[ "$(cat "$T/actions.log")" == *"devzone passwords regenerate"* ]] || false
}

@test "repair: active gitlab and postgres are repaired too" {
    printf 'gitlab=on\npostgres=on\n' >"$DEVZONE_STATE"
    run bash "$APP" repair
    [ "$status" -eq 0 ]
    [[ "$(cat "$T/actions.log")" == *"devzone gitlab host-set"* ]] || false
    [[ "$(cat "$T/actions.log")" == *"devzone gitlab relay-start"* ]] || false
    [[ "$(cat "$T/actions.log")" == *"devzone postgres relay-start"* ]] || false
}

@test "repair: starts the catalog watcher" {
    run bash "$APP" repair
    [ "$status" -eq 0 ]
    [[ "$output" == *"✔ catalog watcher"* ]] || false
    [[ "$(cat "$T/actions.log")" == *"catalog-watcher start"* ]] || false
}

@test "repair: a failed element shows its reason and code 1" {
    : >"$T/failed-password"
    run bash "$APP" repair
    [ "$status" -eq 1 ]
    [[ "$output" == *"✖ credentials : credentials unavailable"* ]] || false
    [[ "$(cat "$T/actions.log")" == *"devzone passwords regenerate"* ]] || false
}

@test "metrics: passes the context and the options" {
    run bash "$APP" metrics docker-desktop --force
    [ "$status" -eq 0 ]
    [ "$(cat "$T/actions.log")" = "metrics docker-desktop --force" ]
}

@test "use: switches the context without touching the services cluster" {
    faux_kubectl
    printf 'cluster=kind-devzone\n' >"$DEVZONE_STATE"
    run bash "$APP" use docker-desktop
    [ "$status" -eq 0 ]
    [[ "$output" == *"working cluster: docker-desktop"* ]] || false
    [[ "$(cat "$T/kubectl.log")" == *"config use-context docker-desktop"* ]] || false
    [ "$(cat "$DEVZONE_STATE")" = "cluster=kind-devzone" ]
}

@test "use: unknown context refused without switching" {
    faux_kubectl
    run bash "$APP" use inconnu
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown context: inconnu"* ]] || false
    [[ "$(cat "$T/kubectl.log")" != *"use-context"* ]] || false
}

@test "use: remote cluster refused without confirmation" {
    faux_kubectl
    run bash "$APP" use prod
    [ "$status" -eq 2 ]
    [[ "$output" == *"remote cluster refused: prod"* ]] || false
    [[ "$(cat "$T/kubectl.log")" != *"use-context"* ]] || false
}

@test "use: exact --confirm accepted, other value refused" {
    faux_kubectl
    run bash "$APP" use prod --confirm prod
    [ "$status" -eq 0 ]
    [[ "$(cat "$T/kubectl.log")" == *"config use-context prod"* ]] || false

    : >"$T/kubectl.log"
    run bash "$APP" use prod --confirm autre
    [ "$status" -eq 2 ]
    [[ "$output" == *"remote cluster refused: prod"* ]] || false
    [[ "$(cat "$T/kubectl.log")" != *"use-context"* ]] || false
}
