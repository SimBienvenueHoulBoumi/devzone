#!/usr/bin/env bats
# English command names (#502): command_canonical maps every entry of the
# table to the internal (French) name, unknown names pass through, and the
# host scripts normalize their first argument.

setup() {
    bats_require_minimum_version 1.5.0
    load commun
    relais_docker_isole
    kube_isole
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CLI="$RACINE/manage/devzone"
    WS="$RACINE/manage/workspace.sh"
    ALIASES="$RACINE/.devcontainer/command-aliases.sh"
    T="$BATS_TEST_TMPDIR"
    mkdir -p "$T/bin"
    cat >"$T/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
echo "kubectl $*" >>"$T/kubectl.log"
exit 0
KUBE
    cat >"$T/bin/helm" <<'HELM'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
echo "helm $*" >>"$T/helm.log"
exit 0
HELM
    chmod +x "$T/bin/kubectl" "$T/bin/helm"
    export PATH="$T/bin:$PATH"
    cd "$T" || return 1
}

@test "command_canonical: every entry of the table maps to the internal name" {
    # shellcheck source=../.devcontainer/command-aliases.sh
    # shellcheck disable=SC1090
    . "$ALIASES"
    while IFS='|' read -r english french; do
        [ -n "$english" ] || continue
        [ "$(command_canonical "$english")" = "$french" ] || {
            echo "unexpected mapping: $english -> $(command_canonical "$english") (expected $french)";
            return 1;
        }
    done <<'TABLE'
is-enabled|actif
enable|activer
disable|desactiver
help|aide
apply|appliquer
catalog|catalogue
start|demarrer
stop|arreter
status|etat
passwords|mots-de-passe
packages|paquets
platform|plateforme
repair|reparer
use|utiliser
update|mettre-a-jour
uninstall|desinstaller
copy-to|copier-vers
copy-from|copier-depuis
migrate|migrer
revert|revenir
clean-docker|nettoyer-docker
TABLE
}

@test "command_canonical: unknown name unchanged, empty stays empty" {
    # shellcheck source=../.devcontainer/command-aliases.sh
    # shellcheck disable=SC1090
    . "$ALIASES"
    [ "$(command_canonical nexistepas)" = "nexistepas" ]
    [ -z "$(command_canonical "")" ]
    [ -z "$(command_canonical)" ]
}

@test "manage/workspace.sh status behaves like etat" {
    : >"$T/kubectl.log"
    run bash "$WS" status
    [ "$status" -eq 0 ]
    grep -q -- "get pods" "$T/kubectl.log" || false
    cp "$T/kubectl.log" "$T/status.log"
    : >"$T/kubectl.log"
    run bash "$WS" etat
    [ "$status" -eq 0 ]
    [ "$(cat "$T/kubectl.log")" = "$(cat "$T/status.log")" ]
}

@test "manage/devzone enable x is refused on the host like a container command" {
    run bash "$CLI" enable x
    [ "$status" -eq 2 ]
    [[ "$output" == *"commande du conteneur"* ]] || false
    [ ! -e enable ]
}

@test "manage/devzone copied without command-aliases.sh still answers --version" {
    mkdir -p "$T/paquet/manage"
    cp "$CLI" "$T/paquet/manage/devzone"
    run bash "$T/paquet/manage/devzone" --version
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "manage/devzone stop creates ./stop, not ./arreter" {
    DEVZONE_SANS_DEMARRER=1 run bash "$CLI" stop
    [ "$status" -eq 0 ]
    [ -d stop ]
    [ ! -e arreter ]
}

@test "old French name warns on stderr and still runs" {
    run --separate-stderr bash "$CLI" activer ia
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"devzone: \"activer\" is deprecated, use \"enable\""* ]] || false
    [[ "$stderr" == *"commande du conteneur"* ]] || false
    [[ "$stdout" != *"deprecated"* ]] || false
}

@test "English name is silent" {
    run --separate-stderr bash "$CLI" enable ia
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"commande du conteneur"* ]] || false
    [[ "$stderr" != *"deprecated"* ]] || false
    [[ "$stdout" != *"deprecated"* ]] || false
}

@test "DEVZONE_NO_DEPRECATION=1 silences the warning" {
    DEVZONE_NO_DEPRECATION=1 run --separate-stderr bash "$CLI" activer ia
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"commande du conteneur"* ]] || false
    [[ "$stderr" != *"deprecated"* ]] || false
}

@test "devzone mettre-a-jour warns, update is silent" {
    run --separate-stderr bash "$CLI" mettre-a-jour
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"devzone: \"mettre-a-jour\" is deprecated, use \"update\""* ]] || false
    run --separate-stderr bash "$CLI" update
    [ "$status" -eq 1 ]
    [[ "$stderr" == *".devcontainer introuvable"* ]] || false
    [[ "$stderr" != *"deprecated"* ]] || false
}

@test "workspace migrer warns, migrate is silent" {
    # fake docker: the migration stops at its first check, nothing is touched
    cat >"$T/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
echo "docker $*" >>"$T/docker.log"
exit 1
DOCKER
    chmod +x "$T/bin/docker"
    run --separate-stderr bash "$WS" migrer
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"devzone: \"migrer\" is deprecated, use \"migrate\""* ]] || false
    run --separate-stderr bash "$WS" migrate
    [ "$status" -ne 0 ]
    [[ "$stderr" != *"deprecated"* ]] || false
}
