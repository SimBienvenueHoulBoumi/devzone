#!/usr/bin/env bats
# Application unique (#341) : devzone répare, démarre, installe metrics-server
# et bascule le cluster de travail. Copie de devzone dans $BATS_TEST_TMPDIR avec
# des scripts factices : aucun script réel, cluster ni socket touché.

setup() {
    load commun
    kube_isole
    RACINE_TEST="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    T="$BATS_TEST_TMPDIR"
    APP="$T/app/devzone"
    export DEVZONE_RACINE="$T/racine"
    export DEVZONE_ETAT="$T/modules"
    mkdir -p "$T/app/gitlab" "$T/app/postgres" "$T/bin" "$DEVZONE_RACINE"
    cp "$RACINE_TEST/.devcontainer/devzone" "$APP"
    cp "$RACINE_TEST/.devcontainer/cluster.sh" "$T/app/cluster.sh"
    cp "$RACINE_TEST/.devcontainer/kube-joignable.sh" "$T/app/kube-joignable.sh"
    chmod +x "$APP"
    export PATH="$T/bin:$PATH"

    cat >"$T/app/docker-relais.sh" <<'RELAIS'
#!/usr/bin/env bash
printf 'relais %s %s\n' "${DEVZONE_RELAIS_REEL:-}" "$*" >>"$BATS_TEST_TMPDIR/actions.log"
[ ! -f "$BATS_TEST_TMPDIR/echec-relais" ] || { echo "socket indisponible"; exit 1; }
RELAIS
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
[ ! -f "$BATS_TEST_TMPDIR/echec-password" ] || { echo "identifiants indisponibles"; exit 1; }
PASSWORD
    cat >"$T/app/gitlab/gitlab.sh" <<'GITLAB'
#!/usr/bin/env bash
printf 'gitlab %s\n' "$*" >>"$BATS_TEST_TMPDIR/actions.log"
GITLAB
    cat >"$T/app/postgres/postgres.sh" <<'POSTGRES'
#!/usr/bin/env bash
printf 'postgres %s\n' "$*" >>"$BATS_TEST_TMPDIR/actions.log"
POSTGRES
    cat >"$T/app/demarrage.sh" <<'DEMARRAGE'
#!/usr/bin/env bash
printf 'demarrage %s\n' "$*" >>"$BATS_TEST_TMPDIR/actions.log"
DEMARRAGE
    cat >"$T/app/metrics-server.sh" <<'METRICS'
#!/usr/bin/env bash
printf 'metrics %s\n' "$*" >>"$BATS_TEST_TMPDIR/actions.log"
METRICS
    chmod +x "$T/app"/*.sh "$T/app/gitlab/gitlab.sh" "$T/app/postgres/postgres.sh"
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

@test "conception : devzone est l'application et la doc n'expose plus les scripts" {
    aide="$(bash "$APP" --help)"
    for commande in reparer demarrer metrics utiliser; do
        [[ "$aide" == *"devzone $commande"* ]] || { echo "aide : $commande absente"; false; }
    done
    for fichier in README.md manage/docs/reference.md; do
        contenu="$(awk '/^## Pour les contributeurs/{exit} {print}' "$RACINE_TEST/$fichier")"
        [[ "$contenu" != *"bash .devcontainer/"* ]] || { echo "$fichier : script direct"; false; }
        [[ "$contenu" != *"kubectl config use-context"* ]] || { echo "$fichier : kubectl direct"; false; }
        if grep -qE 'DEVZONE_[A-Z_]+=' <<<"$contenu"; then
            echo "$fichier : variable interne"
            false
        fi
    done
}

@test "reparer : chaque élément réparé et code 0" {
    run bash "$APP" reparer
    [ "$status" -eq 0 ]
    [[ "$output" == *"✔ relais Docker"* ]] || false
    [[ "$output" == *"✔ relais de ports"* ]] || false
    [[ "$output" == *"✔ identifiants"* ]] || false
    [[ "$(cat "$T/actions.log")" == *"relais oui"* ]] || false
    [[ "$(cat "$T/actions.log")" == *"ports relancer"* ]] || false
    [[ "$(cat "$T/actions.log")" == *"password regenerer"* ]] || false
}

@test "reparer : gitlab et postgres actifs sont aussi réparés" {
    printf 'gitlab=on\npostgres=on\n' >"$DEVZONE_ETAT"
    run bash "$APP" reparer
    [ "$status" -eq 0 ]
    [[ "$(cat "$T/actions.log")" == *"gitlab hote-poser"* ]] || false
    [[ "$(cat "$T/actions.log")" == *"gitlab relais-lancer"* ]] || false
    [[ "$(cat "$T/actions.log")" == *"postgres relais-lancer"* ]] || false
}

@test "reparer : un élément en échec affiche sa raison et code 1" {
    : >"$T/echec-password"
    run bash "$APP" reparer
    [ "$status" -eq 1 ]
    [[ "$output" == *"✖ identifiants : identifiants indisponibles"* ]] || false
    [[ "$(cat "$T/actions.log")" == *"ports relancer"* ]] || false
}

@test "demarrer : lance le démarrage complet" {
    run bash "$APP" demarrer
    [ "$status" -eq 0 ]
    [ "$(cat "$T/actions.log")" = "demarrage " ]
}

@test "metrics : transmet le contexte et les options" {
    run bash "$APP" metrics docker-desktop --force
    [ "$status" -eq 0 ]
    [ "$(cat "$T/actions.log")" = "metrics docker-desktop --force" ]
}

@test "utiliser : bascule le contexte sans toucher au cluster des services" {
    faux_kubectl
    printf 'cluster=kind-devzone\n' >"$DEVZONE_ETAT"
    run bash "$APP" utiliser docker-desktop
    [ "$status" -eq 0 ]
    [[ "$output" == *"cluster de travail : docker-desktop"* ]] || false
    [[ "$(cat "$T/kubectl.log")" == *"config use-context docker-desktop"* ]] || false
    [ "$(cat "$DEVZONE_ETAT")" = "cluster=kind-devzone" ]
}

@test "utiliser : contexte inconnu refusé sans bascule" {
    faux_kubectl
    run bash "$APP" utiliser inconnu
    [ "$status" -eq 2 ]
    [[ "$output" == *"contexte inconnu : inconnu"* ]] || false
    [[ "$(cat "$T/kubectl.log")" != *"use-context"* ]] || false
}

@test "utiliser : cluster distant refusé sans confirmation" {
    faux_kubectl
    run bash "$APP" utiliser prod
    [ "$status" -eq 2 ]
    [[ "$output" == *"cluster distant refusé : prod"* ]] || false
    [[ "$(cat "$T/kubectl.log")" != *"use-context"* ]] || false
}

@test "utiliser : --confirmer exact accepté, autre valeur refusée" {
    faux_kubectl
    run bash "$APP" utiliser prod --confirmer prod
    [ "$status" -eq 0 ]
    [[ "$(cat "$T/kubectl.log")" == *"config use-context prod"* ]] || false

    : >"$T/kubectl.log"
    run bash "$APP" utiliser prod --confirmer autre
    [ "$status" -eq 2 ]
    [[ "$output" == *"cluster distant refusé : prod"* ]] || false
    [[ "$(cat "$T/kubectl.log")" != *"use-context"* ]] || false
}
