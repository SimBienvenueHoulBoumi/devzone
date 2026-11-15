#!/usr/bin/env bats
# Module llm (#586): install through helm direct, preset, ingress policy,
# status, uninstall (volume kept), delete-data. Fake kubectl, kind, helm and
# nohup in the PATH: no cluster touched, no model downloaded. kubectl keeps its
# state in files of $BATS_TEST_TMPDIR and logs its arguments (kubectl.log) and
# what it reads on stdin (apply.log).

setup() {
    load commun
    load commun-helm
    kind_vide
    kube_isole
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    LLM="$BATS_TEST_DIRNAME/../../.devcontainer/llm/llm.sh"
    export HOME="$BATS_TEST_TMPDIR/home"
    export DEVZONE_RACINE="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_ETAT="$BATS_TEST_TMPDIR/modules"
    export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
    export KIND_CLUSTERS="$BATS_TEST_TMPDIR/clusters"
    export LLM_ATTENTE=120
    mkdir -p "$HOME" "$DEVZONE_RACINE/workspace" "$BATS_TEST_TMPDIR/bin"
    : >"$KIND_CLUSTERS"
    : >"$DEVZONE_KUBE_HOTE"

    cat >"$BATS_TEST_TMPDIR/bin/kind" <<'KIND'
#!/usr/bin/env bash
echo "kind $*" >>"$BATS_TEST_TMPDIR/kind.log"
case "$1 $2" in
    "get clusters") cat "$KIND_CLUSTERS" ;;
    "create cluster") echo "${4:-}" >>"$KIND_CLUSTERS" ;;
esac
KIND
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"$BATS_TEST_TMPDIR/kubectl.log"
T="$BATS_TEST_TMPDIR"
case "$*" in
    *"config get-contexts -o name"*) echo "docker-desktop" ;;
    *"config view"*)
        if [[ "$*" == *'.cluster.server'* ]]; then echo "https://127.0.0.1:6443"; else echo docker-desktop; fi ;;
    *"get --raw /readyz"*) ;;
    *"get namespace devzone-llm"*) [ -f "$T/ns" ]; exit $? ;;
    *"get namespaces -l"*) ;;
    *"create namespace"*) printf 'kind: Namespace\nmetadata:\n  name: devzone-llm\n' ;;
    *"apply -f -"*) cat >>"$T/apply.log"; touch "$T/ns" ;;
    *"get job llm-bench"*) echo "${BENCH_STATUS:-1/}" ;;
    *"logs job/llm-bench"*) cat "$T/bench.out" 2>/dev/null ;;
    *"rollout status"*) [ -z "${FAUX_PAS_PRET:-}" ]; exit $? ;;
    *"readyReplicas"*) echo 1 ;;
    *"limits.memory"*) echo 7Gi ;;
    *"delete namespace devzone-llm"*) rm -f "$T/ns" ;;
    *"port-forward"*) exec sleep 300 ;;
esac
exit 0
KUBE
    cat >"$BATS_TEST_TMPDIR/bin/nohup" <<'NOHUP'
#!/usr/bin/env bash
echo "nohup $*" >>"$BATS_TEST_TMPDIR/nohup.log"
exec sleep 300
NOHUP
    chmod +x "$BATS_TEST_TMPDIR"/bin/*
    helm_fake_install
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

teardown() {
    bash "$LLM" relay-stop >/dev/null 2>&1 || true
}

@test "llm: known module, disabled by default" {
    run bash "$DEVZONE"
    [[ "$output" == *"○ module llm"*"devzone enable llm"* ]] || false
}

@test "enable llm: namespace isolated, ingress from devzone-workspace, helm release with the 7B model, relay" {
    run bash "$DEVZONE" enable llm --context docker-desktop </dev/null
    [ "$status" -eq 0 ]
    grep -qx 'llm=on' "$DEVZONE_ETAT"
    grep -qx 'cluster=docker-desktop' "$DEVZONE_ETAT"
    grep -q 'name: devzone-meme-namespace' "$BATS_TEST_TMPDIR/apply.log"
    grep -q 'name: devzone-llm-workspace' "$BATS_TEST_TMPDIR/apply.log"
    grep -q 'kubernetes.io/metadata.name: devzone-workspace' "$BATS_TEST_TMPDIR/apply.log"
    grep -q 'image: ghcr.io/ggml-org/llama.cpp:server-b' "$BATS_TEST_TMPDIR/apply.log"
    grep -q 'qwen2.5-coder-7b-instruct-q4_k_m.gguf' "$BATS_TEST_TMPDIR/apply.log"
    grep -q 'storage: 8Gi' "$BATS_TEST_TMPDIR/apply.log"
    grep -q 'helm --kube-context devzone upgrade --install llm .*charts/devzone-llm -n devzone-llm' "$BATS_TEST_TMPDIR/helm.log"
    grep -q 'kubectl --context devzone -n devzone-llm rollout status deployment/llm' "$BATS_TEST_TMPDIR/kubectl.log"
    for i in $(seq 50); do grep -q 'svc/llm 8089:8080$' "$BATS_TEST_TMPDIR/nohup.log" 2>/dev/null && break; sleep 0.1; done
    grep -q 'devzone-llm svc/llm 8089:8080$' "$BATS_TEST_TMPDIR/nohup.log"
    [[ "$output" == *"http://llm.devzone-llm.svc.cluster.local:8080/v1"* ]] || false
    [ ! -f "$DEVZONE_ETAT-echec-llm" ]
    [ "$(jq -r '.provider["devzone-llm"].options.baseURL' "$HOME/.config/opencode/config.json")" = "http://127.0.0.1:8089/v1" ]
}

@test "enable llm --preset light: the 3B model, 3Gi request and 4Gi limit" {
    run bash "$DEVZONE" enable llm --context docker-desktop --preset light </dev/null
    [ "$status" -eq 0 ]
    grep -q 'qwen2.5-coder-3b-instruct-q4_k_m.gguf' "$BATS_TEST_TMPDIR/apply.log"
    grep -q 'memory: 4Gi' "$BATS_TEST_TMPDIR/apply.log"
    grep -q 'model.sha256=724fb256' "$BATS_TEST_TMPDIR/helm.log"
    grep -q 'contextSize=16384' "$BATS_TEST_TMPDIR/helm.log"
    [ "$(cat "$DEVZONE_RACINE/workspace/.llm/preset")" = light ]
}

@test "enable llm: unknown preset or argument refused (code 2), module off, nothing installed" {
    run bash "$DEVZONE" enable llm --context docker-desktop --preset huge </dev/null
    [ "$status" -ne 0 ]
    grep -qx 'llm=off' "$DEVZONE_ETAT"
    [ ! -f "$BATS_TEST_TMPDIR/helm.log" ] || ! grep -q 'upgrade' "$BATS_TEST_TMPDIR/helm.log"
    run bash "$DEVZONE" enable llm --oops </dev/null
    [ "$status" -ne 0 ]
    grep -qx 'llm=off' "$DEVZONE_ETAT"
}

@test "enable llm: model not ready after the wait, failure marker, module off" {
    FAUX_PAS_PRET=1 LLM_ATTENTE=60 run bash "$DEVZONE" enable llm --context docker-desktop </dev/null
    [ "$status" -ne 0 ]
    [[ "$output" == *"not ready after 60s"* ]] || false
    [ -f "$DEVZONE_ETAT-echec-llm" ]
    grep -qx 'llm=off' "$DEVZONE_ETAT"
}

@test "status: disabled, then ready with the model and the memory limit" {
    run bash "$LLM" status
    [ "$output" = disabled ]
    run bash "$DEVZONE" enable llm --context docker-desktop </dev/null
    [ "$status" -eq 0 ]
    run bash "$LLM" status
    [[ "$output" == "ready on docker-desktop: qwen2.5-coder-7b-instruct-q4_k_m.gguf, memory limit 7Gi, reachable 127.0.0.1:8089" ]] || false
}

@test "devzone status: the llm line shows the model and whether it is reachable, in text and in JSON" {
    bash "$DEVZONE" enable llm --context docker-desktop </dev/null
    run bash "$DEVZONE" status
    [[ "$output" == *"✔ module llm"*"ready on docker-desktop: qwen2.5-coder-7b-instruct-q4_k_m.gguf"*"reachable 127.0.0.1:8089"* ]] || false
    run bash "$DEVZONE" status --json
    [[ "$(printf '%s\n' "$output" | jq -r '.modules[] | select(.nom=="llm") | .etat')" == "ready on docker-desktop: qwen2.5-coder"* ]] || false
}

@test "enable llm twice: already active, nothing to do" {
    bash "$DEVZONE" enable llm --context docker-desktop </dev/null
    : >"$BATS_TEST_TMPDIR/helm.log"
    run bash "$DEVZONE" enable llm </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"llm already active"* ]] || false
    ! grep -q upgrade "$BATS_TEST_TMPDIR/helm.log" || false
}

@test "disable llm: release uninstalled, volume and namespace kept" {
    bash "$DEVZONE" enable llm --context docker-desktop </dev/null
    run bash "$DEVZONE" disable llm </dev/null
    [ "$status" -eq 0 ]
    grep -q 'helm --kube-context devzone uninstall llm -n devzone-llm' "$BATS_TEST_TMPDIR/helm.log"
    ! grep -q 'delete namespace' "$BATS_TEST_TMPDIR/kubectl.log" || false
    [[ "$output" == *"volume llm-models kept"* ]] || false
    grep -qx 'llm=off' "$DEVZONE_ETAT"
    [ ! -e "$HOME/.config/opencode/config.json" ]
}

@test "delete-data: without --yes and without a terminal, refused; with --yes the namespace goes" {
    bash "$DEVZONE" enable llm --context docker-desktop </dev/null
    run bash "$LLM" delete-data </dev/null
    [ "$status" -eq 2 ]
    ! grep -q 'delete namespace' "$BATS_TEST_TMPDIR/kubectl.log" || false
    run bash "$LLM" delete-data --yes
    [ "$status" -eq 0 ]
    grep -q 'delete namespace devzone-llm' "$BATS_TEST_TMPDIR/kubectl.log"
}

@test "llm.sh: unknown subcommand prints the usage" {
    run bash "$LLM" bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"devzone llm"* ]] || false
}

@test "devzone llm status goes through llm.sh" {
    run bash "$DEVZONE" llm status
    [ "$output" = disabled ]
}

# Output of a llama-bench Job: loading noise on stderr, then the JSON array
# (threads, prompt tok/s, generation tok/s)
bench_logs() {
    {
        echo "load_backend: loaded CPU backend"
        echo "["
        local first=1 row
        for row in "$@"; do
            IFS=: read -r t pp tg <<<"$row"
            [ "$first" = 1 ] || echo ","
            first=0
            printf '{"n_threads": %s, "n_prompt": 512, "n_gen": 0, "avg_ts": %s},\n' "$t" "$pp"
            printf '{"n_threads": %s, "n_prompt": 0, "n_gen": 64, "avg_ts": %s}\n' "$t" "$tg"
        done
        echo "]"
    } >"$BATS_TEST_TMPDIR/bench.out"
}

@test "llm bench: Job rendered on the full image, applied, table and recommendation, Job deleted" {
    bash "$DEVZONE" enable llm --context docker-desktop </dev/null
    : >"$BATS_TEST_TMPDIR/apply.log"
    bench_logs 4:60.5:9.2 8:90.1:11.4
    LLM_BENCH_POLL=0 run bash "$LLM" bench
    [ "$status" -eq 0 ]
    grep -q 'image: ghcr.io/ggml-org/llama.cpp:full-b' "$BATS_TEST_TMPDIR/apply.log"
    grep -q 'kind: Job' "$BATS_TEST_TMPDIR/apply.log"
    grep -q 'readOnly: true' "$BATS_TEST_TMPDIR/apply.log"
    grep -q 'qwen2.5-coder-7b-instruct-q4_k_m.gguf' "$BATS_TEST_TMPDIR/apply.log"
    [[ "$output" == *"threads"*"prompt (tok/s)"*"generation (tok/s)"* ]] || false
    [[ "$output" == *"4 "*"60.5"*"9.2"* ]] || false
    [[ "$output" == *"8 "*"90.1"*"11.4"* ]] || false
    [[ "$output" == *"Recommended: threads=8"* ]] || false
    [[ "$output" == *"Fast enough for opencode"* ]] || false
    grep -q 'delete job llm-bench' "$BATS_TEST_TMPDIR/kubectl.log"
    ! grep -q 'upgrade llm' "$BATS_TEST_TMPDIR/helm.log" || false
}

@test "llm bench: too slow for opencode (generation under 8 tok/s), thresholds from the environment" {
    bash "$DEVZONE" enable llm --context docker-desktop </dev/null
    bench_logs 4:60:3.1 8:70:4.2
    LLM_BENCH_POLL=0 run bash "$LLM" bench
    [ "$status" -eq 0 ]
    [[ "$output" == *"Recommended: threads=8"* ]] || false
    [[ "$output" == *"Too slow for opencode"* ]] || false
    [[ "$output" == *"devzone enable llm --preset light"* ]] || false
    LLM_BENCH_MIN_TG=4 LLM_BENCH_POLL=0 run bash "$LLM" bench
    [[ "$output" == *"Fast enough for opencode"* ]] || false
}

@test "llm bench: the smaller thread count wins a tie" {
    bash "$DEVZONE" enable llm --context docker-desktop </dev/null
    bench_logs 8:90:10 4:80:10
    LLM_BENCH_POLL=0 run bash "$LLM" bench
    [[ "$output" == *"Recommended: threads=4"* ]] || false
}

@test "llm bench --apply: helm upgrade of the release with threads=<best>, values kept" {
    bash "$DEVZONE" enable llm --context docker-desktop </dev/null
    bench_logs 4:60:9 8:90:11
    LLM_BENCH_POLL=0 run bash "$LLM" bench --apply --threads 4,8 --prompt 256 --gen 32
    [ "$status" -eq 0 ]
    grep -qF 'bench.threads=4\,8' "$BATS_TEST_TMPDIR/helm.log"
    grep -qF -- '- "4,8"' "$BATS_TEST_TMPDIR/apply.log"
    grep -q 'bench.prompt=256' "$BATS_TEST_TMPDIR/helm.log"
    grep -q 'bench.gen=32' "$BATS_TEST_TMPDIR/helm.log"
    grep -q 'upgrade llm .*charts/devzone-llm -n devzone-llm --reset-then-reuse-values --set threads=8' "$BATS_TEST_TMPDIR/helm.log"
    [[ "$output" == *"threads=8 applied"* ]] || false
}

@test "llm bench: Job failed, error shown and Job deleted; module off or bad argument refused" {
    bash "$DEVZONE" enable llm --context docker-desktop </dev/null
    echo "boom" >"$BATS_TEST_TMPDIR/bench.out"
    BENCH_STATUS="/1" LLM_BENCH_POLL=0 run bash "$LLM" bench
    [ "$status" -ne 0 ]
    [[ "$output" == *"bench Job failed or timed out"* ]] || false
    grep -q 'delete job llm-bench' "$BATS_TEST_TMPDIR/kubectl.log"
    run bash "$LLM" bench --oops
    [ "$status" -eq 2 ]
    run bash "$LLM" bench --threads
    [ "$status" -eq 2 ]
}

@test "llm bench: timeout of the Job, Job deleted; not enabled refused" {
    bash "$DEVZONE" enable llm --context docker-desktop </dev/null
    BENCH_STATUS="/" LLM_BENCH_ATTENTE=2 LLM_BENCH_POLL=1 run bash "$LLM" bench
    [ "$status" -ne 0 ]
    [[ "$output" == *"failed or timed out"* ]] || false
    grep -q 'delete job llm-bench' "$BATS_TEST_TMPDIR/kubectl.log"
    rm -f "$BATS_TEST_TMPDIR/ns"
    run bash "$LLM" bench
    [ "$status" -eq 2 ]
    [[ "$output" == *"not enabled"* ]] || false
}

@test "devzone llm bench goes through llm.sh" {
    run bash "$DEVZONE" llm bench
    [ "$status" -eq 2 ]
    [[ "$output" == *"not enabled"* ]] || false
}

@test "llm bench: too slow with the light preset already installed proposes nothing more" {
    bash "$DEVZONE" enable llm --context docker-desktop --preset light </dev/null
    bench_logs 4:60:3.1
    LLM_BENCH_POLL=0 run bash "$LLM" bench
    [[ "$output" == *"Too slow for opencode"* ]] || false
    [[ "$output" != *"--preset light"* ]] || false
    grep -q 'model.file=qwen2.5-coder-3b' "$BATS_TEST_TMPDIR/helm.log"
}
