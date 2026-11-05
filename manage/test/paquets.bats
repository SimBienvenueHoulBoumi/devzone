#!/usr/bin/env bats
# Paquets systeme gardes apres un rebuild (#351) : liste <racine>/.devzone.paquets,
# reinstallee a la creation du conteneur (post-create.sh). Faux apt-get, apt-cache,
# dpkg-query, kubectl et gh dans le PATH : aucun paquet reellement installe.

setup() {
    load commun
    relais_docker_isole
    kube_isole
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    export HOME="$BATS_TEST_TMPDIR/home"
    export DEVZONE_RACINE="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_PAQUETS_SUDO=""
    export DEVZONE_PAQUETS_MARQUE="$BATS_TEST_TMPDIR/paquets.echec"
    export DEVZONE_PAQUETS_MAJ="$BATS_TEST_TMPDIR/paquets.maj"
    mkdir -p "$HOME" "$DEVZONE_RACINE/workspace" "$BATS_TEST_TMPDIR/bin"
    : >"$BATS_TEST_TMPDIR/apt.log"
    : >"$BATS_TEST_TMPDIR/apt-cache.log"
    : >"$BATS_TEST_TMPDIR/apt-cache.list"
    : >"$BATS_TEST_TMPDIR/apt-echoues"
    : >"$BATS_TEST_TMPDIR/installe"
    : >"$BATS_TEST_TMPDIR/apt-cache.list"
    cat >"$BATS_TEST_TMPDIR/bin/apt-get" <<'APT'
#!/usr/bin/env bash
echo "apt-get $*" >>"$BATS_TEST_TMPDIR/apt.log"
case "${1:-}" in
    update)
        printf 'tree\nhtop\n' >"$BATS_TEST_TMPDIR/apt-cache.list"
        exit 0
        ;;
    install)
        shift
        for arg in "$@"; do
            case "$arg" in
                -y | --no-install-recommends) ;;
                *)
                    grep -qx "$arg" "$BATS_TEST_TMPDIR/apt-echoues" && exit 1
                    echo "$arg" >>"$BATS_TEST_TMPDIR/installe"
                    ;;
            esac
        done
        exit 0
        ;;
    remove)
        shift
        for arg in "$@"; do
            case "$arg" in
                -y) ;;
                *)
                    tmp="$(mktemp)"
                    grep -vx "$arg" "$BATS_TEST_TMPDIR/installe" >"$tmp" || true
                    mv "$tmp" "$BATS_TEST_TMPDIR/installe"
                    ;;
            esac
        done
        exit 0
        ;;
esac
exit 0
APT
    cat >"$BATS_TEST_TMPDIR/bin/apt-cache" <<'APT'
#!/usr/bin/env bash
echo "apt-cache $*" >>"$BATS_TEST_TMPDIR/apt-cache.log"
paquet="${2:-}"
grep -qx "$paquet" "$BATS_TEST_TMPDIR/apt-cache.list" && exit 0
exit 1
APT
    cat >"$BATS_TEST_TMPDIR/bin/dpkg-query" <<'DPKG'
#!/usr/bin/env bash
if [ "${1:-}" = -W ]; then
    paquet="${3:-}"
    if grep -qx "$paquet" "$BATS_TEST_TMPDIR/installe"; then
        echo "install ok installed"
    else
        echo "install ok not-installed"
    fi
    exit 0
fi
exit 1
DPKG
    printf '#!/usr/bin/env bash\nexit 0\n' >"$BATS_TEST_TMPDIR/bin/kubectl"
    cat >"$BATS_TEST_TMPDIR/bin/gh" <<'GH'
#!/usr/bin/env bash
case "${GH_ETAT:-absent}" in
    absent) echo "You are not logged into any GitHub hosts." >&2; exit 1 ;;
    sans) echo "  - Token scopes: 'gist', 'read:org', 'repo'" ;;
    avec) echo "  - Token scopes: 'gist', 'read:org', 'repo', 'workflow'" ;;
esac
GH
    cat >"$BATS_TEST_TMPDIR/bin/npm" <<'NPM'
#!/usr/bin/env bash
echo "npm $*" >>"$BATS_TEST_TMPDIR/npm.log"
if [ "${1:-}" = ls ]; then
    echo '{"dependencies":{}}'
    exit 0
fi
if [ "${1:-}" = view ]; then
    echo "0.0.0"
    exit 0
fi
exit 0
NPM
    chmod +x "$BATS_TEST_TMPDIR/bin/"*
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "paquets : liste vide -> aucun paquet, et la commande pour en ajouter" {
    run bash "$DEVZONE" paquets
    [ "$status" -eq 0 ]
    [[ "$output" == *"aucun paquet"* ]] || false
}

@test "paquets : ajouter valide installe et ajoute a la liste" {
    run bash "$DEVZONE" paquets ajouter tree
    [ "$status" -eq 0 ]
    grep -q -- "apt-get install -y --no-install-recommends tree" "$BATS_TEST_TMPDIR/apt.log"
    [ -f "$DEVZONE_RACINE/.devzone.paquets" ]
    grep -qx "tree" "$DEVZONE_RACINE/.devzone.paquets"
}

@test "paquets : ajouter un nom inconnu est refuse, liste inchon due, code 1" {
    run bash "$DEVZONE" paquets ajouter inconnome
    [ "$status" -eq 1 ]
    [[ "$output" == *"paquet inconnu"* ]] || false
    [ ! -f "$DEVZONE_RACINE/.devzone.paquets" ]
}

@test "paquets : retirer retire la liste et desinstalle" {
    run bash "$DEVZONE" paquets ajouter tree
    [ "$status" -eq 0 ]
    run bash "$DEVZONE" paquets retirer tree
    [ "$status" -eq 0 ]
    grep -q -- "apt-get remove -y tree" "$BATS_TEST_TMPDIR/apt.log"
    run bash "$DEVZONE" paquets
    [[ "$output" == *"aucun paquet"* ]] || false
}

@test "paquets : retirer un paquet non liste (fourni par l image) est refuse" {
    run bash "$DEVZONE" paquets retirer tree
    [ "$status" -eq 1 ]
    [[ "$output" == *"paquet non list"* ]] || false
}


@test "paquets : appliquer n installe que les paquets manquants" {
    printf '# paquets ajoutes par devzone paquets ; reinstalle a chaque creation du conteneur\ntree\nhtop\n' >"$DEVZONE_RACINE/.devzone.paquets"
    printf 'tree\n' >"$BATS_TEST_TMPDIR/installe"
    : >"$BATS_TEST_TMPDIR/apt.log"
    run bash "$DEVZONE" paquets appliquer
    [ "$status" -eq 0 ]
    grep -q -- "apt-get install -y --no-install-recommends htop" "$BATS_TEST_TMPDIR/apt.log"
    [ ! -e "$DEVZONE_PAQUETS_MARQUE" ]
}

@test "paquets : liste trie et sans doublon" {
    printf '# paquets ajoutes par devzone paquets ; reinstalle a chaque creation du conteneur\ntree\nhtop\ntree\n' >"$DEVZONE_RACINE/.devzone.paquets"
    run bash "$DEVZONE" paquets
    [ "$status" -eq 0 ]
    [ "$(grep -c "○ htop" <<<"$output")" -eq 1 ]
    [ "$(grep -c "○ tree" <<<"$output")" -eq 1 ]
}

@test "paquets : paquet introuvable a l appliquer -> marque et ⚠ dans le recapitulatif" {
    printf '# paquets ajoutes par devzone paquets ; reinstalle a chaque creation du conteneur\nghost\n' >"$DEVZONE_RACINE/.devzone.paquets"
    printf 'ghost\n' >"$BATS_TEST_TMPDIR/apt-echoues"
    run bash "$DEVZONE" paquets appliquer
    [ "$status" -ne 0 ]
    [ -f "$DEVZONE_PAQUETS_MARQUE" ]
    run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"⚠ paquets"* ]] || false
    [[ "$output" == *"devzone paquets"* ]] || false
}

@test "paquets : ajouter valide fait apt-get update avant apt-get install" {
    run bash "$DEVZONE" paquets ajouter tree
    [ "$status" -eq 0 ]
    grep -q -- "apt-get update" "$BATS_TEST_TMPDIR/apt.log"
    grep -q -- "apt-get install -y --no-install-recommends tree" "$BATS_TEST_TMPDIR/apt.log"
    ligne_update="$(grep -n "apt-get update" "$BATS_TEST_TMPDIR/apt.log" | head -1 | cut -d: -f1)"
    ligne_install="$(grep -n "apt-get install" "$BATS_TEST_TMPDIR/apt.log" | head -1 | cut -d: -f1)"
    [ "$ligne_update" -lt "$ligne_install" ] || false
}

@test "paquets : appliquer fait apt-get update avant apt-get install pour un paquet manquant" {
    printf '# paquets ajoutes par devzone paquets ; reinstalle a chaque creation du conteneur\ntree\n' >"$DEVZONE_RACINE/.devzone.paquets"
    : >"$BATS_TEST_TMPDIR/installe"
    run bash "$DEVZONE" paquets appliquer
    [ "$status" -eq 0 ]
    grep -q -- "apt-get update" "$BATS_TEST_TMPDIR/apt.log"
    grep -q -- "apt-get install -y --no-install-recommends tree" "$BATS_TEST_TMPDIR/apt.log"
    ligne_update="$(grep -n "apt-get update" "$BATS_TEST_TMPDIR/apt.log" | head -1 | cut -d: -f1)"
    ligne_install="$(grep -n "apt-get install" "$BATS_TEST_TMPDIR/apt.log" | head -1 | cut -d: -f1)"
    [ "$ligne_update" -lt "$ligne_install" ] || false
}

@test "paquets : appliquer installe le valide et ne marque que l inconnu" {
    printf '# paquets ajoutes par devzone paquets ; reinstalle a chaque creation du conteneur\ninconnu\ntree\n' >"$DEVZONE_RACINE/.devzone.paquets"
    printf 'inconnu\n' >"$BATS_TEST_TMPDIR/apt-echoues"
    : >"$BATS_TEST_TMPDIR/installe"
    run bash "$DEVZONE" paquets appliquer
    [ "$status" -ne 0 ]
    grep -q -- "apt-get update" "$BATS_TEST_TMPDIR/apt.log"
    grep -qx "tree" "$BATS_TEST_TMPDIR/installe"
    [ -f "$DEVZONE_PAQUETS_MARQUE" ]
    grep -qx "inconnu" "$DEVZONE_PAQUETS_MARQUE"
    [ "$(wc -l < "$DEVZONE_PAQUETS_MARQUE")" -eq 1 ] || false
    [[ "$(cat "$DEVZONE_PAQUETS_MARQUE")" == "inconnu" ]] || false
}
