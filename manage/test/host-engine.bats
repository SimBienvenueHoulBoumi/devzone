#!/usr/bin/env bats
# Tests of the host container engine (fakes in $BATS_TEST_TMPDIR/bin): the uninstall of the
# Go command, run on a copy of the devcontainer configuration in a temporary folder.

setup() {
    load commun
    devzone_go_pret
    export BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-/tmp/bats}"
    kube_isole
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
    export ETAT="$BATS_TEST_TMPDIR/state"
    : >"$ETAT"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# Devzone folder of the test: its devcontainer configuration is a copy of the
# repository's, read by the devcontainer CLI; the uninstall never touches the repository
dossier_devzone() {
    local dz="$BATS_TEST_TMPDIR/dz"
    mkdir -p "$dz/.devcontainer" "$dz/workspace"
    cp "$BATS_TEST_DIRNAME/../../.devcontainer/devcontainer.json" "$dz/.devcontainer/"
    export DEVZONE_ROOT="$dz"
}

# --- uninstall ---------------------------------------------------------
@test "uninstall : filter by instance, no kind" {
    dossier_devzone
    export DEVZONE_VOLUMES="mon-devzone"
    export CONFIRMER=yes
    export DEVZONE_IN_CONTAINER=no
    cat >"$BATS_TEST_TMPDIR/bin/engine" <<'ENGINE'
#!/usr/bin/env bash
echo "engine $*" >>"$BATS_TEST_TMPDIR/engine.log"
case "$*" in
    *"ps -aq --filter"*"io.x-k8s.kind.cluster=devzone-mon-devzone"*) echo "KIND_DEVZONE_ID" ;;
    *"ps -aq --filter"*"io.x-k8s.kind.cluster=gitlab-mon-devzone"*) echo "KIND_GITLAB_ID" ;;
    *"ps -aq --filter"*"devzone.instance=mon-devzone"*) echo "LABEL_ID" ;;
    *"ps -aq --filter"*"devzone.instance=other"*) echo "OTHER_ID" ;;
esac
exit 0
ENGINE
    chmod +x "$BATS_TEST_TMPDIR/bin/engine"
    : >"$BATS_TEST_TMPDIR/engine.log"
    # kind is usually not installed on the workstation: the uninstall must never
    # call it (the clusters are found by their label)
    printf '#!/usr/bin/env bash\necho "kind $*" >>"$BATS_TEST_TMPDIR/kind.log"\n' >"$BATS_TEST_TMPDIR/bin/kind"
    chmod +x "$BATS_TEST_TMPDIR/bin/kind"
    : >"$BATS_TEST_TMPDIR/kind.log"
    run "$DEVZONE_HOST_BIN" uninstall
    [ "$status" -eq 0 ]
    grep -q "engine rm -f KIND_DEVZONE_ID" "$BATS_TEST_TMPDIR/engine.log"
    grep -q "engine rm -f KIND_GITLAB_ID" "$BATS_TEST_TMPDIR/engine.log"
    grep -q "engine rm -f LABEL_ID" "$BATS_TEST_TMPDIR/engine.log"
    ! grep -q "engine rm -f OTHER_ID" "$BATS_TEST_TMPDIR/engine.log" || false
    [ ! -s "$BATS_TEST_TMPDIR/kind.log" ]
}

@test "uninstall in the container: no engine action on the workstation" {
    # the engine command reaches the host engine there: the volumes seen would be the workstation's
    dossier_devzone
    export CONFIRMER=yes
    export DEVZONE_IN_CONTAINER=yes
    cat >"$BATS_TEST_TMPDIR/bin/engine" <<'ENGINE'
#!/usr/bin/env bash
echo "engine $*" >>"$BATS_TEST_TMPDIR/engine.log"
case "$*" in
    *"ps -aq"*) echo "UN_CONTENEUR" ;;
    *"volume ls"*) echo "devzone-gh" ;;
esac
exit 0
ENGINE
    chmod +x "$BATS_TEST_TMPDIR/bin/engine"
    : >"$BATS_TEST_TMPDIR/engine.log"
    run "$DEVZONE_HOST_BIN" uninstall
    [ "$status" -eq 0 ]
    [[ "$output" == *"make desinstaller on your machine"* ]] || false
    ! grep -qE "engine (rm|rmi|volume rm|network rm)" "$BATS_TEST_TMPDIR/engine.log" || false
}
