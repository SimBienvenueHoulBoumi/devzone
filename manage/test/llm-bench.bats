#!/usr/bin/env bats
# devzone llm bench (#593): progress lines while the Job runs, deadline of the
# Job. Fake kubectl, kind and helm in the PATH: no cluster touched.

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
    *"get nodes -o jsonpath"*) printf '%s\n' "${FAUX_MEMOIRE_CLUSTER:-16777216Ki}" ;;
    *"get namespace devzone-llm"*) [ -f "$T/ns" ]; exit $? ;;
    *"get namespaces -l"*) ;;
    *"create namespace"*) printf 'kind: Namespace\nmetadata:\n  name: devzone-llm\n' ;;
    *"apply -f -"*) cat >>"$T/apply.log"; touch "$T/ns" ;;
    *"get job llm-bench"*)
        # still running for BENCH_RUNS polls, then done
        n=$(($(cat "$T/polls" 2>/dev/null || echo 0) + 1)); echo "$n" >"$T/polls"
        if [ "$n" -gt "${BENCH_RUNS:-0}" ]; then echo "1/"; else echo "/"; fi ;;
    *"get pods -l app=llm-bench"*)
        # one line of pods.seq per call (startedAt|terminated reason), the last one repeats
        n=$(($(cat "$T/pods.n" 2>/dev/null || echo 0) + 1)); echo "$n" >"$T/pods.n"
        line="$(sed -n "${n}p" "$T/pods.seq")"; [ -n "$line" ] || line="$(tail -n 1 "$T/pods.seq")"
        echo "$line" ;;
    *"logs job/llm-bench"*) cat "$T/bench.out" 2>/dev/null ;;
    *"rollout status"*) ;;
    *"readyReplicas"*) echo 1 ;;
    *"limits.memory"*) echo 7Gi ;;
    *"get deployment llm"*) [ -f "$T/ns" ]; exit $? ;;
esac
exit 0
KUBE
    cat >"$BATS_TEST_TMPDIR/bin/nohup" <<'NOHUP'
#!/usr/bin/env bash
exec sleep 300
NOHUP
    chmod +x "$BATS_TEST_TMPDIR"/bin/*
    printf '|\n' >"$BATS_TEST_TMPDIR/pods.seq"
    helm_fake_install
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    printf '[\n{"n_threads": 4, "n_prompt": 128, "n_gen": 0, "avg_ts": 60},\n{"n_threads": 4, "n_prompt": 0, "n_gen": 32, "avg_ts": 9}\n]\n' >"$BATS_TEST_TMPDIR/bench.out"
    bash "$DEVZONE" enable llm --context docker-desktop </dev/null
}

teardown() {
    bash "$LLM" relay-stop >/dev/null 2>&1 || true
}

@test "llm bench: a progress line at the start, then one per interval, with the phase and the elapsed time" {
    BENCH_RUNS=5 LLM_BENCH_POLL=1 LLM_BENCH_SIGNE=2 run bash "$LLM" bench
    [ "$status" -eq 0 ]
    [[ "$output" == *"… pulling the image, 0s elapsed"* ]] || false
    [[ "$output" == *"… pulling the image, 2s elapsed"* ]] || false
    [[ "$output" == *"… pulling the image, 4s elapsed"* ]] || false
    [[ "$output" != *"3s elapsed"* ]] || false
}

@test "llm bench: the progress line says measuring once the container runs" {
    printf '2026-11-15T10:00:00Z|\n' >"$BATS_TEST_TMPDIR/pods.seq"
    BENCH_RUNS=2 LLM_BENCH_POLL=1 LLM_BENCH_SIGNE=1 run bash "$LLM" bench
    [ "$status" -eq 0 ]
    [[ "$output" == *"… measuring, 1s elapsed"* ]] || false
    [[ "$output" != *"pulling the image"* ]] || false
}

@test "llm bench: the phase never goes back to pulling once measuring" {
    # ContainerCreating, then running, then waiting again (a stale or replaced pod)
    printf '|\n2026-11-15T10:00:00Z|\n|\n' >"$BATS_TEST_TMPDIR/pods.seq"
    BENCH_RUNS=6 LLM_BENCH_POLL=1 LLM_BENCH_SIGNE=1 run bash "$LLM" bench
    [ "$status" -eq 0 ]
    [[ "$output" == *"… pulling the image, 0s elapsed"* ]] || false
    [[ "$output" == *"… measuring, 1s elapsed"* ]] || false
    [[ "$output" == *"… measuring, 5s elapsed"* ]] || false
    [[ "$output" != *"pulling the image, 2s"* ]] || false
    [[ "$output" != *"pulling the image, 3s"* ]] || false
    [[ "$output" != *"pulling the image, 4s"* ]] || false
    [ "$(cat "$BATS_TEST_TMPDIR/pods.n")" -eq 2 ]
}

@test "llm bench: a terminated container counts as measuring" {
    printf '|Completed\n' >"$BATS_TEST_TMPDIR/pods.seq"
    BENCH_RUNS=2 LLM_BENCH_POLL=1 LLM_BENCH_SIGNE=1 run bash "$LLM" bench
    [ "$status" -eq 0 ]
    [[ "$output" == *"… measuring, 0s elapsed"* ]] || false
    [[ "$output" != *"pulling the image"* ]] || false
}

@test "llm bench: the Job is deleted after a timeout, progress included" {
    BENCH_RUNS=99 LLM_BENCH_ATTENTE=3 LLM_BENCH_POLL=1 LLM_BENCH_SIGNE=1 run bash "$LLM" bench
    [ "$status" -ne 0 ]
    [[ "$output" == *"… pulling the image, 2s elapsed"* ]] || false
    [[ "$output" == *"failed or timed out (LLM_BENCH_ATTENTE=3s)"* ]] || false
    grep -q 'delete job llm-bench' "$BATS_TEST_TMPDIR/kubectl.log"
}

@test "llm bench: the Job gets activeDeadlineSeconds 1800 by default, LLM_BENCH_ATTENTE overrides it" {
    LLM_BENCH_POLL=0 run bash "$LLM" bench
    [ "$status" -eq 0 ]
    grep -q 'activeDeadlineSeconds: 1800' "$BATS_TEST_TMPDIR/apply.log"
    LLM_BENCH_ATTENTE=600 LLM_BENCH_POLL=0 run bash "$LLM" bench
    [ "$status" -eq 0 ]
    grep -q 'activeDeadlineSeconds: 600' "$BATS_TEST_TMPDIR/apply.log"
}

@test "llm bench: too slow in the Docker container, the commands are devzone llm" {
    printf '[\n{"n_threads": 4, "n_prompt": 128, "n_gen": 0, "avg_ts": 60},\n{"n_threads": 4, "n_prompt": 0, "n_gen": 32, "avg_ts": 3}\n]\n' >"$BATS_TEST_TMPDIR/bench.out"
    LLM_BENCH_POLL=0 run bash "$LLM" bench
    [ "$status" -eq 0 ]
    [[ "$output" == *"⚠ Too slow for opencode"* ]] || false
    [[ "$output" == *"devzone disable llm && devzone enable llm --preset light"* ]] || false
    [[ "$output" == *"devzone llm bench --apply  sets threads=4 on the release"* ]] || false
    [[ "$output" != *"workspace services"* ]] || false
}

@test "llm bench: too slow in the Kubernetes workspace, the commands are devzone workspace services" {
    printf '[\n{"n_threads": 4, "n_prompt": 128, "n_gen": 0, "avg_ts": 60},\n{"n_threads": 4, "n_prompt": 0, "n_gen": 32, "avg_ts": 3}\n]\n' >"$BATS_TEST_TMPDIR/bench.out"
    DEVZONE_WORKSPACE=kubernetes DEVZONE_SERVICES_ADMIN=1 LLM_BENCH_POLL=0 run bash "$LLM" bench
    [ "$status" -eq 0 ]
    [[ "$output" == *"devzone workspace services disable llm && devzone workspace services enable llm --preset light"* ]] || false
    [[ "$output" == *"devzone workspace services bench llm --apply  sets threads=4 on the release"* ]] || false
    [[ "$output" != *"devzone llm bench --apply"* ]] || false
}
