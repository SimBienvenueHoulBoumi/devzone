# Helpers of the agent-pod tests (#222), loaded with `load agent-pod-racine`.
# The projects root of the launcher is a test folder under BATS_TEST_TMPDIR:
# no test creates or needs /workspaces.

# Sets DEVZONE_RACINE to <test tmp>/projets (created inside BATS_TEST_TMPDIR),
# TMPDIR to BATS_TEST_TMPDIR, and REAL_KUBECTL to the kubectl found without the
# fake bin folder (empty when kubectl is absent). Call it in setup, after agent_isole.
racine_test() {
    export DEVZONE_RACINE="$BATS_TEST_TMPDIR/projets"
    export TMPDIR="$BATS_TEST_TMPDIR"
    mkdir -p "$DEVZONE_RACINE"
    REAL_KUBECTL="$(PATH="${PATH#"$BATS_TEST_TMPDIR/bin:"}" command -v kubectl 2>/dev/null || true)"
    export REAL_KUBECTL
}

# Creates <root>/<depot>-wt/<nom> with a .git file that points to
# <root>/<depot>/.git/worktrees/<nom>, as git writes it. Prints the folder.
faux_worktree() {
    local depot="$1" nom="$2"
    local folder="$DEVZONE_RACINE/$depot-wt/$nom"
    mkdir -p "$folder" "$DEVZONE_RACINE/$depot/.git/worktrees/$nom"
    printf 'gitdir: %s/%s/.git/worktrees/%s\n' "$DEVZONE_RACINE" "$depot" "$nom" >"$folder/.git"
    echo "$folder"
}
