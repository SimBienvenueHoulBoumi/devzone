#!/usr/bin/env bats
# English command names (#502): command_canonical maps every entry of the
# table to the internal (French) name, unknown names pass through, and the
# host scripts normalize their first argument.

setup() {
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
