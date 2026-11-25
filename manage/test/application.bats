#!/usr/bin/env bats
# Single application (#341): devzone repairs, starts, installs metrics-server
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
    mkdir -p "$T/app/gitlab" "$T/app/postgres" "$T/app/catalog/mysql" "$T/bin" "$DEVZONE_ROOT"
    cp "$RACINE_TEST/.devcontainer/devzone" "$APP"
    cp "$RACINE_TEST"/.devcontainer/devzone-*.sh "$T/app/"
    cp "$RACINE_TEST/.devcontainer/help.sh" "$T/app/help.sh"
    cp "$RACINE_TEST/.devcontainer/cluster.sh" "$T/app/cluster.sh"
    cp "$RACINE_TEST/.devcontainer/state.sh" "$T/app/state.sh"
    cp "$RACINE_TEST/.devcontainer/state-lock.sh" "$T/app/state-lock.sh"
    cp "$RACINE_TEST/.devcontainer/state-gitops.sh" "$T/app/state-gitops.sh"
    cp "$RACINE_TEST/.devcontainer/kube-reachable.sh" "$T/app/kube-reachable.sh"
    cp "$RACINE_TEST/.devcontainer/kube-account.sh" "$T/app/kube-account.sh"
    mkdir -p "$T/app/ai"
    cp "$RACINE_TEST/.devcontainer/ai/host-models.sh" "$T/app/ai/host-models.sh"
    cp "$RACINE_TEST/.devcontainer/ai/host-check.sh" "$T/app/ai/host-check.sh"
    cp "$RACINE_TEST/.devcontainer/ai/host-check.message" "$T/app/ai/host-check.message"
    chmod +x "$APP"
    export PATH="$T/bin:$PATH"

    cat >"$T/app/ports.sh" <<'PORTS'
#!/usr/bin/env bash
printf 'ports %s\n' "$*" >>"$BATS_TEST_TMPDIR/actions.log"
PORTS
    cat >"$T/app/ports-auto.sh" <<'PORTS_AUTO'
#!/usr/bin/env bash
printf 'ports-auto %s\n' "$*" >>"$BATS_TEST_TMPDIR/actions.log"
PORTS_AUTO
    cat >"$T/app/password.sh" <<'PASSWORD'
#!/usr/bin/env bash
printf 'password %s\n' "$*" >>"$BATS_TEST_TMPDIR/actions.log"
[ ! -f "$BATS_TEST_TMPDIR/failed-password" ] || { echo "credentials unavailable"; exit 1; }
PASSWORD
    cat >"$T/app/gitlab/gitlab.sh" <<'GITLAB'
#!/usr/bin/env bash
printf 'gitlab %s\n' "$*" >>"$BATS_TEST_TMPDIR/actions.log"
GITLAB
    cat >"$T/app/postgres/postgres.sh" <<'POSTGRES'
#!/usr/bin/env bash
printf 'postgres %s\n' "$*" >>"$BATS_TEST_TMPDIR/actions.log"
POSTGRES
    cat >"$T/app/catalog/catalog-watcher.sh" <<'VEILLEUR'
#!/usr/bin/env bash
printf 'catalog-watcher %s\n' "$*" >>"$BATS_TEST_TMPDIR/actions.log"
VEILLEUR
    cat >"$T/app/catalog/mysql/mysql.sh" <<'MYSQL'
#!/usr/bin/env bash
printf 'mysql %s\n' "$*" >>"$BATS_TEST_TMPDIR/actions.log"
MYSQL
    cat >"$T/app/startup.sh" <<'DEMARRAGE'
#!/usr/bin/env bash
printf 'startup %s\n' "$*" >>"$BATS_TEST_TMPDIR/actions.log"
DEMARRAGE
    cat >"$T/app/metrics-server.sh" <<'METRICS'
#!/usr/bin/env bash
printf 'metrics %s\n' "$*" >>"$BATS_TEST_TMPDIR/actions.log"
METRICS
    chmod +x "$T/app"/*.sh "$T/app/gitlab/gitlab.sh" "$T/app/postgres/postgres.sh" "$T/app/catalog/catalog-watcher.sh" "$T/app/catalog/mysql/mysql.sh"
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
    *"create token"*)
        echo jeton-de-test
        ;;
    *"auth can-i"*)
        echo yes
        ;;
esac
KUBE
    chmod +x "$T/bin/kubectl"
}

@test "design: devzone is the application and the docs no longer expose the scripts" {
    aide="$(bash "$APP" --help)"
    for commande in repair start metrics use; do
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
    [[ "$output" == *"✔ ports relay"* ]] || false
    [[ "$output" == *"✔ ports auto watcher"* ]] || false
    [[ "$output" == *"✔ credentials"* ]] || false
    [[ "$(cat "$T/actions.log")" == *"ports restart"* ]] || false
    [[ "$(cat "$T/actions.log")" == *"ports-auto demarrer"* ]] || false
    [[ "$(cat "$T/actions.log")" == *"password regenerer"* ]] || false
}

@test "repair: active gitlab and postgres are repaired too" {
    printf 'gitlab=on\npostgres=on\n' >"$DEVZONE_STATE"
    run bash "$APP" repair
    [ "$status" -eq 0 ]
    [[ "$(cat "$T/actions.log")" == *"gitlab hote-poser"* ]] || false
    [[ "$(cat "$T/actions.log")" == *"gitlab relay-start"* ]] || false
    [[ "$(cat "$T/actions.log")" == *"postgres relay-start"* ]] || false
}

@test "repair: the kubernetes account token is renewed" {
    faux_kubectl
    printf 'cluster=docker-desktop\n' >"$DEVZONE_STATE"
    run bash "$APP" repair
    [ "$status" -eq 0 ]
    [[ "$output" == *"✔ kubernetes account"* ]] || false
    grep -q 'create token devzone-agent -n devzone-system --duration=24h' "$T/kubectl.log" || false
}

@test "repair: without a services cluster, no kubernetes account token" {
    run bash "$APP" repair
    [ "$status" -eq 0 ]
    [[ "$output" != *"kubernetes account"* ]] || false
    ! grep -q 'create token' "$T/kubectl.log" 2>/dev/null || false
}

@test "repair: starts the catalog watcher" {
    run bash "$APP" repair
    [ "$status" -eq 0 ]
    [[ "$output" == *"✔ catalog watcher"* ]] || false
    [[ "$(cat "$T/actions.log")" == *"catalog-watcher demarrer"* ]] || false
}

@test "repair: a failed element shows its reason and code 1" {
    : >"$T/failed-password"
    run bash "$APP" repair
    [ "$status" -eq 1 ]
    [[ "$output" == *"✖ credentials : credentials unavailable"* ]] || false
    [[ "$(cat "$T/actions.log")" == *"ports restart"* ]] || false
}

@test "start: runs the full startup" {
    run bash "$APP" start
    [ "$status" -eq 0 ]
    [ "$(cat "$T/actions.log")" = "startup " ]
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

@test "repair: Kubernetes workspace, no auto ports watcher (#517)" {
    DEVZONE_WORKSPACE=kubernetes run bash "$APP" repair
    [ "$status" -eq 0 ]
    [[ "$output" != *"ports auto watcher"* ]] || false
    [[ "$(cat "$T/actions.log")" != *"ports-auto demarrer"* ]] || false
    [[ "$(cat "$T/actions.log")" == *"password regenerer"* ]] || false
}
