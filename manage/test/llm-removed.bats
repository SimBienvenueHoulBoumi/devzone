#!/usr/bin/env bats
# Removed llm module (#669): migration message, state line dropped, old
# opencode provider removed, the cluster namespace never deleted.

setup() {
    load commun
    kube_isole
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    HM="$BATS_TEST_DIRNAME/../../.devcontainer/ai/host-models.sh"
    export DEVZONE_ROOT="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_STATE="$BATS_TEST_TMPDIR/etat"
    mkdir -p "$DEVZONE_ROOT/workspace" "$BATS_TEST_TMPDIR/bin"
    export FAKE_KUBECTL_LOG="$BATS_TEST_TMPDIR/kubectl.log"
    printf '#!/usr/bin/env bash\necho "kubectl $*" >>"$FAKE_KUBECTL_LOG"\n' >"$BATS_TEST_TMPDIR/bin/kubectl"
    chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    : >"$FAKE_KUBECTL_LOG"
}

@test "enable llm: refused with the migration message, not an unknown module" {
    run bash "$DEVZONE" enable llm
    [ "$status" -eq 1 ]
    [[ "$output" == *"llm module removed"* ]] || false
    [[ "$output" == *"devzone ai"* ]] || false
    [[ "$output" == *"kubectl delete namespace devzone-llm"* ]] || false
    [[ "$output" != *"module inconnu"* ]] || false
}

@test "disable llm with llm=on in the state: the line is dropped, the others kept" {
    printf 'ia=on\nllm=on\npostgres=off\n' >"$DEVZONE_STATE"
    run bash "$DEVZONE" disable llm
    [ "$status" -eq 1 ]
    [[ "$output" == *"llm module removed"* ]] || false
    ! grep -q '^llm=' "$DEVZONE_STATE" || false
    grep -qx 'ia=on' "$DEVZONE_STATE"
    grep -qx 'postgres=off' "$DEVZONE_STATE"
}

@test "llm is no longer a module of the list" {
    run bash "$DEVZONE" modules
    [[ "$output" != *"llm"* ]] || false
}

@test "the namespace and the volume of the model are never deleted by devzone" {
    printf 'llm=on\n' >"$DEVZONE_STATE"
    run bash "$DEVZONE" enable llm
    run bash "$DEVZONE" disable llm
    ! grep -q "delete" "$FAKE_KUBECTL_LOG" || false
}

@test "unset removes the old devzone-llm provider and keeps the other ones" {
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME/.config/opencode"
    printf '%s' '{"provider":{"devzone-llm":{"name":"old"},"devzone-host":{"name":"host"},"autre":{"name":"keep"}}}' >"$HOME/.config/opencode/config.json"
    run bash "$HM" unset
    [ "$status" -eq 0 ]
    [ "$(jq -r '.provider | keys | join(",")' "$HOME/.config/opencode/config.json")" = "autre" ]
}
