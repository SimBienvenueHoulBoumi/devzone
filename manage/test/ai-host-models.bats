#!/usr/bin/env bats
# Host (Ollama) model detection, default choice and update check (#665, #668).
# Fake Ollama and fake registry (fake curl), no network, no cluster.

setup() {
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    HM="$BATS_TEST_DIRNAME/../../.devcontainer/ai/host-models.sh"
    HC="$BATS_TEST_DIRNAME/../../.devcontainer/ai/host-check.sh"
    export HOME="$BATS_TEST_TMPDIR/home"
    export DEVZONE_ROOT="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_OLLAMA_URL="http://host.docker.internal:11434"
    export DEVZONE_OLLAMA_REGISTRY="http://registre.faux"
    unset DEVZONE_HOST_MODEL DEVZONE_AI_MEASURES
    mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin" "$DEVZONE_ROOT/workspace" "$BATS_TEST_TMPDIR/manifests"
    : >"$BATS_TEST_TMPDIR/curl.log"
    export FAKE_CURL="$BATS_TEST_TMPDIR/curl.log"
    export FAKE_OLLAMA=ok
    export FAKE_REGISTRY=on
    export FAKE_MANIFEST_DIR="$BATS_TEST_TMPDIR/manifests"
    export FAKE_TAGS='{"models":[{"name":"qwen3-coder:32k","size":12345,"digest":"sha256:aaaaaaaa","details":{"type":"llm"}},{"name":"nomic-embed-text:latest","size":67890,"details":{"type":"embedding"}},{"name":"deepseek-coder:latest","size":99999,"digest":"sha256:bbbbbbbb","details":{"type":"llm"}}]}'
    rm -f "$HOME/.config/opencode/config.json" "$HOME/.config/devzone/ai-measures.json"
    # Fake Ollama: /api/tags returns $FAKE_TAGS; fake registry: a manifest file
    # per name/tag, exit 1 (404) when absent; honors -o like curl.
    cat >"$BATS_TEST_TMPDIR/bin/curl" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_CURL"
sortie=""
url=""
prev=""
for a in "$@"; do
    [ "$prev" = "-o" ] && sortie="$a"
    prev="$a"
done
for a in "$@"; do url="$a"; done
ecrire() {
    if [ -n "$sortie" ]; then cat >"$sortie"; else cat; fi
}
case "$url" in
    *"/api/tags"*)
        [ "${FAKE_OLLAMA:-ok}" = ok ] || exit 1
        printf '%s' "$FAKE_TAGS" | ecrire
        ;;
    *"/v2/library/"*)
        [ "${FAKE_REGISTRY:-on}" = on ] || exit 1
        rest="${url#*/v2/library/}"
        nom="${rest%%/manifests/*}"
        tag="${rest##*/manifests/}"
        [ -f "$FAKE_MANIFEST_DIR/$nom/$tag" ] || exit 1
        cat "$FAKE_MANIFEST_DIR/$nom/$tag" | ecrire
        ;;
    *) exit 0 ;;
esac
FAKE
    chmod +x "$BATS_TEST_TMPDIR/bin/curl"
    # Fake ollama: records any call (must never happen).
    cat >"$BATS_TEST_TMPDIR/bin/ollama" <<'FAKE'
#!/usr/bin/env bash
echo "ollama $*" >>"$FAKE_CURL"
FAKE
    chmod +x "$BATS_TEST_TMPDIR/bin/ollama"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# Writes a fake registry manifest and prints its sha256.
pose_manifest() {
    local nom="$1" tag="$2" corps="$3"
    mkdir -p "$FAKE_MANIFEST_DIR/$nom"
    printf '%s' "$corps" >"$FAKE_MANIFEST_DIR/$nom/$tag"
    sha256sum "$FAKE_MANIFEST_DIR/$nom/$tag" | cut -d' ' -f1
}

@test "detection: lists non-embedding models and ignores embedding models" {
    run bash "$HM"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c .)" -eq 2 ]
    [[ "$output" == *"qwen3-coder:32k"* ]] || false
    [[ "$output" == *"deepseek-coder:latest"* ]] || false
    [[ "$output" != *"nomic-embed-text"* ]] || false
}

@test "detection: default model and DEVZONE_HOST_MODEL override" {
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

@test "first: the measurement wins, an undetected model is ignored" {
    mkdir -p "$HOME/.config/devzone"
    cat >"$HOME/.config/devzone/ai-measures.json" <<'EOF'
{"qwen3-coder:32k":{"reussite":0.8,"tok_s":500,"date":"2026-11-19"},"deepseek-coder:latest":{"reussite":0.9,"tok_s":100,"date":"2026-11-19"},"inconnu:latest":{"reussite":1.0,"tok_s":999,"date":"2026-11-19"}}
EOF
    run bash "$HM" first
    [ "$status" -eq 0 ]
    [ "$output" = "deepseek-coder:latest" ]
}

@test "first: at equal success, the highest tok_s speed wins" {
    mkdir -p "$HOME/.config/devzone"
    cat >"$HOME/.config/devzone/ai-measures.json" <<'EOF'
{"qwen3-coder:32k":{"reussite":0.9,"tok_s":500,"date":"2026-11-19"},"deepseek-coder:latest":{"reussite":0.9,"tok_s":100,"date":"2026-11-19"}}
EOF
    run bash "$HM" first
    [ "$status" -eq 0 ]
    [ "$output" = "qwen3-coder:32k" ]
}

@test "first: without a measurement, a name containing coder first, then the smallest size" {
    export FAKE_TAGS='{"models":[{"name":"aaa-small:1","size":1,"details":{"type":"llm"}},{"name":"bbb-coder:1","size":9999,"details":{"type":"llm"}},{"name":"ccc-coder:1","size":5000,"details":{"type":"llm"}}]}'
    run bash "$HM" first
    [ "$status" -eq 0 ]
    [ "$output" = "ccc-coder:1" ]
}

@test "first: without a measurement, at equal size the name order decides" {
    export FAKE_TAGS='{"models":[{"name":"zzz-coder:1","size":10,"details":{"type":"llm"}},{"name":"aaa-coder:1","size":10,"details":{"type":"llm"}}]}'
    run bash "$HM" first
    [ "$status" -eq 0 ]
    [ "$output" = "aaa-coder:1" ]
}

@test "first: Nemotron is no longer first, the rule picks the coder" {
    export FAKE_TAGS='{"models":[{"name":"hf.co/ggml-org/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-GGUF:Q4_0","size":1,"details":{"type":"llm"}},{"name":"qwen3-coder:32k","size":12345,"details":{"type":"llm"}}]}'
    run bash "$HM" first
    [ "$status" -eq 0 ]
    [ "$output" = "qwen3-coder:32k" ]
}

@test "check: up to date when the manifest sha256 matches the local digest" {
    h="$(pose_manifest qwen3-coder 32k '{"schemaVersion":2}')"
    export FAKE_TAGS="{\"models\":[{\"name\":\"qwen3-coder:32k\",\"size\":1,\"digest\":\"sha256:$h\",\"details\":{\"type\":\"llm\"}}]}"
    run bash "$HC" check
    [ "$status" -eq 0 ]
    [[ "$output" == *"qwen3-coder:32k : up to date"* ]] || false
    [[ "$output" != *"update available"* ]] || false
}

@test "check: update available, the ollama pull command is printed" {
    pose_manifest qwen3-coder 32k '{"schemaVersion":2}' >/dev/null
    export FAKE_TAGS='{"models":[{"name":"qwen3-coder:32k","size":1,"digest":"sha256:deadbeef","details":{"type":"llm"}}]}'
    run bash "$HC" check
    [ "$status" -eq 0 ]
    [[ "$output" == *"qwen3-coder:32k : update available"* ]] || false
    [[ "$output" == *"ollama pull qwen3-coder:32k"* ]] || false
}

@test "check: not verifiable (hf.co, 404, registry unreachable)" {
    h="$(pose_manifest qwen3-coder 32k '{"schemaVersion":2}')"
    export FAKE_TAGS="{\"models\":[{\"name\":\"hf.co/ggml-org/Nemotron:Q4_0\",\"size\":1,\"digest\":\"sha256:$h\",\"details\":{\"type\":\"llm\"}},{\"name\":\"absent:latest\",\"size\":1,\"digest\":\"sha256:$h\",\"details\":{\"type\":\"llm\"}},{\"name\":\"qwen3-coder:32k\",\"size\":1,\"digest\":\"sha256:$h\",\"details\":{\"type\":\"llm\"}}]}"
    run bash "$HC" check
    [ "$status" -eq 0 ]
    [[ "$output" == *"hf.co/ggml-org/Nemotron:Q4_0 : not verifiable"* ]] || false
    [[ "$output" == *"absent:latest : not verifiable"* ]] || false
    [[ "$output" == *"qwen3-coder:32k : up to date"* ]] || false

    FAKE_REGISTRY=off run bash "$HC" check
    [ "$status" -eq 0 ]
    [[ "$output" == *"qwen3-coder:32k : not verifiable"* ]] || false
}

@test "check: a single manifest GET per model, no download" {
    h="$(pose_manifest qwen3-coder 32k '{"schemaVersion":2}')"
    pose_manifest deepseek-coder latest '{"schemaVersion":2}' >/dev/null
    export FAKE_TAGS="{\"models\":[{\"name\":\"qwen3-coder:32k\",\"size\":1,\"digest\":\"sha256:$h\",\"details\":{\"type\":\"llm\"}},{\"name\":\"deepseek-coder:latest\",\"size\":1,\"digest\":\"sha256:$h\",\"details\":{\"type\":\"llm\"}}]}"
    : >"$FAKE_CURL"
    run bash "$HC" check
    [ "$status" -eq 0 ]
    [ "$(grep -c '/v2/library/' "$FAKE_CURL")" -eq 2 ]
    ! grep -q '/api/pull' "$FAKE_CURL" || false
    ! grep -q '^ollama ' "$FAKE_CURL" || false
}

@test "check: Ollama unreachable -> clean message" {
    FAKE_OLLAMA=ko run bash "$HC" check
    [ "$status" -eq 0 ]
    [[ "$output" == *"no Ollama model detected"* ]] || false
}

@test "report: shows the chosen model and the reason (rule)" {
    h="$(pose_manifest qwen3-coder 32k '{"schemaVersion":2}')"
    export FAKE_TAGS="{\"models\":[{\"name\":\"qwen3-coder:32k\",\"size\":12345,\"digest\":\"sha256:$h\",\"details\":{\"type\":\"llm\"}}]}"
    run bash "$HC" rapport
    [ "$status" -eq 0 ]
    [[ "$output" == *"qwen3-coder:32k : up to date ; size 12345"* ]] || false
    [[ "$output" == *"chosen model: qwen3-coder:32k (rule)"* ]] || false
}

@test "report: the reason is the DEVZONE_HOST_MODEL variable when it is set" {
    pose_manifest qwen3-coder 32k '{"schemaVersion":2}' >/dev/null
    export FAKE_TAGS='{"models":[{"name":"qwen3-coder:32k","size":1,"digest":"sha256:aaaaaaaa","details":{"type":"llm"}}]}'
    DEVZONE_HOST_MODEL=deepseek-coder:latest run bash "$HC" rapport
    [ "$status" -eq 0 ]
    [[ "$output" == *"chosen model: deepseek-coder:latest (DEVZONE_HOST_MODEL)"* ]] || false
}

@test "report: the reason is the measurement and the measurements are printed" {
    pose_manifest qwen3-coder 32k '{"schemaVersion":2}' >/dev/null
    pose_manifest deepseek-coder latest '{"schemaVersion":2}' >/dev/null
    export FAKE_TAGS='{"models":[{"name":"qwen3-coder:32k","size":12345,"digest":"sha256:aaaaaaaa","details":{"type":"llm"}},{"name":"deepseek-coder:latest","size":99999,"digest":"sha256:bbbbbbbb","details":{"type":"llm"}}]}'
    mkdir -p "$HOME/.config/devzone"
    cat >"$HOME/.config/devzone/ai-measures.json" <<'EOF'
{"qwen3-coder:32k":{"reussite":0.8,"tok_s":500,"date":"2026-11-19"},"deepseek-coder:latest":{"reussite":0.9,"tok_s":100,"date":"2026-11-19"}}
EOF
    run bash "$HC" rapport
    [ "$status" -eq 0 ]
    [[ "$output" == *"measurement reussite 0.9, tok_s 100"* ]] || false
    [[ "$output" == *"chosen model: deepseek-coder:latest (measurement)"* ]] || false
}

@test "agent: host model is the local model, after every online model" {
    # Module ai on: the local slot is the host model detected via /api/tags.
    printf 'ai=on\n' >"$DEVZONE_ROOT/.devzone.modules"
    export DEVZONE_AGENT_STATE="$BATS_TEST_TMPDIR/etat"
    export FAKE_ARGS="$BATS_TEST_TMPDIR/refs.log"
    : >"$FAKE_ARGS"
    mkdir -p "$DEVZONE_AGENT_STATE" "$DEVZONE_ROOT/workspace/projet"
    printf 'construis la feature\n' >"$DEVZONE_ROOT/workspace/consigne.txt"
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
    run bash "$DEVZONE" agent "$DEVZONE_ROOT/workspace/projet" "$DEVZONE_ROOT/workspace/consigne.txt"
    [ "$status" -eq 3 ]
    [ "$(tail -1 "$FAKE_ARGS")" = "devzone-host/qwen3-coder:32k" ]
    [ "$(grep -c '^opencode/' "$FAKE_ARGS")" -eq 2 ]
    [ "$(grep -c 'devzone-host/qwen3-coder:32k' "$FAKE_ARGS")" -eq 1 ]
}

# Fake opencode for the rotation tests: online models fail quietly (exit 1, no
# known cause); the host model (devzone-host/...) hits the quota. Every
# reference passed to -m is recorded in $FAKE_ARGS.
fake_opencode_rotation() {
    export DEVZONE_AGENT_STATE="$BATS_TEST_TMPDIR/etat"
    export FAKE_ARGS="$BATS_TEST_TMPDIR/refs.log"
    : >"$FAKE_ARGS"
    mkdir -p "$DEVZONE_AGENT_STATE" "$DEVZONE_ROOT/workspace/projet"
    printf 'construis la feature\n' >"$DEVZONE_ROOT/workspace/consigne.txt"
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

@test "agent: the host model is tried last, whatever .devzone.modules says" {
    unset DEVZONE_WORKSPACE
    printf 'ai=on\n' >"$DEVZONE_ROOT/.devzone.modules"
    fake_opencode_rotation
    run bash "$DEVZONE" agent "$DEVZONE_ROOT/workspace/projet" "$DEVZONE_ROOT/workspace/consigne.txt"
    [ "$status" -eq 3 ]
    [ "$(tail -1 "$FAKE_ARGS")" = "devzone-host/qwen3-coder:32k" ]
    [ "$(grep -c '^opencode/' "$FAKE_ARGS")" -eq 2 ]
    ! grep -q 'devzone-llm' "$FAKE_ARGS" || false
}

@test "agent: a host model name with slashes sets no stray file and keeps its exact reference" {
    unset DEVZONE_WORKSPACE
    printf 'ai=on\n' >"$DEVZONE_ROOT/.devzone.modules"
    # Fake Ollama: one model whose name has slashes and a colon (as pulled from Hugging Face).
    export FAKE_TAGS='{"models":[{"name":"hf.co/ggml-org/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-GGUF:Q4_0","size":1,"digest":"sha256:aaaaaaaa","details":{"type":"llm"}}]}'
    fake_opencode_rotation
    run bash "$DEVZONE" agent "$DEVZONE_ROOT/workspace/projet" "$DEVZONE_ROOT/workspace/consigne.txt"
    [ "$status" -eq 3 ]
    # The reference given to opencode keeps the exact model name
    [ "$(tail -1 "$FAKE_ARGS")" = "devzone-host/hf.co/ggml-org/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-GGUF:Q4_0" ]
    # The set-aside file has a slash-free internal name, nothing is created in a sub-folder
    [ -f "$DEVZONE_AGENT_STATE/ecart-hf.co_ggml-org_NVIDIA-Nemotron-3.5-Lightning-30B-A3B-GGUF_Q4_0" ]
    [ ! -e "$DEVZONE_AGENT_STATE/ecart-hf.co" ]
    [ -z "$(find "$DEVZONE_AGENT_STATE" -mindepth 1 -type d -name 'ecart-*')" ]
}
