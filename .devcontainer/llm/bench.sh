#!/usr/bin/env bash
# devzone llm bench (#593), sourced by llm.sh (uses its NS, k, preset_read
# and refuse): llama-bench of the model in a Kubernetes Job of the
# namespace devzone-llm (image full-<llamaBuild> of the chart, same build as the
# server, pulled only here), then a table, a threads recommendation and whether
# the speed is enough for opencode.
#   devzone llm bench [--apply] [--threads LIST] [--prompt N] [--gen N]
# --apply sets threads=<best> on the release llm (helm upgrade, values kept).
# Env: LLM_BENCH_ATTENTE (seconds, 1800: wait limit and activeDeadlineSeconds of
# the Job, which stops by itself if the call is interrupted), LLM_BENCH_POLL
# (seconds, 5), LLM_BENCH_SIGNE (seconds, 30: a progress line at least this
# often, so that the connection of kubectl exec is not cut), LLM_BENCH_MIN_PP (50 tok/s, prompt reading), LLM_BENCH_MIN_TG (8 tok/s,
# generation). The Job is deleted at the end, even on failure. bash 3.2 (macOS).

BENCH_JOB=llm-bench

# Server present, read with the rights of the namespace (the account of the pod
# cannot read a namespace, a cluster resource: installed would fail for it)
bench_present() { k get deployment llm >/dev/null 2>&1; }

# Job deleted (no error when it is already gone)
bench_cleanup() { k delete job "$BENCH_JOB" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }

# Phase of the Job for the progress line, read from the state of the container
# (not the phase of the pod): waiting (ContainerCreating, PullImage...) is
# pulling, running or terminated is measuring. The caller keeps the phase
# monotone: once measuring, it never goes back to pulling.
bench_phase() {
    local etat
    etat="$(k get pods -l app=llm-bench -o jsonpath='{.items[0].status.containerStatuses[0].state.running.startedAt}|{.items[0].status.containerStatuses[0].state.terminated.reason}' 2>/dev/null || true)"
    case "$etat" in
        "|" | "") echo "pulling the image" ;;
        *) echo "measuring" ;;
    esac
}

# Waits for the Job: 0 done, 1 failed, 2 timeout. Writes a line (phase,
# elapsed time) at least every LLM_BENCH_SIGNE seconds
bench_wait() {
    local waited=0 poll="${LLM_BENCH_POLL:-5}" limit="${LLM_BENCH_ATTENTE:-1800}" beat="${LLM_BENCH_SIGNE:-30}" st last="" phase="pulling the image"
    while [ "$waited" -lt "$limit" ]; do
        st="$(k get job "$BENCH_JOB" -o jsonpath='{.status.succeeded}/{.status.failed}' 2>/dev/null || true)"
        case "$st" in
            1/*) return 0 ;;
            */[1-9]*) return 1 ;;
        esac
        if [ -z "$last" ] || [ $((waited - last)) -ge "$beat" ]; then
            # Monotone: once measuring, the phase is not read again
            [ "$phase" = measuring ] || phase="$(bench_phase)"
            echo "  … $phase, ${waited}s elapsed"
            last=$waited
        fi
        sleep "$poll"
        waited=$((waited + poll))
    done
    return 2
}

# Table "threads pp tg" (tok/s) from the JSON of llama-bench (logs of the Job:
# the array is the part between the line "[" and the line "]")
bench_rows() {
    sed -n '/^\[/,/^\]/p' | jq -r '
        group_by(.n_threads)[]
        | [.[0].n_threads,
           (map(select(.n_prompt > 0 and .n_gen == 0)) | .[0].avg_ts // 0),
           (map(select(.n_gen > 0 and .n_prompt == 0)) | .[0].avg_ts // 0)]
        | @tsv' 2>/dev/null
}

# Best row (generation speed, then fewer threads) and the verdict, from the
# rows on stdin: prints the table then "best=<n>" and "ok=0|1"
bench_report() {
    awk -v mpp="${LLM_BENCH_MIN_PP:-50}" -v mtg="${LLM_BENCH_MIN_TG:-8}" '
        { t[NR] = $1; pp[NR] = $2; tg[NR] = $3 }
        END {
            printf "%-8s %-22s %s\n", "threads", "prompt (tok/s)", "generation (tok/s)"
            b = 0
            for (i = 1; i <= NR; i++) {
                printf "%-8s %-22.1f %.1f\n", t[i], pp[i], tg[i]
                if (b == 0 || tg[i] > tg[b] || (tg[i] == tg[b] && t[i] + 0 < t[b] + 0)) b = i
            }
            if (b == 0) exit 1
            print "best=" t[b]
            print "ok=" ((pp[b] >= mpp && tg[b] >= mtg) ? 1 : 0)
        }'
}

bench_apply() {
    helm --kube-context devzone upgrade llm "$CHART_CODE/charts/devzone-llm" -n "$NS" --reset-then-reuse-values --set "threads=$1" >/dev/null || return 1
    wait_ready
}

bench() {
    local apply="" want="" arg threads="" prompt="" gen="" sets logs rows report best ok
    local -a args
    for arg in "$@"; do
        if [ -n "$want" ]; then
            case "$want" in
                threads) threads="$arg" ;;
                prompt) prompt="$arg" ;;
                gen) gen="$arg" ;;
            esac
            want=""
            continue
        fi
        case "$arg" in
            --apply) apply=1 ;;
            --threads | --prompt | --gen) want="${arg#--}" ;;
            *) refuse "unknown argument: $arg (devzone llm bench [--apply] [--threads 4,8] [--prompt 128] [--gen 32])" ;;
        esac
    done
    [ -z "$want" ] || refuse "--$want needs a value"
    # In the pod only devzone workspace services (DEVZONE_SERVICES_ADMIN) has rights on the namespace
    if [ "${DEVZONE_WORKSPACE:-}" = kubernetes ] && [ -z "${DEVZONE_SERVICES_ADMIN:-}" ]; then
        echo "devzone: llm bench runs from your computer: devzone workspace services bench llm" >&2
        exit 2
    fi
    bench_present || refuse "bench: the module is not enabled (devzone enable llm)"
    sets="$(llm_preset_sets "$(preset_read)") bench.enabled=true"
    [ -z "$threads" ] || sets="$sets bench.threads=${threads//,/\\,}" # helm --set: a comma separates keys
    [ -z "$prompt" ] || sets="$sets bench.prompt=$prompt"
    [ -z "$gen" ] || sets="$sets bench.gen=$gen"
    sets="$sets bench.deadline=${LLM_BENCH_ATTENTE:-1800}"
    args=()
    for arg in $sets; do args+=(--set "$arg"); done
    trap bench_cleanup EXIT INT TERM
    bench_cleanup
    echo "▶ llama-bench in the namespace $NS (image full-<build>: larger than the server image, pulled on first use; the server keeps running, so the numbers are a bit low)…"
    helm template llm "$CHART_CODE/charts/devzone-llm" -n "$NS" "${args[@]}" --show-only templates/bench-job.yaml | k apply -f - >/dev/null || return 1
    bench_wait || {
        echo "devzone: llm: bench Job failed or timed out (LLM_BENCH_ATTENTE=${LLM_BENCH_ATTENTE:-1800}s): kubectl --context devzone -n $NS logs job/$BENCH_JOB" >&2
        k logs "job/$BENCH_JOB" --tail=5 >&2 2>/dev/null || true
        return 1
    }
    logs="$(k logs "job/$BENCH_JOB" 2>/dev/null || true)"
    rows="$(printf '%s\n' "$logs" | bench_rows)"
    [ -n "$rows" ] || { echo "devzone: llm: no llama-bench result in the logs of the Job" >&2; return 1; }
    report="$(printf '%s\n' "$rows" | bench_report)"
    printf '%s\n' "$report" | grep -v '^best=\|^ok='
    best="$(printf '%s\n' "$report" | sed -n 's/^best=//p')"
    ok="$(printf '%s\n' "$report" | sed -n 's/^ok=//p')"
    echo "▶ Recommended: threads=$best"
    if [ "$ok" = 1 ]; then
        echo "✔ Fast enough for opencode (prompt >= ${LLM_BENCH_MIN_PP:-50} tok/s, generation >= ${LLM_BENCH_MIN_TG:-8} tok/s)"
    else
        echo "⚠ Too slow for opencode (needs prompt >= ${LLM_BENCH_MIN_PP:-50} tok/s and generation >= ${LLM_BENCH_MIN_TG:-8} tok/s)"
        if [ "$(preset_read)" != light ]; then
            echo "  Lighter model (3B, context 16k, 2.1 GB download): devzone disable llm && devzone enable llm --preset light"
        fi
    fi
    if [ -n "$apply" ]; then
        bench_apply "$best" || return 1
        echo "✔ threads=$best applied to the release llm"
    else
        echo "  devzone llm bench --apply  sets threads=$best on the release"
    fi
}
