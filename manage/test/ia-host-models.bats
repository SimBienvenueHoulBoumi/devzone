#!/usr/bin/env bats
# Host (Ollama) model detection and the devzone-host opencode provider (#665).
# Fake Ollama (fake curl), no network, no cluster.

setup() {
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    HM="$BATS_TEST_DIRNAME/../../.devcontainer/ia/host-models.sh"
    export HOME="$BATS_TEST_TMPDIR/home"
    export DEVZONE_RACINE="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_OLLAMA_URL="http://host.docker.internal:11434"
    mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin" "$DEVZONE_RACINE/workspace"
    : >"$BATS_TEST_TMPDIR/curl.log"
    export FAKE_CURL="$BATS_TEST_TMPDIR/curl.log"
    export FAKE_OLLAMA=ok
    unset DEVZONE_HOST_MODEL
    rm -f "$HOME/.config/opencode/config.json"
    # Fake Ollama: /api/tags returns a JSON payload; anything else succeeds.
    cat >"$BATS_TEST_TMPDIR/bin/curl" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_CURL"
case "$*" in
    *"/api/tags"*)
        if [ "${FAKE_OLLAMA:-ok}" = ok ]; then
            printf '%s' '{"models":[{"name":"qwen3-coder:32k","size":12345,"details":{"type":"llm"}},{"name":"nomic-embed-text:latest","size":67890,"details":{"type":"embedding"}},{"name":"deepseek-coder:latest","size":999,"details":{"type":"llm"}}]}'
        else
            exit 1
        fi
        ;;
    *) exit 0 ;;
esac
FAKE
    chmod +x "$BATS_TEST_TMPDIR/bin/curl"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "detection: lists non-embedding models and ignores embedding models" {
    run bash "$HM"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c .)" -eq 2 ]
    [[ "$output" == *"qwen3-coder:32k"* ]] || false
    [[ "$output" == *"deepseek-coder:latest"* ]] || false
    [[ "$output" != *"nomic-embed-text"* ]] || false
}

@test "detection: first model and DEVZONE_HOST_MODEL override" {
    run bash "$HM" first
    [ "$status" -eq 0 ]
    [ "$output" = "qwen3-coder:32k" ]
    DEVZONE_HOST_MODEL=deepseek-coder:latest run bash "$HM" first
    [ "$status" -eq 0 ]
    [ "$output" = "deepseek-coder:latest" ]
}

@test "absence: Ollama does not answer -> clean exit, nothing written" {
    FAKE_OLLAMA=ko run bash "$HM"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    FAKE_OLLAMA=ko run bash "$HM" first
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "set: merges the devzone-host provider and keeps the rest of the file" {
    mkdir -p "$HOME/.config/opencode"
    printf '{"model":"x/y","provider":{"autre":{"name":"a"}}}' >"$HOME/.config/opencode/config.json"
    run bash "$HM" set
    [ "$status" -eq 0 ]
    F="$HOME/.config/opencode/config.json"
    [ "$(jq -r '.provider["devzone-host"].npm' "$F")" = "@ai-sdk/openai-compatible" ]
    [ "$(jq -r '.provider["devzone-host"].options.baseURL' "$F")" = "http://host.docker.internal:11434/v1" ]
    [ "$(jq -r '.provider["devzone-host"].models | keys | join(",")' "$F")" = "deepseek-coder:latest,qwen3-coder:32k" ]
    [ "$(jq -r .model "$F")" = "x/y" ]
    [ "$(jq -r '.provider.autre.name' "$F")" = a ]
}

@test "set: invalid JSON is left untouched and fails" {
    mkdir -p "$HOME/.config/opencode"
    printf '{ nope' >"$HOME/.config/opencode/config.json"
    run bash "$HM" set
    [ "$status" -ne 0 ]
    [ "$(cat "$HOME/.config/opencode/config.json")" = '{ nope' ]
}

@test "unset: removes the devzone-host provider and keeps the rest" {
    bash "$HM" set
    run bash "$HM" unset
    [ "$status" -eq 0 ]
    [ ! -e "$HOME/.config/opencode/config.json" ]

    mkdir -p "$HOME/.config/opencode"
    printf '{"model":"x/y","provider":{"autre":{"name":"a"}}}' >"$HOME/.config/opencode/config.json"
    bash "$HM" set
    bash "$HM" unset
    F="$HOME/.config/opencode/config.json"
    [ "$(jq -r '.provider | keys | join(",")' "$F")" = autre ]
    [ "$(jq -r .model "$F")" = "x/y" ]
    [ "$(jq -r '.provider.autre.name' "$F")" = a ]
    [ "$(jq -e '.provider["devzone-host"]' "$F" >/dev/null 2>&1; echo $?)" -ne 0 ]
}

@test "agent: host model is the local model, after every online model" {
    # Module ia (and llm) on: the local slot is the host model detected via /api/tags.
    printf 'ia=on\nllm=on\n' >"$DEVZONE_RACINE/.devzone.modules"
    export DEVZONE_AGENT_ETAT="$BATS_TEST_TMPDIR/etat"
    export FAKE_ARGS="$BATS_TEST_TMPDIR/refs.log"
    : >"$FAKE_ARGS"
    mkdir -p "$DEVZONE_AGENT_ETAT" "$DEVZONE_RACINE/workspace/projet"
    printf 'construis la feature\n' >"$DEVZONE_RACINE/workspace/consigne.txt"
    # Fake opencode: two online models, every attempt fails so the whole rotation runs.
    cat >"$BATS_TEST_TMPDIR/bin/opencode" <<'FAKE'
#!/usr/bin/env bash
case "${1:-}" in
    models) printf 'opencode/big-pickle\nopencode/glm-5.3-flash-free\n' ;;
    run)
        ref=""
        prev=""
        for a in "$@"; do
            [ "$prev" = -m ] && ref="$a"
            prev="$a"
        done
        echo "$ref" >>"$FAKE_ARGS"
        exit 1
        ;;
esac
FAKE
    chmod +x "$BATS_TEST_TMPDIR/bin/opencode"
    run bash "$DEVZONE" agent "$DEVZONE_RACINE/workspace/projet" "$DEVZONE_RACINE/workspace/consigne.txt"
    [ "$status" -eq 3 ]
    [ "$(tail -1 "$FAKE_ARGS")" = "devzone-host/qwen3-coder:32k" ]
    [ "$(grep -c '^opencode/' "$FAKE_ARGS")" -eq 2 ]
    [ "$(grep -c 'devzone-host/qwen3-coder:32k' "$FAKE_ARGS")" -eq 1 ]
}

# Fake opencode for the rotation tests: online models fail quietly (exit 1, no
# known cause); the host model (devzone-host/...) hits the quota. Every
# reference passed to -m is recorded in $FAKE_ARGS.
fake_opencode_rotation() {
    export DEVZONE_AGENT_ETAT="$BATS_TEST_TMPDIR/etat"
    export FAKE_ARGS="$BATS_TEST_TMPDIR/refs.log"
    : >"$FAKE_ARGS"
    mkdir -p "$DEVZONE_AGENT_ETAT" "$DEVZONE_RACINE/workspace/projet"
    printf 'construis la feature\n' >"$DEVZONE_RACINE/workspace/consigne.txt"
    cat >"$BATS_TEST_TMPDIR/bin/opencode" <<'FAKE'
#!/usr/bin/env bash
case "${1:-}" in
    models) printf 'opencode/big-pickle\nopencode/glm-5.3-flash-free\n' ;;
    run)
        ref=""
        prev=""
        for a in "$@"; do
            [ "$prev" = -m ] && ref="$a"
            prev="$a"
        done
        echo "$ref" >>"$FAKE_ARGS"
        case "$ref" in
            devzone-host/*)
                echo "timestamp=2026-01-01T00:00:00.000Z level=ERROR message=stream error providerID=devzone-host error=AI_APICallError: Free usage limit" >&2
                ;;
        esac
        exit 1
        ;;
esac
FAKE
    chmod +x "$BATS_TEST_TMPDIR/bin/opencode"
}

@test "agent: the host model is tried even when the llm module is off" {
    unset DEVZONE_WORKSPACE
    printf 'ia=on\n' >"$DEVZONE_RACINE/.devzone.modules"
    fake_opencode_rotation
    run bash "$DEVZONE" agent "$DEVZONE_RACINE/workspace/projet" "$DEVZONE_RACINE/workspace/consigne.txt"
    [ "$status" -eq 3 ]
    [ "$(tail -1 "$FAKE_ARGS")" = "devzone-host/qwen3-coder:32k" ]
    [ "$(grep -c '^opencode/' "$FAKE_ARGS")" -eq 2 ]
    ! grep -q 'devzone-llm' "$FAKE_ARGS" || false
}

@test "agent: a host model name with slashes sets no stray file and keeps its exact reference" {
    unset DEVZONE_WORKSPACE
    printf 'ia=on\n' >"$DEVZONE_RACINE/.devzone.modules"
    # Fake Ollama: one model whose name has slashes and a colon (as pulled from Hugging Face).
    cat >"$BATS_TEST_TMPDIR/bin/curl" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_CURL"
case "$*" in
    *"/api/tags"*)
        printf '%s' '{"models":[{"name":"hf.co/ggml-org/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-GGUF:Q4_0","size":1,"details":{"type":"llm"}}]}'
        ;;
    *) exit 0 ;;
esac
FAKE
    chmod +x "$BATS_TEST_TMPDIR/bin/curl"
    fake_opencode_rotation
    run bash "$DEVZONE" agent "$DEVZONE_RACINE/workspace/projet" "$DEVZONE_RACINE/workspace/consigne.txt"
    [ "$status" -eq 3 ]
    # The reference given to opencode keeps the exact model name
    [ "$(tail -1 "$FAKE_ARGS")" = "devzone-host/hf.co/ggml-org/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-GGUF:Q4_0" ]
    # The set-aside file has a slash-free internal name, nothing is created in a sub-folder
    [ -f "$DEVZONE_AGENT_ETAT/ecart-hf.co_ggml-org_NVIDIA-Nemotron-3.5-Lightning-30B-A3B-GGUF_Q4_0" ]
    [ ! -e "$DEVZONE_AGENT_ETAT/ecart-hf.co" ]
    [ -z "$(find "$DEVZONE_AGENT_ETAT" -mindepth 1 -type d -name 'ecart-*')" ]
}
