#!/usr/bin/env bats
# Chart charts/devzone-llm (#586): the chart alone, rendered by helm template.
# The expected values are written in this file. The helm-direct path
# (chart_install in .devcontainer/llm/llm.sh) passes the preset with --set.
# Skipped without helm.

setup() {
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CHART="$RACINE/charts/devzone-llm"
    command -v helm >/dev/null 2>&1 || skip "helm missing"
}

# Chart rendered in namespace team; extra arguments go to helm template
render() {
    helm template llm "$CHART" --namespace team "$@"
}

@test "chart devzone-llm: helm lint" {
    run helm lint "$CHART"
    [ "$status" -eq 0 ]
}

@test "chart devzone-llm: default values render a Deployment, a Service and a PVC, no Secret" {
    run render
    [ "$status" -eq 0 ]
    [ "$(grep -c '^kind: ' <<<"$output")" -eq 3 ]
    [[ "$output" == *"kind: Deployment"* ]] || false
    [[ "$output" == *"kind: Service"* ]] || false
    [[ "$output" == *"kind: PersistentVolumeClaim"* ]] || false
    [[ "$output" != *"kind: Secret"* ]] || false
}

@test "chart devzone-llm: default Deployment runs the pinned llama.cpp server with the 7B model" {
    run render --show-only templates/deployment.yaml
    [ "$status" -eq 0 ]
    [[ "$output" == *"image: ghcr.io/ggml-org/llama.cpp:server-b12407"* ]] || false
    [[ "$output" == *"replicas: 1"* ]] || false
    [[ "$output" == *"- /models/qwen2.5-coder-7b-instruct-q4_k_m.gguf"* ]] || false
    [[ "$output" == *'- "32768"'* ]] || false
    [[ "$output" == *"--cache-type-k"* ]] || false
    [[ "$output" == *"--cache-type-v"* ]] || false
    [ "$(grep -c -- '- "q8_0"' <<<"$output")" -eq 2 ]
    [[ "$output" == *"--flash-attn"* ]] || false
    [[ "$output" == *'- "on"'* ]] || false
    [[ "$output" == *'- name: THREADS'* ]] || false
    [[ "$output" == *'value: "auto"'* ]] || false
    [[ "$output" == *'value: "8"'* ]] || false
    [[ "$output" == *'t="$(nproc)"'* ]] || false
    [[ "$output" == *'exec /app/llama-server "$@" -t "$t" --threads-batch "$t"'* ]] || false
    [[ "$output" == *'cpu: 2'* ]] || false
    [[ "$output" != *"cpu: 500m"* ]] || false
    [[ "$output" == *"--host"* ]] || false
    [[ "$output" == *"0.0.0.0"* ]] || false
    [[ "$output" == *"resolve/13fb94bfda8c8cf22497dc57b78f391a9acb426a/qwen2.5-coder-7b-instruct-q4_k_m.gguf"* ]] || false
    [[ "$output" == *"509287f78cb4d4cf6b3843734733b914b2c158e43e22a7f4bf5e963800894d3c"* ]] || false
    [[ "$output" == *"memory: 6Gi"* ]] || false
    [[ "$output" == *"memory: 7Gi"* ]] || false
}

@test "chart devzone-llm: one llamaBuild value gives the server image tag" {
    run render --set llamaBuild=b99999 --show-only templates/deployment.yaml
    [ "$status" -eq 0 ]
    [[ "$output" == *"image: ghcr.io/ggml-org/llama.cpp:server-b99999"* ]] || false
    [[ "$output" != *"b12407"* ]] || false
}

@test "chart devzone-llm: a numeric threads value and maxThreads are passed as is, CPU is a request only" {
    run render --set threads=6 --set maxThreads=12 --set resources.requests.cpu=3 --show-only templates/deployment.yaml
    [ "$status" -eq 0 ]
    [[ "$output" == *'value: "6"'* ]] || false
    [[ "$output" == *'value: "12"'* ]] || false
    [[ "$output" == *"cpu: 3"* ]] || false
    [ "$(grep -c 'cpu:' <<<"$output")" -eq 1 ]
}

@test "chart devzone-llm: readiness probe on GET /health, init container downloads only when missing and checks the sha256" {
    run render --show-only templates/deployment.yaml
    [ "$status" -eq 0 ]
    [[ "$output" == *"readinessProbe:"* ]] || false
    [[ "$output" == *"path: /health"* ]] || false
    [[ "$output" == *"initContainers:"* ]] || false
    [[ "$output" == *'if [ ! -f "$f" ]; then'* ]] || false
    [[ "$output" == *"curl -fL"* ]] || false
    [[ "$output" == *"sha256sum -c"* ]] || false
    [[ "$output" == *'rm -f "$f"'* ]] || false
    [[ "$output" == *"exit 1"* ]] || false
}

@test "chart devzone-llm: Service llm on 8080 and PVC llm-models of 8Gi kept at uninstall" {
    run render --show-only templates/service.yaml
    [ "$status" -eq 0 ]
    [[ "$output" == *"name: llm"* ]] || false
    [[ "$output" == *"type: ClusterIP"* ]] || false
    [[ "$output" == *"port: 8080"* ]] || false

    run render --show-only templates/pvc.yaml
    [ "$status" -eq 0 ]
    [[ "$output" == *"name: llm-models"* ]] || false
    [[ "$output" == *"storage: 8Gi"* ]] || false
    [[ "$output" == *"helm.sh/resource-policy: keep"* ]] || false
    [[ "$output" == *"argocd.argoproj.io/sync-options: Delete=false"* ]] || false
}

@test "chart devzone-llm: the light preset (3B) comes from --set" {
    run render --set model.file=qwen2.5-coder-3b-instruct-q4_k_m.gguf \
        --set model.sha256=724fb256bec1ff062b2f65e4569e871ad2e95ab2a3989723d1769c54294730b7 \
        --set memory=3Gi --set resources.limits.memory=4Gi --set contextSize=16384 --show-only templates/deployment.yaml
    [ "$status" -eq 0 ]
    [[ "$output" == *"- /models/qwen2.5-coder-3b-instruct-q4_k_m.gguf"* ]] || false
    [[ "$output" == *"memory: 3Gi"* ]] || false
    [[ "$output" == *"memory: 4Gi"* ]] || false
    [[ "$output" == *'- "16384"'* ]] || false
    [[ "$output" != *"memory: 7Gi"* ]] || false
}

@test "chart devzone-llm: no namespace written in the chart, the release namespace is used" {
    run render
    [ "$status" -eq 0 ]
    [ "$(grep -c '^  namespace: team$' <<<"$output")" -eq 3 ]
    [[ "$output" != *"namespace: devzone"* ]] || false
}

@test "chart devzone-llm: the bench Job is not rendered by default" {
    run render --show-only templates/bench-job.yaml
    [ "$status" -ne 0 ] || [[ "$output" != *"kind: Job"* ]]
    run render
    [[ "$output" != *"llama-bench"* ]] || false
    [[ "$output" != *"full-"* ]] || false
}

@test "chart devzone-llm: bench.enabled renders a Job on the full image of the same build, models read-only, node of the server" {
    run render --set bench.enabled=true --show-only templates/bench-job.yaml
    [ "$status" -eq 0 ]
    [[ "$output" == *"kind: Job"* ]] || false
    [[ "$output" == *"image: ghcr.io/ggml-org/llama.cpp:full-b12407"* ]] || false
    [[ "$output" == *"- /app/llama-bench"* ]] || false
    [[ "$output" == *"- /models/qwen2.5-coder-7b-instruct-q4_k_m.gguf"* ]] || false
    [[ "$output" == *'- "512"'* ]] || false
    [[ "$output" == *'- "64"'* ]] || false
    [[ "$output" == *'- "4,8"'* ]] || false
    [[ "$output" == *"- json"* ]] || false
    [[ "$output" == *"readOnly: true"* ]] || false
    [ "$(grep -c 'readOnly: true' <<<"$output")" -eq 2 ]
    [[ "$output" == *"claimName: llm-models"* ]] || false
    [[ "$output" == *"podAffinity:"* ]] || false
    [[ "$output" == *"topologyKey: kubernetes.io/hostname"* ]] || false
    [[ "$output" == *"app: llm"$'\n'* ]] || false
    [[ "$output" == *"ttlSecondsAfterFinished: 600"* ]] || false
    [[ "$output" == *"restartPolicy: Never"* ]] || false
    [[ "$output" == *"namespace: team"* ]] || false
}

@test "chart devzone-llm: bench values (prompt, gen, threads, build) are overridable" {
    run render --set bench.enabled=true --set bench.prompt=256 --set bench.gen=32 \
        --set bench.threads=2 --set llamaBuild=b99999 --show-only templates/bench-job.yaml
    [ "$status" -eq 0 ]
    [[ "$output" == *'- "256"'* ]] || false
    [[ "$output" == *'- "32"'* ]] || false
    [[ "$output" == *'- "2"'* ]] || false
    [[ "$output" == *"llama.cpp:full-b99999"* ]] || false
}
