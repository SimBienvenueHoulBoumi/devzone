#!/usr/bin/env bats
# System packages kept after a rebuild (#351): list <root>/.devzone.packages,
# reinstalled at container creation (post-create.sh). Fake apt-get, apt-cache,
# dpkg-query, kubectl and gh in the PATH: no package really installed.

# Stored mark « already present », byte for byte as packages.sh writes it
PRESENT_MARK=$'# d\303\251j\303\240 pr\303\251sent'

setup() {
    load commun
    kind_vide
    kube_isole
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    export HOME="$BATS_TEST_TMPDIR/home"
    export DEVZONE_ROOT="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_PACKAGES_SUDO=""
    export DEVZONE_PACKAGES_MARKER="$BATS_TEST_TMPDIR/packages.failed"
    export DEVZONE_PACKAGES_UPDATE="$BATS_TEST_TMPDIR/packages.updated"
    mkdir -p "$HOME" "$DEVZONE_ROOT/workspace" "$BATS_TEST_TMPDIR/bin"
    : >"$BATS_TEST_TMPDIR/apt.log"
    : >"$BATS_TEST_TMPDIR/apt-cache.log"
    : >"$BATS_TEST_TMPDIR/apt-cache.list"
    : >"$BATS_TEST_TMPDIR/apt-failing"
    : >"$BATS_TEST_TMPDIR/installed"
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
                    grep -qx "$arg" "$BATS_TEST_TMPDIR/apt-failing" && exit 1
                    echo "$arg" >>"$BATS_TEST_TMPDIR/installed"
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
                    grep -vx "$arg" "$BATS_TEST_TMPDIR/installed" >"$tmp" || true
                    mv "$tmp" "$BATS_TEST_TMPDIR/installed"
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
package="${2:-}"
grep -qx "$package" "$BATS_TEST_TMPDIR/apt-cache.list" && exit 0
exit 1
APT
    cat >"$BATS_TEST_TMPDIR/bin/dpkg-query" <<'DPKG'
#!/usr/bin/env bash
if [ "${1:-}" = -W ]; then
    package="${3:-}"
    if grep -qx "$package" "$BATS_TEST_TMPDIR/installed"; then
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
case "${GH_STATE:-absent}" in
    absent) echo "You are not logged into any GitHub hosts." >&2; exit 1 ;;
    without) echo "  - Token scopes: 'gist', 'read:org', 'repo'" ;;
    with) echo "  - Token scopes: 'gist', 'read:org', 'repo', 'workflow'" ;;
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

@test "packages: empty list -> no package, and the command to add one" {
    run bash "$DEVZONE" packages
    [ "$status" -eq 0 ]
    [[ "$output" == *"no package"* ]] || false
}

@test "packages: the English names of the subcommands give no warning" {
    run --separate-stderr bash "$DEVZONE" packages list
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"deprecated"* ]] || false
    run --separate-stderr bash "$DEVZONE" packages apply
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"deprecated"* ]] || false
}

@test "packages: add installs and adds to the list" {
    run bash "$DEVZONE" packages add tree
    [ "$status" -eq 0 ]
    grep -q -- "apt-get install -y --no-install-recommends tree" "$BATS_TEST_TMPDIR/apt.log"
    [ -f "$DEVZONE_ROOT/.devzone.packages" ]
    grep -qx "tree" "$DEVZONE_ROOT/.devzone.packages"
}

@test "packages: adding an unknown name is refused, list unchanged, code 1" {
    run bash "$DEVZONE" packages add nosuchpkg
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown package"* ]] || false
    [ ! -f "$DEVZONE_ROOT/.devzone.packages" ]
}

@test "packages: remove drops it from the list and uninstalls" {
    run bash "$DEVZONE" packages add tree
    [ "$status" -eq 0 ]
    run bash "$DEVZONE" packages remove tree
    [ "$status" -eq 0 ]
    grep -q -- "apt-get remove -y tree" "$BATS_TEST_TMPDIR/apt.log"
    run bash "$DEVZONE" packages
    [[ "$output" == *"no package"* ]] || false
}

@test "packages: removing a package not listed (from the image) is refused" {
    run bash "$DEVZONE" packages remove tree
    [ "$status" -eq 1 ]
    [[ "$output" == *"package not listed"* ]] || false
}


@test "packages: apply installs only the missing packages" {
    printf '# packages added by devzone packages ; reinstalled at each container creation\ntree\nhtop\n' >"$DEVZONE_ROOT/.devzone.packages"
    printf 'tree\n' >"$BATS_TEST_TMPDIR/installed"
    : >"$BATS_TEST_TMPDIR/apt.log"
    run bash "$DEVZONE" packages apply
    [ "$status" -eq 0 ]
    grep -q -- "apt-get install -y --no-install-recommends htop" "$BATS_TEST_TMPDIR/apt.log"
    [ ! -e "$DEVZONE_PACKAGES_MARKER" ]
}

@test "packages: list sorted and without duplicate" {
    printf '# packages added by devzone packages ; reinstalled at each container creation\ntree\nhtop\ntree\n' >"$DEVZONE_ROOT/.devzone.packages"
    run bash "$DEVZONE" packages
    [ "$status" -eq 0 ]
    [ "$(grep -c "○ htop" <<<"$output")" -eq 1 ]
    [ "$(grep -c "○ tree" <<<"$output")" -eq 1 ]
}

@test "packages: package not found at apply -> mark and ⚠ in the recap" {
    printf '# packages added by devzone packages ; reinstalled at each container creation\nghost\n' >"$DEVZONE_ROOT/.devzone.packages"
    printf 'ghost\n' >"$BATS_TEST_TMPDIR/apt-failing"
    run bash "$DEVZONE" packages apply
    [ "$status" -ne 0 ]
    [ -f "$DEVZONE_PACKAGES_MARKER" ]
    run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"⚠ packages"* ]] || false
    [[ "$output" == *"devzone packages"* ]] || false
}

@test "packages: add runs apt-get update before apt-get install" {
    run bash "$DEVZONE" packages add tree
    [ "$status" -eq 0 ]
    grep -q -- "apt-get update" "$BATS_TEST_TMPDIR/apt.log"
    grep -q -- "apt-get install -y --no-install-recommends tree" "$BATS_TEST_TMPDIR/apt.log"
    line_update="$(grep -n "apt-get update" "$BATS_TEST_TMPDIR/apt.log" | head -1 | cut -d: -f1)"
    line_install="$(grep -n "apt-get install" "$BATS_TEST_TMPDIR/apt.log" | head -1 | cut -d: -f1)"
    [ "$line_update" -lt "$line_install" ] || false
}

@test "packages: apply runs apt-get update before apt-get install for a missing package" {
    printf '# packages added by devzone packages ; reinstalled at each container creation\ntree\n' >"$DEVZONE_ROOT/.devzone.packages"
    : >"$BATS_TEST_TMPDIR/installed"
    run bash "$DEVZONE" packages apply
    [ "$status" -eq 0 ]
    grep -q -- "apt-get update" "$BATS_TEST_TMPDIR/apt.log"
    grep -q -- "apt-get install -y --no-install-recommends tree" "$BATS_TEST_TMPDIR/apt.log"
    line_update="$(grep -n "apt-get update" "$BATS_TEST_TMPDIR/apt.log" | head -1 | cut -d: -f1)"
    line_install="$(grep -n "apt-get install" "$BATS_TEST_TMPDIR/apt.log" | head -1 | cut -d: -f1)"
    [ "$line_update" -lt "$line_install" ] || false
}

@test "packages: apply installs the valid one and marks only the unknown one" {
    printf '# packages added by devzone packages ; reinstalled at each container creation\nunknown\ntree\n' >"$DEVZONE_ROOT/.devzone.packages"
    printf 'unknown\n' >"$BATS_TEST_TMPDIR/apt-failing"
    : >"$BATS_TEST_TMPDIR/installed"
    run bash "$DEVZONE" packages apply
    [ "$status" -ne 0 ]
    grep -q -- "apt-get update" "$BATS_TEST_TMPDIR/apt.log"
    grep -qx "tree" "$BATS_TEST_TMPDIR/installed"
    [ -f "$DEVZONE_PACKAGES_MARKER" ]
    grep -qx "unknown" "$DEVZONE_PACKAGES_MARKER"
    [ "$(wc -l < "$DEVZONE_PACKAGES_MARKER")" -eq 1 ] || false
    [[ "$(cat "$DEVZONE_PACKAGES_MARKER")" == "unknown" ]] || false
}

@test "packages: package already installed before add is marked, remove does not uninstall it" {
    printf 'tree\n' >"$BATS_TEST_TMPDIR/installed"
    run bash "$DEVZONE" packages add tree
    [ "$status" -eq 0 ]
    grep -qxF -e "tree $PRESENT_MARK" "$DEVZONE_ROOT/.devzone.packages"
    : >"$BATS_TEST_TMPDIR/apt.log"
    run bash "$DEVZONE" packages remove tree
    [ "$status" -eq 0 ]
    [[ "$output" == *"left installed"* ]] || false
    ! grep -q "apt-get remove" "$BATS_TEST_TMPDIR/apt.log" || false
    grep -qx "tree" "$BATS_TEST_TMPDIR/installed"
    run bash "$DEVZONE" packages
    [[ "$output" == *"no package"* ]] || false
}

@test "packages: after add a, add b, remove a, a single header and only b" {
    run bash "$DEVZONE" packages add tree
    [ "$status" -eq 0 ]
    run bash "$DEVZONE" packages add htop
    [ "$status" -eq 0 ]
    run bash "$DEVZONE" packages remove tree
    [ "$status" -eq 0 ]
    [ "$(grep -c '^#' "$DEVZONE_ROOT/.devzone.packages")" -eq 1 ]
    [ "$(grep -v '^#' "$DEVZONE_ROOT/.devzone.packages")" = "htop" ]
}

@test "packages: names_list ignores the already-present mark" {
    printf '# packages added by devzone packages ; reinstalled at each container creation\ntree %s\nhtop\n' "$PRESENT_MARK" >"$DEVZONE_ROOT/.devzone.packages"
    printf 'tree\n' >"$BATS_TEST_TMPDIR/installed"
    : >"$BATS_TEST_TMPDIR/apt.log"
    run bash "$DEVZONE" packages
    [ "$status" -eq 0 ]
    [[ "$output" == *"✔ tree"* ]] || false
    [[ "$output" != *"#"* ]] || false
    run bash "$DEVZONE" packages apply
    [ "$status" -eq 0 ]
    ! grep -q "tree #" "$BATS_TEST_TMPDIR/apt.log" || false
}
