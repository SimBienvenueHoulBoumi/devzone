#!/usr/bin/env bats
# workspace-init.sh (#503): startup initialization in the Kubernetes workspace
# pod. Fake npm, repowarden, devzone and git keep the test offline and isolated.

setup() {
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$RACINE/.devcontainer/workspace-init.sh"
    REPOWARDEN_VERSION="$(sed -nE 's/^REPOWARDEN_VERSION=([^[:space:]]+)$/\1/p' \
        "$RACINE/.devcontainer/versions.env" | head -1)"
    export REPOWARDEN_VERSION
    RPW=repowarden
    export HOME="$BATS_TEST_TMPDIR/home"
    export JOURNAL="$BATS_TEST_TMPDIR/journal.log"
    export SAFE="$BATS_TEST_TMPDIR/safe-directory"
    export RPW_VERSION="$BATS_TEST_TMPDIR/repowarden-version"
    mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin"
    : >"$JOURNAL"

    cat >"$BATS_TEST_TMPDIR/bin/git" <<'GIT'
#!/usr/bin/env bash
echo "git $*" >>"$JOURNAL"
if [ "${1:-}" = config ] && [ "${2:-}" = --global ] && [ "${3:-}" = --get-all ] && [ "${4:-}" = safe.directory ]; then
    [ -f "$SAFE" ] && cat "$SAFE"
    exit 0
fi
if [ "${1:-}" = config ] && [ "${2:-}" = --global ] && [ "${3:-}" = --add ] && [ "${4:-}" = safe.directory ]; then
    printf '%s\n' "$5" >>"$SAFE"
    exit 0
fi
exit 0
GIT

    cat >"$BATS_TEST_TMPDIR/bin/npm" <<'NPM'
#!/usr/bin/env bash
echo "npm $*" >>"$JOURNAL"
if [ "${1:-}" = install ]; then
    case "${3:-}" in
        *@*) printf '%s\n' "${3#*@}" >"$RPW_VERSION" ;;
    esac
fi
exit 0
NPM

    cat >"$BATS_TEST_TMPDIR/bin/repowarden" <<'RPW'
#!/usr/bin/env bash
echo "repowarden $*" >>"$JOURNAL"
if [ "${1:-}" = --version ]; then
    if [ -f "$RPW_VERSION" ]; then
        cat "$RPW_VERSION"
    else
        echo 0.0.0
    fi
fi
exit 0
RPW

    cat >"$BATS_TEST_TMPDIR/bin/devzone" <<'DEVZONE'
#!/usr/bin/env bash
echo "devzone $*" >>"$JOURNAL"
[ "${DEVZONE_FAILED:-0}" = 1 ] && exit 1
exit 0
DEVZONE

    chmod +x "$BATS_TEST_TMPDIR/bin/"*
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "first run: installation, safe.directory and prompt block" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -qx "npm install -g ${RPW}@$REPOWARDEN_VERSION" "$JOURNAL"
    grep -qx "repowarden install --global --lang fr" "$JOURNAL"
    grep -qx "devzone apply" "$JOURNAL"
    grep -qxF '/workspaces/projets/*' "$SAFE"
    grep -qF '# >>> devzone prompt >>>' "$HOME/.bashrc"
    grep -qF '# <<< devzone prompt <<<' "$HOME/.bashrc"
    grep -qF '. /usr/local/share/devzone/.devcontainer/kube-prompt.sh' "$HOME/.bashrc"
    [[ "$output" == *"devzone init: done"* ]] || false
}

@test "second run: no second block nor new npm installation" {
    bash "$SCRIPT"
    : >"$JOURNAL"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    ! grep -q "npm install -g" "$JOURNAL" || false
    [ "$(grep -cF '# >>> devzone prompt >>>' "$HOME/.bashrc")" -eq 1 ]
    grep -qx "devzone apply" "$JOURNAL"
}

@test "old prompt block (invite-kube.sh): migrated to kube-prompt.sh, not duplicated" {
    {
        echo "# >>> devzone prompt >>>"
        echo ". /usr/local/share/devzone/.devcontainer/invite-kube.sh"
        echo "PS1='\$(devzone_invite_kube) '\"\$PS1\""
        echo "# <<< devzone prompt <<<"
    } >"$HOME/.bashrc"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    ! grep -q "invite" "$HOME/.bashrc" || false
    grep -qF "kube-prompt.sh" "$HOME/.bashrc"
    grep -qF "devzone_kube_prompt" "$HOME/.bashrc"
    [ "$(grep -cF '# >>> devzone prompt >>>' "$HOME/.bashrc")" -eq 1 ]
    run bash "$SCRIPT"
    [ "$(grep -cF 'kube-prompt.sh' "$HOME/.bashrc")" -eq 1 ]
}

@test "devzone apply failing: the following steps run and done is written" {
    export DEVZONE_FAILED=1
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"devzone init: modules incomplete"* ]] || false
    grep -qF '# >>> devzone prompt >>>' "$HOME/.bashrc"
    [[ "$output" == *"devzone init: done"* ]] || false
}
