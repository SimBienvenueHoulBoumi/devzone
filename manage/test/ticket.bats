#!/usr/bin/env bats
# devzone ticket (#558). Real git on local repositories under $BATS_TEST_TMPDIR
# (bare origin, clones), fake repowarden: no network, no real clone touched.

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    TICKET="$ROOT/.devcontainer/ticket.sh"
    T="$BATS_TEST_TMPDIR"
    export HOME="$T/home" GIT_CONFIG_GLOBAL="$T/gitconfig"
    mkdir -p "$HOME" "$T/bin"
    git config --global user.name Test
    git config --global user.email test@example.org
    git config --global init.defaultBranch develop
    export DEVZONE_TICKET_PROJECTS="$T/projets" DEVZONE_TICKET_TOOLS="$T/tools"
    git init -q --bare "$T/origin.git"
    git clone -q "$T/origin.git" "$T/seed" 2>/dev/null
    (cd "$T/seed" && git commit -q --allow-empty -m init && git push -q origin develop)
    # fake repowarden: ticket <n> creates and checks out feat/<n>-test
    cat >"$T/bin/repowarden" <<'RW'
#!/usr/bin/env bash
[ "${FAKE_RW_FAIL:-}" = 1 ] && exit 1
[ "$1" = ticket ] && git checkout -q -b "feat/$2-test"
exit 0
RW
    chmod +x "$T/bin/repowarden"
    export PATH="$T/bin:$PATH"
}

pod() { export DEVZONE_WORKSPACE=kubernetes; }

clone_to() { git clone -q "$T/origin.git" "$1" 2>/dev/null; }

@test "ticket: pod worktree under <repo>-wt/dz-<n> on the ticket branch" {
    pod
    clone_to "$T/projets/devzone"
    run bash "$TICKET" 558
    [ "$status" -eq 0 ]
    [[ "$output" == *"$T/projets/devzone-wt/dz-558" ]] || false
    [ "$(git -C "$T/projets/devzone-wt/dz-558" branch --show-current)" = "feat/558-test" ]
}

@test "ticket: --repo repowarden uses repowarden-wt/rw-<n>" {
    pod
    clone_to "$T/projets/repowarden"
    run bash "$TICKET" 12 --repo repowarden
    [ "$status" -eq 0 ]
    [ -d "$T/projets/repowarden-wt/rw-12" ]
}

@test "ticket: tools container uses workspace/wt/dz-<n> of /workspaces/devzone" {
    unset DEVZONE_WORKSPACE
    clone_to "$T/tools"
    run bash "$TICKET" 7
    [ "$status" -eq 0 ]
    [ -d "$T/tools/workspace/wt/dz-7" ]
}

@test "ticket: repowarden repo refused outside the pod" {
    unset DEVZONE_WORKSPACE
    run bash "$TICKET" 7 --repo repowarden
    [ "$status" -eq 2 ]
    [[ "$output" == *"only in the Kubernetes workspace pod"* ]] || false
}

@test "ticket: missing clone points to workspace clone" {
    pod
    run bash "$TICKET" 558
    [ "$status" -eq 2 ]
    [[ "$output" == *"devzone workspace clone"* ]] || false
}

@test "ticket: existing worktree is reused, not recreated" {
    pod
    clone_to "$T/projets/devzone"
    bash "$TICKET" 558 >/dev/null
    run bash "$TICKET" 558
    [ "$status" -eq 0 ]
    [[ "$output" == *"already there"* ]] || false
}

@test "ticket: repowarden failure removes the worktree" {
    pod
    clone_to "$T/projets/devzone"
    export FAKE_RW_FAIL=1
    run bash "$TICKET" 558
    [ "$status" -eq 2 ]
    [ ! -d "$T/projets/devzone-wt/dz-558" ]
}

@test "ticket: bad arguments give usage" {
    run bash "$TICKET" abc
    [ "$status" -eq 1 ]
    [[ "$output" == *"usage: devzone ticket"* ]] || false
    run bash "$TICKET" 5 --repo
    [ "$status" -eq 1 ]
}

@test "ticket done: removes worktree and local branch when origin has no branch" {
    pod
    clone_to "$T/projets/devzone"
    bash "$TICKET" 558 >/dev/null
    run bash "$TICKET" "done" 558
    [ "$status" -eq 0 ]
    [ ! -d "$T/projets/devzone-wt/dz-558" ]
    run git -C "$T/projets/devzone" branch --list "feat/558-test"
    [ -z "$output" ]
}

@test "ticket done: refused when the worktree is not clean" {
    pod
    clone_to "$T/projets/devzone"
    bash "$TICKET" 558 >/dev/null
    : >"$T/projets/devzone-wt/dz-558/new-file"
    run bash "$TICKET" "done" 558
    [ "$status" -eq 2 ]
    [[ "$output" == *"not clean"* ]] || false
    [ -d "$T/projets/devzone-wt/dz-558" ]
}

@test "ticket done: refused while the branch exists on origin" {
    pod
    clone_to "$T/projets/devzone"
    bash "$TICKET" 558 >/dev/null
    git -C "$T/projets/devzone-wt/dz-558" push -q origin feat/558-test
    run bash "$TICKET" "done" 558
    [ "$status" -eq 2 ]
    [[ "$output" == *"still exists on origin"* ]] || false
    [ -d "$T/projets/devzone-wt/dz-558" ]
}

@test "ticket done: unknown worktree is refused" {
    pod
    clone_to "$T/projets/devzone"
    run bash "$TICKET" "done" 99
    [ "$status" -eq 2 ]
    [[ "$output" == *"no worktree for ticket 99"* ]] || false
}
