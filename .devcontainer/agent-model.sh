#!/usr/bin/env bash
# Models asked with devzone agent --model (#420): list check, attempt order
# (requested models first, then the usual rotation) and the shared rank rule.
# Library sourced by agent.sh: no command is launched here.

# Journal and refusal texts, printf formats.
# shellcheck source=SCRIPTDIR/agent-model.messages disable=SC1091
. "$ICI/agent-model.messages"

# Option --model as typed (comma-separated list), empty when absent.
MODEL_LIST=""
# Requested models, in order, checked by models_load.
MODELS_REQUESTED=()
# Attempt order of the session (internal names), set by model_order.
ORDER=()

# Refuses a name missing from the free models: nothing is launched (code 2).
refuse_model() {
    # shellcheck disable=SC2059 # the format comes from agent-model.messages
    printf "$MSG_UNKNOWN\n" "$1" >&2
    printf '  %s\n' "${FREE_MODELS[@]}" >&2
    exit 2
}

# Loads the free models, checks the --model list and writes its header to the
# journal $1: the last header tells devzone agent state what was asked.
models_load() {
    local journal="$1" m nom
    FREE_MODELS=()
    while IFS= read -r m; do
        if [ -n "$m" ]; then FREE_MODELS+=("$m"); fi
    done < <(list_models)
    [ "${#FREE_MODELS[@]}" -gt 0 ] || refuse "$MSG_NO_MODEL"
    MODELS_REQUESTED=()
    if [ -n "$MODEL_LIST" ]; then
        while IFS= read -r nom; do
            case " ${FREE_MODELS[*]} " in
                *" $nom "*) MODELS_REQUESTED+=("$nom") ;;
                *) refuse_model "$nom" ;;
            esac
        done < <(printf '%s\n' "$MODEL_LIST" | tr ',' '\n')
    fi
    echo "=== --model : ${MODEL_LIST:-none}" >>"$journal"
}

# True when model $1 was asked with --model.
model_requested_p() {
    case " ${MODELS_REQUESTED[*]:-} " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

# Journal line when requested model $1 starts; other models get no line.
model_requested_chosen() {
    if model_requested_p "$1"; then
        # shellcheck disable=SC2059 # the format comes from agent-model.messages
        printf "$MSG_CHOSEN\n" "$1" >>"$2"
    fi
}

# Journal line when requested model $1 is excluded for cause $2, written to the
# journal $3. Other models keep their own lines.
model_requested_excluded() {
    if model_requested_p "$1"; then
        # shellcheck disable=SC2059 # the format comes from agent-model.messages
        printf "$MSG_EXCLUDED\n" "$1" "$2" >>"$3"
    fi
}

# Cause of the current exclusion of model $1: ecart-<model> gives it, muet-<model>
# has none and counts as muet.
model_exclusion_cause() {
    local f cause=""
    f="$AGENT_STATE/ecart-$1"
    if [ ! -f "$f" ]; then f="$AGENT_STATE/muet-$1"; fi
    if [ -f "$f" ]; then read -r _ cause _ <"$f" || true; fi
    echo "${cause:-muet}"
}

# Adds model $1 to ORDER unless it is already there.
order_add() {
    case " ${ORDER[*]:-} " in
        *" $1 "*) ;;
        *) ORDER+=("$1") ;;
    esac
}

# Attempt order of the session from rank $1: requested models in their order,
# then the usual rotation (online models, then the local one). Each model
# appears once, so the rotation never tries again a requested model.
model_order() {
    local start="$1" total i k
    ORDER=()
    for ((k = 0; k < ${#MODELS_REQUESTED[@]}; k++)); do
        order_add "${MODELS_REQUESTED[$k]}"
    done
    total="$(models_total)"
    for ((i = 0; i < total; i++)); do
        order_add "$(model_at_rank "$i" "$start")"
    done
}

# True when the shared rank may advance: no requested model is available.
# A requested model that starts leaves the rank alone, so the rotation of the
# other sessions does not move.
model_rank_advance() {
    local k
    for ((k = 0; k < ${#MODELS_REQUESTED[@]}; k++)); do
        if ! model_excluded "${MODELS_REQUESTED[$k]}"; then return 1; fi
    done
    return 0
}
