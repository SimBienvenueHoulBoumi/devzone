#!/usr/bin/env bats
# Sortie machine devzone etat --json (#308)

setup() {
    load commun
    relais_docker_isole
    kube_isole
    kind_vide
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/racine/workspace"
    export DEVZONE_RACINE="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_ETAT="$BATS_TEST_TMPDIR/modules"
    : >"$DEVZONE_ETAT"
    export GIT_CONFIG_NOSYSTEM=1
    cd "$BATS_TEST_TMPDIR" || return 1

    # git config user name/email par défaut absent
    # faux kubectl
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
case "$*" in
    "config current-context") echo "docker-desktop" ;;
    *) exit 1 ;;
esac
KUBECTL
    # faux gh
    cat >"$BATS_TEST_TMPDIR/bin/gh" <<'GH'
#!/usr/bin/env bash
case "${GH_ETAT:-absent}" in
    absent) echo "You are not logged into any GitHub hosts." >&2; exit 1 ;;
    sans) echo "  - Token scopes: 'gist', 'read:org', 'repo'" ;;
    avec) echo "  - Token scopes: 'gist', 'read:org', 'repo', 'workflow'" ;;
esac
GH
    # faux docker
    mkdir -p "$BATS_TEST_TMPDIR/relais"
    cat >"$BATS_TEST_TMPDIR/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
case "${1:-}" in
    ps)
        show_all=0; motif=""
        prec=""
        for a in "$@"; do
            [ "$a" = "-a" ] && show_all=1
            [ "$prec" = --filter ] && motif="$a"
            prec="$a"
        done
        for f in "$T"/relais/*; do
            [ -e "$f" ] || continue
            nom="$(basename "$f")"
            m="${motif#name=^}"
            m="${m%$}"
            if [ "$nom" = "$m" ]; then echo "$nom"; fi
        done
        ;;
esac
exit 0
DOCKER
    # faux curl
    cat >"$BATS_TEST_TMPDIR/bin/curl" <<'CURL'
#!/usr/bin/env bash
for p in ${FAUX_REPOND:-}; do
    case "$*" in *":$p"*) exit 0 ;; esac
done
exit 7
CURL
    chmod +x "$BATS_TEST_TMPDIR/bin/"*
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "etat-json : schema 1 et JSON valide" {
    run bash "$DEVZONE" etat --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | jq -e . >/dev/null
    [ "$(printf '%s\n' "$output" | jq -r '.schema')" = "1" ]
}

@test "etat-json : identité absente → ok false avec commande" {
    run bash "$DEVZONE" etat --json
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | jq -r '.identite_git.ok')" = "false" ]
    [ "$(printf '%s\n' "$output" | jq -r '.identite_git.commande')" != "null" ]
}

@test "etat-json : identité présente" {
    git config --global user.name "Nom Accentué \"X\"" 2>/dev/null || true
    git config --global user.email "a@b.invalid" 2>/dev/null || true
    run bash "$DEVZONE" etat --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | jq -e . >/dev/null
    [ "$(printf '%s\n' "$output" | jq -r '.identite_git.nom')" = 'Nom Accentué "X"' ]
}

@test "etat-json : module en échec → echec et commande" {
    printf 'ia=on\n' >"$DEVZONE_ETAT"
    echo "echec npm" >"$DEVZONE_ETAT-echec-ia"
    run bash "$DEVZONE" etat --json
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | jq -r '.modules[] | select(.nom=="ia") | .echec')" = "echec npm" ]
    [ "$(printf '%s\n' "$output" | jq -r '.modules[] | select(.nom=="ia") | .commande')" = "devzone appliquer" ]
}

@test "etat-json : faux gh qui échoue → github null et erreurs.github" {
    GH_ETAT=absent run bash "$DEVZONE" etat --json
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | jq -r '.plateforme.github')" = "null" ]
    [ "$(printf '%s\n' "$output" | jq -r '.erreurs.github')" != "null" ]
}

@test "etat-json : relais en échec → alerte relais_docker" {
    echo "relais cassé" >"$BATS_TEST_TMPDIR/relais.echec"
    export DEVZONE_RELAIS_MARQUE="$BATS_TEST_TMPDIR/relais.echec"
    run bash "$DEVZONE" etat --json
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | jq -r '.alertes[] | select(.code=="relais_docker") | .code')" = "relais_docker" ]
}

@test "etat-json : port ouvert → dans ports" {
    printf 'ports=8080\n' >"$DEVZONE_ETAT"
    : >"$BATS_TEST_TMPDIR/relais/devzone-devzone-port-8080"
    FAUX_REPOND=8080 run bash "$DEVZONE" etat --json
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | jq -r '.ports[] | select(.port==8080) | .port')" = "8080" ]
}

@test "etat-json : aucun secret dans la sortie" {
    printf 'secret-sentinel-123\n' >"$DEVZONE_RACINE/.password"
    cat >"$BATS_TEST_TMPDIR/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "token secret-gh-456" >&2
exit 1
GH
    chmod +x "$BATS_TEST_TMPDIR/bin/gh"
    run bash "$DEVZONE" etat --json
    [ "$status" -eq 0 ]
    [[ "$output" != *"secret-sentinel-123"* ]] || false
    [[ "$output" != *"secret-gh-456"* ]] || false
}

@test "etat-json : docker-hote on par défaut, socket présent → actif" {
    : >"$DEVZONE_RELAIS_SOURCE"
    run bash "$DEVZONE" etat --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | jq -e . >/dev/null
    [ "$(printf '%s\n' "$output" | jq -r '.docker_hote')" = "true" ]
    [ "$(printf '%s\n' "$output" | jq -r '.docker_hote_actif')" = "true" ]
}

@test "etat-json : docker-hote on, socket absent → actif false" {
    rm -f "$DEVZONE_RELAIS_SOURCE"
    run bash "$DEVZONE" etat --json
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | jq -r '.docker_hote')" = "true" ]
    [ "$(printf '%s\n' "$output" | jq -r '.docker_hote_actif')" = "false" ]
}

@test "etat-json : docker-hote=off, socket encore monté → actif true" {
    : >"$DEVZONE_RELAIS_SOURCE"
    printf 'docker-hote=off\n' >"$DEVZONE_ETAT"
    run bash "$DEVZONE" etat --json
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | jq -r '.docker_hote')" = "false" ]
    [ "$(printf '%s\n' "$output" | jq -r '.docker_hote_actif')" = "true" ]
}

@test "etat-json : docker-hote=off sans socket → false" {
    printf 'docker-hote=off\n' >"$DEVZONE_ETAT"
    rm -f "$DEVZONE_RELAIS_SOURCE"
    run bash "$DEVZONE" etat --json
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | jq -r '.docker_hote')" = "false" ]
    [ "$(printf '%s\n' "$output" | jq -r '.docker_hote_actif')" = "false" ]
}

@test "etat-json : texte non modifié (devzone sans --json)" {
    run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"devzone : état"* ]] || false
}
