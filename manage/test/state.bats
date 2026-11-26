#!/usr/bin/env bats
# Safe write of the module state (#417): lock, temporary file in the state
# folder (never missing for a reader), backup copy, restore and rebuild from
# the namespaces. State, root and tools under $BATS_TEST_TMPDIR.

setup() {
    load commun
    kube_isole
    # Outside the pod by default: the ambient DEVZONE_WORKSPACE (a workspace
    # pod) must not change the messages of these tests
    unset DEVZONE_WORKSPACE
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    ETAT_SH="$BATS_TEST_DIRNAME/../../.devcontainer/state.sh"
    export DEVZONE_ROOT="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_STATE="$BATS_TEST_TMPDIR/racine/.devzone.modules"
    export DEVZONE_INSTANCE=devzone
    export GIT_CONFIG_NOSYSTEM=1
    mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/relais" "$DEVZONE_ROOT/workspace"
    cd "$BATS_TEST_TMPDIR" || return 1

    # fake kubectl: namespaces labelled devzone according to FAUX_NS (#417, step 3)
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"$BATS_TEST_TMPDIR/kubectl.log"
    case "$*" in
    "config get-contexts -o name") printf 'devzone\ndocker-desktop\n' ;;
    get\ namespaces*)
        for n in ${FAUX_NS:-}; do printf 'namespace/%s\n' "$n"; done
        ;;
    *"config view"*)
        nom=""
        for c in devzone docker-desktop; do
            if [[ "$*" == *"$c"* ]]; then nom="$c"; break; fi
        done
        case "$nom" in
            devzone | docker-desktop) echo "docker-desktop" ;;
            *) exit 1 ;;
        esac
        ;;
    *) exit 1 ;;
esac
exit 0
KUBE
    # fake docker: relays noted in a file, no container
    cat >"$BATS_TEST_TMPDIR/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
echo "docker $*" >>"$T/docker.log"
case "${1:-}" in
    inspect) echo "devzone_default 172.18.0.5" ;;
    run)
        nom=""; prec=""
        for a in "$@"; do
            [ "$prec" = --name ] && nom="$a"
            prec="$a"
        done
        mkdir -p "$T/relais"; : >"$T/relais/$nom"; echo "id-$nom"
        ;;
    rm) rm -f "$T/relais/${3:-${2:-}}" ;;
    ps) ;;
esac
exit 0
DOCKER
    # fake npm: versions.sh --installees answers without any installed tool
    cat >"$BATS_TEST_TMPDIR/bin/npm" <<'NPM'
#!/usr/bin/env bash
echo "npm $*" >>"$BATS_TEST_TMPDIR/npm.log"
case "${1:-}" in ls) printf '{"dependencies":{}}\n' ;; esac
exit 0
NPM
    chmod +x "$BATS_TEST_TMPDIR/bin/"*
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    : >"$BATS_TEST_TMPDIR/docker.log"
}

# Concurrent writer: $1 = key prefix, $2 = number of keys (#417)
writer() {
    ETAT="$DEVZONE_STATE" bash -c '
        . "$1"
        i=1
        while [ "$i" -le "$2" ]; do
            state_write "$3$i" on || exit 1
            i=$((i + 1))
        done
    ' _ "$ETAT_SH" "$2" "$1"
}

# Reader: loops on the existence of the state until the writes end
reader() {
    while [ ! -f "$BATS_TEST_TMPDIR/reader-done" ]; do
        [ -f "$DEVZONE_STATE" ] || { echo "state missing during a write (#417)"; return 1; }
    done
    return 0
}

@test "two concurrent writers: no line lost" {
    writer a 25 &
    pid_a=$!
    writer b 25 &
    pid_b=$!
    wait "$pid_a"
    wait "$pid_b"
    i=1
    while [ "$i" -le 25 ]; do
        grep -qx "a$i=on" "$DEVZONE_STATE" || { echo "line a$i lost"; false; }
        grep -qx "b$i=on" "$DEVZONE_STATE" || { echo "line b$i lost"; false; }
        i=$((i + 1))
    done
}

@test "reader during the writes: the file is never missing" {
    # The temporary file of a write starts on another file system than the
    # state: without the fix, mv copies then removes and the reader sees the
    # file missing (#417)
    if touch /dev/shm/devzone-state-$$ 2>/dev/null; then
        rm -f /dev/shm/devzone-state-$$
        export TMPDIR=/dev/shm
    fi
    printf 'ai=off\n' >"$DEVZONE_STATE"
    reader &
    pid_r=$!
    writer a 25 &
    pid_a=$!
    writer b 25 &
    pid_b=$!
    code=0
    wait "$pid_a" || code=1
    wait "$pid_b" || code=1
    : >"$BATS_TEST_TMPDIR/reader-done"
    wait "$pid_r" || code=1
    [ "$code" -eq 0 ]
}

@test "state removed with a backup copy: restored" {
    printf 'ai=on\nkubernetes=off\ngitlab=on\npostgres=on\n' >"$DEVZONE_STATE.prev"
    rm -f "$DEVZONE_STATE"
    run bash "$DEVZONE" is-enabled postgres
    [ "$status" -eq 0 ]
    [[ "$output" == *"restored from the backup copy"* ]] || false
    grep -qx 'postgres=on' "$DEVZONE_STATE"
    grep -qx 'gitlab=on' "$DEVZONE_STATE"
    [ -f "$DEVZONE_STATE.recouvre" ]
}

@test "state removed without a backup copy, devzone namespaces: rebuilt" {
    printf 'ai=on\n' >"$DEVZONE_STATE"
    rm -f "$DEVZONE_STATE"
    FAUX_NS="devzone-postgres devzone-gitlab devzone-mysql" run bash "$DEVZONE" is-enabled postgres
    [ "$status" -eq 0 ]
    [[ "$output" == *"rebuilt from the namespaces"* ]] || false
    grep -qx 'postgres=on' "$DEVZONE_STATE"
    grep -qx 'gitlab=on' "$DEVZONE_STATE"
    grep -qx 'mysql=on' "$DEVZONE_STATE"
    grep -qx 'ai=off' "$DEVZONE_STATE"
    # cluster= expects the real host context that points to the services
    # cluster (docker-desktop here), not the "devzone" context
    grep -qx 'cluster=docker-desktop' "$DEVZONE_STATE"
    [ -f "$DEVZONE_STATE.recouvre" ]
}

@test "rebuild: host context not found, no cluster= line but rebuilt" {
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
case "$*" in "config get-contexts -o name"|"config view") exit 1 ;; get\ namespaces*) for n in ${FAUX_NS:-}; do printf 'namespace/%s\n' "$n"; done ;; esac
KUBE
    chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
    printf 'ai=on\n' >"$DEVZONE_STATE"
    rm -f "$DEVZONE_STATE"
    FAUX_NS="devzone-postgres devzone-gitlab" run bash "$DEVZONE" is-enabled postgres
    [ "$status" -eq 0 ]
    [[ "$output" == *"rebuilt from the namespaces"* ]] || false
    [[ "$output" == *"no host context"* ]] || false
    grep -qx 'postgres=on' "$DEVZONE_STATE"
    ! grep -q '^cluster=' "$DEVZONE_STATE" || false
    [ -f "$DEVZONE_STATE.recouvre" ]
}

@test "first installation: default state, without backup copy" {
    run bash "$DEVZONE" is-enabled ai
    [ "$status" -eq 1 ]
    grep -qx 'ai=off' "$DEVZONE_STATE"
    grep -qx 'kubernetes=off' "$DEVZONE_STATE"
    grep -qx 'gitlab=off' "$DEVZONE_STATE"
    run test -e "$DEVZONE_STATE.prev"
    [ "$status" -ne 0 ]
    run test -e "$DEVZONE_STATE.recouvre"
    [ "$status" -ne 0 ]
}

@test "no mv nor redirection to the state outside state.sh" {
    root="$BATS_TEST_DIRNAME/../.."
    found="$(grep -rn 'mv .*"\$ETAT"\|> *"\$ETAT"' "$root/.devcontainer" "$root/manage" 2>/dev/null |
        grep -v '/state.sh:' | grep -v '/test/' || true)"
    [ -z "$found" ] || { echo "direct write outside state.sh: $found"; false; }
}

@test "state: argocd GitOps repository line designates the URL" {
    printf '[argocd]\n    repo = https://github.com/tester/devzone-argocd.git\n' >"$DEVZONE_ROOT/.argocd.conf"
    run bash "$DEVZONE" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"  ○ argocd          GitOps repository: https://github.com/tester/devzone-argocd.git"* ]] || false
}

@test "state: argocd line without GitOps repository: init notice" {
    run bash "$DEVZONE" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"  ○ argocd          no GitOps repository: devzone argocd init"* ]] || false
}

@test "devzone apply confirms the restored state: recovery marker removed" {
    printf 'ai=off\ngitlab=off\npostgres=off\nkubernetes=off\n' >"$DEVZONE_STATE"
    echo $(( $(date +%s) - 120 )) >"$DEVZONE_STATE.recouvre"
    run bash "$DEVZONE" apply
    [ "$status" -eq 0 ]
    run test -e "$DEVZONE_STATE.recouvre"
    [ "$status" -ne 0 ]
}

@test "state: no deprecated line on stdout nor stderr (#532)" {
    bats_require_minimum_version 1.5.0
    printf 'ai=on\nports_auto=off\n' >"$DEVZONE_STATE"
    run --separate-stderr bash "$DEVZONE" status
    [ "$status" -eq 0 ]
    [[ "$output" != *"deprecated"* ]] || false
    [[ "$stderr" != *"deprecated"* ]] || false
    run --separate-stderr bash "$DEVZONE" is-enabled ai
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"deprecated"* ]] || false
}
