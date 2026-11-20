#!/usr/bin/env bats
# Common memory check (#608, #612): check_module_memory refuses under the
# minimum, passes above it, reports an unreachable cluster. The minimum is
# given by the caller (gitlab: 8 GiB). The cluster rule (#612): the nodes of a kind
# cluster share one VM, so memory_cluster_ki returns their greatest memory
# instead of their sum; any other cluster keeps the sum, and the refusal
# message says when a single node was measured. Fake kubectl in the PATH: no
# cluster is touched.

setup() {
    bats_require_minimum_version 1.5.0
    load commun
    kube_isole
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    MEMORY_SH="$ROOT/.devcontainer/memoire.sh"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin"
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
case "$*" in
    *"get nodes -o jsonpath"*)
        [ -n "${FAUX_MEMOIRE_CLUSTER:-}" ] || exit 1
        # Payload of the providerID|memory jsonpath (#612): one line per node,
        # a line without "|" is the memory of a node without providerID.
        printf '%s\n' "$FAUX_MEMOIRE_CLUSTER" ;;
esac
exit 0
KUBE
    chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    # The common function reads the nodes through the admin account (#430):
    # the test provides it, the fake kubectl answers.
    compte_ctx() { echo docker-desktop; }
    compte_admin() { kubectl --context "$1" "${@:2}"; }
    . "$MEMORY_SH"
    # One "<providerID>|<memory>" line per node, exported for the fake kubectl.
    faux_noeuds() {
        FAUX_MEMOIRE_CLUSTER="$(printf '%s\n' "$@")"
        export FAUX_MEMOIRE_CLUSTER
    }
}

@test "gitlab: 8 GiB allocatable is enough for the 8 GiB minimum, not for 12 GiB" {
    FAUX_MEMOIRE_CLUSTER=8388608Ki run check_module_memory gitlab 8
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    FAUX_MEMOIRE_CLUSTER=8388608Ki run check_module_memory gitlab 12
    [ "$status" -eq 2 ]
    [[ "$output" == *"12 GiB"* ]] || false
    [[ "$output" == *"available: 8 GiB"* ]] || false
}

@test "enough memory: 16 GiB allocatable, minimum 8 GiB → 0, says nothing" {
    FAUX_MEMOIRE_CLUSTER=16777216Ki run check_module_memory gitlab 8
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "under the minimum: 4 GiB allocatable, minimum 8 GiB → 2, minimum and available in the message" {
    FAUX_MEMOIRE_CLUSTER=4000000Ki run check_module_memory gitlab 8
    [ "$status" -eq 2 ]
    [[ "$output" == *"8 GiB"* ]] || false
    [[ "$output" == *"available: 3 GiB"* ]] || false
    [[ "$output" == *"enlarge the cluster"* ]] || false
    [[ "$output" == *"devzone enable gitlab"* ]] || false
}

@test "unreachable cluster → 2, message says the services cluster is unreachable" {
    run check_module_memory gitlab 8
    [ "$status" -eq 2 ]
    [[ "$output" == *"services cluster unreachable: devzone cluster"* ]] || false
}

@test "gitlab: exact message under 8 GiB (behaviour unchanged)" {
    FAUX_MEMOIRE_CLUSTER=4000000Ki run check_module_memory gitlab 8
    [ "$status" -eq 2 ]
    [ "$output" = "devzone : gitlab : at least 8 GiB of allocatable memory is needed in the cluster (available: 3 GiB) ; enlarge the cluster (Docker Desktop → Settings → Resources) then retry: devzone enable gitlab" ]
}

@test "4 identical kind nodes: maximum and not sum, maximum rule set" {
    faux_noeuds 'kind://docker/desktop/kind-control-plane|20449328Ki' \
        'kind://docker/desktop/kind-worker|20449328Ki' \
        'kind://docker/desktop/kind-worker2|20449328Ki' \
        'kind://docker/desktop/kind-worker3|20449328Ki'
    run memory_cluster_ki
    [ "$status" -eq 0 ]
    [ "$output" = "20449328" ]
    memory_cluster_ki >/dev/null
    [ "$MEMORY_RULE" = "maximum" ]
    [ "$MEMORY_KI" = "20449328" ]
}

@test "3 non-kind nodes of different sizes: sum, sum rule set" {
    faux_noeuds 'aws:///eu-west-1a/i-01|4000000Ki' \
        'gce://europe-west1-b/g-02|2000000Ki' \
        'openstack://ex/n-03|1000000Ki'
    run memory_cluster_ki
    [ "$status" -eq 0 ]
    [ "$output" = "7000000" ]
    memory_cluster_ki >/dev/null
    [ "$MEMORY_RULE" = "sum" ]
    [ "$MEMORY_KI" = "7000000" ]
}

@test "mix of kind and non-kind nodes: sum" {
    faux_noeuds 'kind://docker/desktop/n1|4000000Ki' \
        'kind://docker/desktop/n2|4000000Ki' \
        'aws:///eu-west-1a/i-01|4000000Ki'
    run memory_cluster_ki
    [ "$status" -eq 0 ]
    [ "$output" = "12000000" ]
    memory_cluster_ki >/dev/null
    [ "$MEMORY_RULE" = "sum" ]
}

@test "empty providerID on every node: sum" {
    faux_noeuds '|4000000Ki' '|4000000Ki' '|4000000Ki'
    run memory_cluster_ki
    [ "$status" -eq 0 ]
    [ "$output" = "12000000" ]
    memory_cluster_ki >/dev/null
    [ "$MEMORY_RULE" = "sum" ]
}

@test "refusal on a kind cluster: the message says single-node memory" {
    faux_noeuds 'kind://docker/desktop/n1|4000000Ki' \
        'kind://docker/desktop/n2|4000000Ki' \
        'kind://docker/desktop/n3|4000000Ki' \
        'kind://docker/desktop/n4|4000000Ki'
    run check_module_memory gitlab 8
    [ "$status" -eq 2 ]
    [[ "$output" == *"available: 3 GiB"* ]] || false
    [[ "$output" == *"memory of a single node: kind cluster, shared VM"* ]] || false
}
