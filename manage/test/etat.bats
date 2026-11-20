#!/usr/bin/env bats
# Safe write of the module state (#417): lock, temporary file in the state
# folder (never missing for a reader), backup copy, restore, rebuild from the
# namespaces, watcher that does not follow a doubtful state. State, root and
# tools under $BATS_TEST_TMPDIR.

setup() {
    load commun
    relais_docker_isole
    kube_isole
    # Outside the pod by default: the ambient DEVZONE_WORKSPACE (a workspace
    # pod) must not change the messages of these tests
    unset DEVZONE_WORKSPACE
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    ETAT_SH="$BATS_TEST_DIRNAME/../../.devcontainer/etat.sh"
    PORTS_AUTO="$BATS_TEST_DIRNAME/../../.devcontainer/ports-auto.sh"
    export DEVZONE_RACINE="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_ETAT="$BATS_TEST_TMPDIR/racine/.devzone.modules"
    export DEVZONE_INSTANCE=devzone
    export DEVZONE_PORTS_AUTO_DIR="$BATS_TEST_TMPDIR/ports-auto"
    export GIT_CONFIG_NOSYSTEM=1
    mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/relais" "$DEVZONE_RACINE/workspace"
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
    # fake ss and socat: the watcher sees a listening port, nothing is started
    cat >"$BATS_TEST_TMPDIR/bin/ss" <<'SS'
#!/usr/bin/env bash
cat "$BATS_TEST_TMPDIR/ss.listen" 2>/dev/null
exit 0
SS
    cat >"$BATS_TEST_TMPDIR/bin/socat" <<'SOCAT'
#!/usr/bin/env bash
echo "socat $*" >>"$BATS_TEST_TMPDIR/socat.log"
exit 0
SOCAT
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
    : >"$BATS_TEST_TMPDIR/ss.listen"
}

# Concurrent writer: $1 = key prefix, $2 = number of keys (#417)
writer() {
    ETAT="$DEVZONE_ETAT" bash -c '
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
        [ -f "$DEVZONE_ETAT" ] || { echo "state missing during a write (#417)"; return 1; }
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
        grep -qx "a$i=on" "$DEVZONE_ETAT" || { echo "line a$i lost"; false; }
        grep -qx "b$i=on" "$DEVZONE_ETAT" || { echo "line b$i lost"; false; }
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
    printf 'ia=off\n' >"$DEVZONE_ETAT"
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
    printf 'ia=on\nkubernetes=off\ngitlab=on\npostgres=on\n' >"$DEVZONE_ETAT.prec"
    rm -f "$DEVZONE_ETAT"
    run bash "$DEVZONE" is-enabled postgres
    [ "$status" -eq 0 ]
    [[ "$output" == *"restored from the backup copy"* ]] || false
    grep -qx 'postgres=on' "$DEVZONE_ETAT"
    grep -qx 'gitlab=on' "$DEVZONE_ETAT"
    [ -f "$DEVZONE_ETAT.recouvre" ]
}

@test "state removed without a backup copy, devzone namespaces: rebuilt" {
    printf 'ia=on\n' >"$DEVZONE_ETAT"
    rm -f "$DEVZONE_ETAT"
    FAUX_NS="devzone-postgres devzone-gitlab devzone-mysql" run bash "$DEVZONE" is-enabled postgres
    [ "$status" -eq 0 ]
    [[ "$output" == *"rebuilt from the namespaces"* ]] || false
    grep -qx 'postgres=on' "$DEVZONE_ETAT"
    grep -qx 'gitlab=on' "$DEVZONE_ETAT"
    grep -qx 'mysql=on' "$DEVZONE_ETAT"
    grep -qx 'ia=off' "$DEVZONE_ETAT"
    # cluster= expects the real host context that points to the services
    # cluster (docker-desktop here), not the "devzone" context
    grep -qx 'cluster=docker-desktop' "$DEVZONE_ETAT"
    [ -f "$DEVZONE_ETAT.recouvre" ]
}

@test "rebuild: host context not found, no cluster= line but rebuilt" {
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
case "$*" in "config get-contexts -o name"|"config view") exit 1 ;; get\ namespaces*) for n in ${FAUX_NS:-}; do printf 'namespace/%s\n' "$n"; done ;; esac
KUBE
    chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
    printf 'ia=on\n' >"$DEVZONE_ETAT"
    rm -f "$DEVZONE_ETAT"
    FAUX_NS="devzone-postgres devzone-gitlab" run bash "$DEVZONE" is-enabled postgres
    [ "$status" -eq 0 ]
    [[ "$output" == *"rebuilt from the namespaces"* ]] || false
    [[ "$output" == *"no host context"* ]] || false
    grep -qx 'postgres=on' "$DEVZONE_ETAT"
    ! grep -q '^cluster=' "$DEVZONE_ETAT" || false
    [ -f "$DEVZONE_ETAT.recouvre" ]
}

@test "first installation: default state, without backup copy" {
    run bash "$DEVZONE" is-enabled ia
    [ "$status" -eq 1 ]
    grep -qx 'ia=off' "$DEVZONE_ETAT"
    grep -qx 'kubernetes=off' "$DEVZONE_ETAT"
    grep -qx 'gitlab=off' "$DEVZONE_ETAT"
    run test -e "$DEVZONE_ETAT.prec"
    [ "$status" -ne 0 ]
    run test -e "$DEVZONE_ETAT.recouvre"
    [ "$status" -ne 0 ]
}

@test "no mv nor redirection to the state outside state.sh" {
    root="$BATS_TEST_DIRNAME/../.."
    found="$(grep -rn 'mv .*"\$ETAT"\|> *"\$ETAT"' "$root/.devcontainer" "$root/manage" 2>/dev/null |
        grep -v '/etat.sh:' | grep -v '/test/' || true)"
    [ -z "$found" ] || { echo "direct write outside etat.sh: $found"; false; }
}

@test "state: argocd GitOps repository line designates the URL" {
    printf '[argocd]\n    repo = https://github.com/tester/devzone-argocd.git\n' >"$DEVZONE_RACINE/.argocd.conf"
    run bash "$DEVZONE" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"  ○ argocd          GitOps repository: https://github.com/tester/devzone-argocd.git"* ]] || false
}

@test "state: argocd line without GitOps repository: init notice" {
    run bash "$DEVZONE" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"  ○ argocd          no GitOps repository: devzone argocd init"* ]] || false
}

@test "fresh restore: the port watcher does nothing for 60 s" {
    printf 'ia=on\nports_auto=on\n' >"$DEVZONE_ETAT.prec"
    rm -f "$DEVZONE_ETAT"
    run bash "$DEVZONE" is-enabled ia
    [ "$status" -eq 0 ]
    [ -f "$DEVZONE_ETAT.recouvre" ]
    # Port that the watcher would normally relay (0.0.0.0, not the container IP)
    echo 'LISTEN 0 128 0.0.0.0:8080 0.0.0.0:*' >"$BATS_TEST_TMPDIR/ss.listen"
    run bash "$PORTS_AUTO" tour
    [ "$status" -eq 0 ]
    ! grep -q "docker run" "$BATS_TEST_TMPDIR/docker.log" || false
}

@test "restored state not confirmed: the watcher does not uninstall" {
    printf 'ia=on\nports_auto=off\n' >"$DEVZONE_ETAT"
    # Mark older than 60 s: the delay has passed, nothing is confirmed
    echo $(( $(date +%s) - 120 )) >"$DEVZONE_ETAT.recouvre"
    mkdir -p "$DEVZONE_PORTS_AUTO_DIR/devzone"
    printf '8080\n' >"$DEVZONE_PORTS_AUTO_DIR/devzone/actifs"
    : >"$BATS_TEST_TMPDIR/relais/devzone-devzone-auto-8080"
    run bash "$PORTS_AUTO" tour
    [ "$status" -eq 0 ]
    [ -e "$BATS_TEST_TMPDIR/relais/devzone-devzone-auto-8080" ]
}

@test "devzone apply confirms the state: uninstall resumes" {
    printf 'ia=off\ngitlab=off\npostgres=off\nkubernetes=off\nports_auto=off\n' >"$DEVZONE_ETAT"
    echo $(( $(date +%s) - 120 )) >"$DEVZONE_ETAT.recouvre"
    mkdir -p "$DEVZONE_PORTS_AUTO_DIR/devzone"
    printf '8080\n' >"$DEVZONE_PORTS_AUTO_DIR/devzone/actifs"
    : >"$BATS_TEST_TMPDIR/relais/devzone-devzone-auto-8080"
    run bash "$DEVZONE" apply
    [ "$status" -eq 0 ]
    run test -e "$DEVZONE_ETAT.recouvre"
    [ "$status" -ne 0 ]
    run bash "$PORTS_AUTO" tour
    [ "$status" -eq 0 ]
    run test -e "$BATS_TEST_TMPDIR/relais/devzone-devzone-auto-8080"
    [ "$status" -ne 0 ]
}

@test "state: no deprecated line on stdout nor stderr (#532)" {
    bats_require_minimum_version 1.5.0
    printf 'ia=on\nports_auto=off\n' >"$DEVZONE_ETAT"
    run --separate-stderr bash "$DEVZONE" status
    [ "$status" -eq 0 ]
    [[ "$output" != *"deprecated"* ]] || false
    [[ "$stderr" != *"deprecated"* ]] || false
    run --separate-stderr bash "$DEVZONE" is-enabled ia
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"deprecated"* ]] || false
}
