#!/usr/bin/env bats
# Common memory check (#608, #612): verifier_memoire_module refuses under the
# minimum, passes above it, reports an unreachable cluster. The minimum is
# given by the caller (gitlab: 8 Go). The cluster rule (#612): the nodes of a kind
# cluster share one VM, so memoire_cluster_ki returns their greatest memory
# instead of their sum; any other cluster keeps the sum, and the refusal
# message says when a single node was measured. Fake kubectl in the PATH: no
# cluster is touched.

setup() {
    bats_require_minimum_version 1.5.0
    load commun
    kube_isole
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    MEMOIRE="$RACINE/.devcontainer/memoire.sh"
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
    . "$MEMOIRE"
    # One "<providerID>|<memory>" line per node, exported for the fake kubectl.
    faux_noeuds() {
        FAUX_MEMOIRE_CLUSTER="$(printf '%s\n' "$@")"
        export FAUX_MEMOIRE_CLUSTER
    }
}

@test "gitlab : 8 Go allouables suffisent au minimum 8 Go, pas au 12 Go" {
    FAUX_MEMOIRE_CLUSTER=8388608Ki run verifier_memoire_module gitlab 8
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    FAUX_MEMOIRE_CLUSTER=8388608Ki run verifier_memoire_module gitlab 12
    [ "$status" -eq 2 ]
    [[ "$output" == *"12 Go"* ]] || false
    [[ "$output" == *"disponible : 8 Go"* ]] || false
}

@test "assez de mémoire : 16 Go allouables, minimum 8 Go → 0, rien dit" {
    FAUX_MEMOIRE_CLUSTER=16777216Ki run verifier_memoire_module gitlab 8
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "sous le minimum : 4 Go allouables, minimum 8 Go → 2, message minimum et disponible" {
    FAUX_MEMOIRE_CLUSTER=4000000Ki run verifier_memoire_module gitlab 8
    [ "$status" -eq 2 ]
    [[ "$output" == *"8 Go"* ]] || false
    [[ "$output" == *"disponible : 3 Go"* ]] || false
    [[ "$output" == *"agrandir le cluster"* ]] || false
    [[ "$output" == *"devzone enable gitlab"* ]] || false
}

@test "cluster injoignable → 2, message cluster des services injoignable" {
    run verifier_memoire_module gitlab 8
    [ "$status" -eq 2 ]
    [[ "$output" == *"cluster des services injoignable : devzone cluster"* ]] || false
}

@test "gitlab : message exact sous 8 Go (comportement inchangé)" {
    FAUX_MEMOIRE_CLUSTER=4000000Ki run verifier_memoire_module gitlab 8
    [ "$status" -eq 2 ]
    [ "$output" = "devzone : gitlab : il faut au moins 8 Go de mémoire allouable dans le cluster (disponible : 3 Go) ; agrandir le cluster (Docker Desktop → Settings → Resources) puis relancer : devzone enable gitlab" ]
}

@test "4 nœuds kind identiques : maximum et non somme, règle maximum posée" {
    faux_noeuds 'kind://docker/desktop/kind-control-plane|20449328Ki' \
        'kind://docker/desktop/kind-worker|20449328Ki' \
        'kind://docker/desktop/kind-worker2|20449328Ki' \
        'kind://docker/desktop/kind-worker3|20449328Ki'
    run memoire_cluster_ki
    [ "$status" -eq 0 ]
    [ "$output" = "20449328" ]
    memoire_cluster_ki >/dev/null
    [ "$MEMOIRE_REGLE" = "maximum" ]
    [ "$MEMOIRE_KI" = "20449328" ]
}

@test "3 nœuds hors kind de tailles différentes : somme, règle somme posée" {
    faux_noeuds 'aws:///eu-west-1a/i-01|4000000Ki' \
        'gce://europe-west1-b/g-02|2000000Ki' \
        'openstack://ex/n-03|1000000Ki'
    run memoire_cluster_ki
    [ "$status" -eq 0 ]
    [ "$output" = "7000000" ]
    memoire_cluster_ki >/dev/null
    [ "$MEMOIRE_REGLE" = "somme" ]
    [ "$MEMOIRE_KI" = "7000000" ]
}

@test "mélange de nœuds kind et hors kind : somme" {
    faux_noeuds 'kind://docker/desktop/n1|4000000Ki' \
        'kind://docker/desktop/n2|4000000Ki' \
        'aws:///eu-west-1a/i-01|4000000Ki'
    run memoire_cluster_ki
    [ "$status" -eq 0 ]
    [ "$output" = "12000000" ]
    memoire_cluster_ki >/dev/null
    [ "$MEMOIRE_REGLE" = "somme" ]
}

@test "providerID vide sur tous les nœuds : somme" {
    faux_noeuds '|4000000Ki' '|4000000Ki' '|4000000Ki'
    run memoire_cluster_ki
    [ "$status" -eq 0 ]
    [ "$output" = "12000000" ]
    memoire_cluster_ki >/dev/null
    [ "$MEMOIRE_REGLE" = "somme" ]
}

@test "refus sur un cluster kind : le message dit mémoire d'un seul nœud" {
    faux_noeuds 'kind://docker/desktop/n1|4000000Ki' \
        'kind://docker/desktop/n2|4000000Ki' \
        'kind://docker/desktop/n3|4000000Ki' \
        'kind://docker/desktop/n4|4000000Ki'
    run verifier_memoire_module gitlab 8
    [ "$status" -eq 2 ]
    [[ "$output" == *"disponible : 3 Go"* ]] || false
    [[ "$output" == *"mémoire d'un seul nœud : cluster kind, VM partagée"* ]] || false
}
