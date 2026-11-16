#!/usr/bin/env bats
# Common memory check (#608): verifier_memoire_module refuses under the minimum,
# passes above it, reports an unreachable cluster, and the llm light preset has
# a lower minimum. Fake kubectl in the PATH: no cluster is touched.

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

@test "preset light : 8 Go allouables suffisent au minimum 8 Go, pas au 12 Go" {
    FAUX_MEMOIRE_CLUSTER=8388608Ki run verifier_memoire_module llm 8
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    FAUX_MEMOIRE_CLUSTER=8388608Ki run verifier_memoire_module llm 12 "--preset light (8 Go)"
    [ "$status" -eq 2 ]
    [[ "$output" == *"12 Go"* ]] || false
    [[ "$output" == *"disponible : 8 Go"* ]] || false
    [[ "$output" == *"--preset light"* ]] || false
}
