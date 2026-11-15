#!/usr/bin/env bats
# Module llm (#586): opencode provider devzone-llm in ~/.config/opencode/config.json.

setup() {
    OC="$BATS_TEST_DIRNAME/../../.devcontainer/llm/opencode.sh"
    export HOME="$BATS_TEST_TMPDIR/home"
    F="$HOME/.config/opencode/config.json"
    unset DEVZONE_WORKSPACE LLM_PORT
}

@test "set: provider openai-compatible, model local, relay URL in the container" {
    run bash "$OC" set
    [ "$status" -eq 0 ]
    [ "$(jq -r '.provider["devzone-llm"].npm' "$F")" = "@ai-sdk/openai-compatible" ]
    [ "$(jq -r '.provider["devzone-llm"].options.baseURL' "$F")" = "http://127.0.0.1:8089/v1" ]
    [ "$(jq -r '.provider["devzone-llm"].models | keys[0]' "$F")" = "local" ]
}

@test "set: LLM_PORT changes the relay URL, the pod uses the cluster DNS" {
    LLM_PORT=9000 run bash "$OC" url
    [ "$output" = "http://127.0.0.1:9000/v1" ]
    DEVZONE_WORKSPACE=kubernetes run bash "$OC" url
    [ "$output" = "http://llm.devzone-llm.svc.cluster.local:8080/v1" ]
}

@test "set: twice gives the same file, other keys and providers kept" {
    mkdir -p "$(dirname "$F")"
    echo '{"model":"x/y","provider":{"autre":{"name":"a"}}}' >"$F"
    bash "$OC" set
    cp "$F" "$BATS_TEST_TMPDIR/first"
    bash "$OC" set
    cmp "$F" "$BATS_TEST_TMPDIR/first"
    [ "$(jq -r .model "$F")" = "x/y" ]
    [ "$(jq -r '.provider.autre.name' "$F")" = a ]
}

@test "unset: file removed when it held only our provider" {
    bash "$OC" set
    run bash "$OC" unset
    [ "$status" -eq 0 ]
    [ ! -e "$F" ]
}

@test "unset: only our provider leaves, the rest stays; no file is fine" {
    run bash "$OC" unset
    [ "$status" -eq 0 ]
    mkdir -p "$(dirname "$F")"
    echo '{"model":"x/y","provider":{"autre":{"name":"a"}}}' >"$F"
    bash "$OC" set
    bash "$OC" unset
    [ "$(jq -r '.provider | keys | join(",")' "$F")" = autre ]
    [ "$(jq -r .model "$F")" = "x/y" ]
}

@test "set: invalid JSON in the file is left untouched, error" {
    mkdir -p "$(dirname "$F")"
    echo '{ nope' >"$F"
    run bash "$OC" set
    [ "$status" -ne 0 ]
    [ "$(cat "$F")" = '{ nope' ]
}
