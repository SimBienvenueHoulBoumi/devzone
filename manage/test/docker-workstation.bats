#!/usr/bin/env bats
# Docker workstation put to sleep by the Kubernetes workspace (#517): containers
# stopped by migrate, started again by revert, never removed. Fake docker (see
# below) logs its calls; no real Docker daemon, container or volume is touched.

setup() {
    load migration
    migration_isolate
    # Fake docker of this file replaces the one of migration.bash (same bin folder).
    cat >"$T/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
# Fake docker for docker-workstation.bats: running containers are poste1 (folder)
# and relay1 (devzone.auto); stopped ones are the same when FAKE_EXITED is set.
echo "docker $*" >>"$BATS_TEST_TMPDIR/docker.log"
case "$1" in
    info) [ -z "${FAKE_DOWN:-}" ] ;;
    ps)
        case "$*" in
            *devzone.auto=true*) id=relay1 ;;
            *) id=poste1 ;;
        esac
        if [[ "$*" == *status=exited* ]]; then
            [ -n "${FAKE_EXITED:-}" ] && echo "$id"
        else
            [ -n "${FAKE_RUNNING:-}" ] && echo "$id"
        fi
        ;;
    stop | start) [ -z "${FAKE_OP_KO:-}" ] ;;
    volume) exit 1 ;; # no volume: migrate ignores them
esac
DOCKER
    chmod +x "$T/bin/docker"
    export FAKE_RUNNING=1
    export DEVZONE_WORKSPACE_WAIT=1 DEVZONE_WORKSPACE_STEP=0.1
}

# Calls one function of docker-workstation.sh with folder $1 in a clean shell.
call_fn() {
    run bash -c '. "$1"; "$2" "$3"' _ "$RACINE/manage/scripts/docker-workstation.sh" "$1" "$T/workstation"
}

@test "migrate: running containers and relays stopped, never removed" {
    ws migrate --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"Docker workstation stopped (kept: devzone workspace revert restarts it)"* ]] || false
    grep -qx "docker stop poste1 relay1" "$T/docker.log" || false
    ! grep -qE "docker (rm|kill)|volume rm" "$T/docker.log" || false
    grep -qx "workspace=kubernetes" "$T/workstation/.devzone.modules" || false
}

@test "migrate: no running container, nothing stopped" {
    export FAKE_RUNNING=""
    ws migrate --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"no running container"* ]] || false
    ! grep -q "docker stop" "$T/docker.log" || false
}

@test "revert: stopped containers and relays started again" {
    echo "workspace=kubernetes" >>"$T/workstation/.devzone.modules"
    export FAKE_EXITED=1
    ws revert
    [ "$status" -eq 0 ]
    [[ "$output" == *"Docker workstation started again"* ]] || false
    grep -qx "docker start poste1 relay1" "$T/docker.log" || false
    ! grep -qE "docker (rm|kill)|volume rm" "$T/docker.log" || false
    grep -qx "workspace=docker" "$T/workstation/.devzone.modules" || false
}

@test "revert: no stopped container, nothing started" {
    echo "workspace=kubernetes" >>"$T/workstation/.devzone.modules"
    ws revert
    [ "$status" -eq 0 ]
    [[ "$output" == *"no stopped container to start"* ]] || false
    ! grep -q "docker start" "$T/docker.log" || false
}

@test "stop: Docker down, warning only, no docker stop" {
    export FAKE_DOWN=1
    call_fn docker_workstation_stop
    [ "$status" -eq 0 ]
    [[ "$output" == *"Docker does not respond, nothing stopped"* ]] || false
    ! grep -q "docker stop" "$T/docker.log" || false
}

@test "start: Docker down, warning only, no docker start" {
    export FAKE_DOWN=1 FAKE_EXITED=1
    call_fn docker_workstation_start
    [ "$status" -eq 0 ]
    [[ "$output" == *"Docker does not respond, nothing started"* ]] || false
    ! grep -q "docker start" "$T/docker.log" || false
}

@test "stop: docker stop fails, warning and success status" {
    export FAKE_OP_KO=1
    call_fn docker_workstation_stop
    [ "$status" -eq 0 ]
    [[ "$output" == *"some containers could not be stopped"* ]] || false
}

@test "start: docker start fails, warning and success status" {
    export FAKE_EXITED=1 FAKE_OP_KO=1
    call_fn docker_workstation_start
    [ "$status" -eq 0 ]
    [[ "$output" == *"some containers could not be started"* ]] || false
}
