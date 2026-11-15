#!/usr/bin/env bats
# Leftovers after gitlab disable (#517): Docker containers on the workstation,
# pods in the Kubernetes workspace. Fake docker and kubectl; nothing real runs.

setup() {
    load commun
    kube_isole
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    : >"$BATS_TEST_TMPDIR/docker.log"
    : >"$BATS_TEST_TMPDIR/kubectl.log"
    for outil in docker kubectl; do
        printf '#!/usr/bin/env bash\necho "%s $*" >>"$BATS_TEST_TMPDIR/%s.log"\necho reste-%s\n' "$outil" "$outil" "$outil" >"$BATS_TEST_TMPDIR/bin/$outil"
        chmod +x "$BATS_TEST_TMPDIR/bin/$outil"
    done
    HELPER="$BATS_TEST_DIRNAME/../../.devcontainer/gitlab/test-gitlab-restes.sh"
}

@test "kubernetes workspace: leftovers read with kubectl get pods, no docker (#517)" {
    DEVZONE_WORKSPACE=kubernetes run bash -c '. "$1"; gitlab_restes_conteneurs mon-devzone' _ "$HELPER"
    [ "$status" -eq 0 ] || false
    [[ "$output" == *"reste-kubectl"* ]] || false
    grep -q "get pods --all-namespaces -l devzone.instance=mon-devzone" "$BATS_TEST_TMPDIR/kubectl.log" || false
    [ ! -s "$BATS_TEST_TMPDIR/docker.log" ] || false
}

@test "workstation: leftovers read with docker ps, kubectl not called" {
    run bash -c 'unset DEVZONE_WORKSPACE; . "$1"; gitlab_restes_conteneurs mon-devzone' _ "$HELPER"
    [ "$status" -eq 0 ] || false
    [[ "$output" == *"reste-docker"* ]] || false
    grep -q "ps -aq --filter label=devzone.instance=mon-devzone" "$BATS_TEST_TMPDIR/docker.log" || false
    [ ! -s "$BATS_TEST_TMPDIR/kubectl.log" ] || false
}
