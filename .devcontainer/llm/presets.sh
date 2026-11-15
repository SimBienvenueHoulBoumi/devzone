#!/usr/bin/env bash
# Presets of the local model (#586), sourced by llm.sh and argocd/services-hook.sh.
# The values are the ones documented in charts/devzone-llm/values.yaml: the
# Hugging Face URL is pinned to a commit (resolve/<commit>) and the sha256 is
# the one of the file, checked by the init container of the chart.
#   llm_preset_name <name>   canonical preset (default | light), 1 when unknown
#   llm_preset_sets <name>   helm parameters key=value, space separated
#   llm_preset_file <name>   file name of the model of the preset
# bash 3.2 (macOS).

LLM_HF_7B="https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/13fb94bfda8c8cf22497dc57b78f391a9acb426a"
LLM_HF_3B="https://huggingface.co/Qwen/Qwen2.5-Coder-3B-Instruct-GGUF/resolve/f74adce6aa16316c625447af059dbebe4983757c"

llm_preset_name() {
    case "${1:-}" in
        "" | default | qwen2.5-coder-7b-instruct-q4_k_m) echo default ;;
        light | qwen2.5-coder-3b-instruct-q4_k_m) echo light ;;
        *) return 1 ;;
    esac
}

llm_preset_file() {
    case "$(llm_preset_name "${1:-}")" in
        default) echo qwen2.5-coder-7b-instruct-q4_k_m.gguf ;;
        light) echo qwen2.5-coder-3b-instruct-q4_k_m.gguf ;;
    esac
}

llm_preset_sets() {
    local name file
    name="$(llm_preset_name "${1:-}")" || return 1
    file="$(llm_preset_file "$name")"
    case "$name" in
        default)
            printf 'model.url=%s/%s model.file=%s model.sha256=%s' "$LLM_HF_7B" "$file" "$file" \
                509287f78cb4d4cf6b3843734733b914b2c158e43e22a7f4bf5e963800894d3c
            ;;
        light)
            printf 'model.url=%s/%s model.file=%s model.sha256=%s memory=3Gi resources.limits.memory=4Gi' \
                "$LLM_HF_3B" "$file" "$file" 724fb256bec1ff062b2f65e4569e871ad2e95ab2a3989723d1769c54294730b7
            ;;
    esac
}
