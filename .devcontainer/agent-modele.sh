#!/usr/bin/env bash
# Models asked with devzone agent --modele (#420): list check, attempt order
# (requested models first, then the usual rotation) and the shared rank rule.
# Library sourced by agent.sh: no command is launched here.

# Journal and refusal texts (French), printf formats.
# shellcheck source=SCRIPTDIR/agent-modele.messages disable=SC1091
. "$ICI/agent-modele.messages"

# Option --modele as typed (comma-separated list), empty when absent.
MODELE_LISTE=""
# Requested models, in order, checked by modeles_charger.
MODELES_DEMANDES=()
# Attempt order of the session (internal names), set by modele_ordre.
ORDRE=()

# Refuses a name missing from the free models: nothing is launched (code 2).
refuse_modele() {
    # shellcheck disable=SC2059 # the format comes from agent-modele.messages
    printf "$MSG_INCONNU\n" "$1" >&2
    printf '  %s\n' "${FREE_MODELS[@]}" >&2
    exit 2
}

# Loads the free models, checks the --modele list and writes its header to the
# journal $1: the last header tells devzone agent etat what was asked.
modeles_charger() {
    local journal="$1" m nom
    FREE_MODELS=()
    while IFS= read -r m; do
        if [ -n "$m" ]; then FREE_MODELS+=("$m"); fi
    done < <(liste_modeles)
    [ "${#FREE_MODELS[@]}" -gt 0 ] || refuse "$MSG_AUCUN_MODELE"
    MODELES_DEMANDES=()
    if [ -n "$MODELE_LISTE" ]; then
        while IFS= read -r nom; do
            case " ${FREE_MODELS[*]} " in
                *" $nom "*) MODELES_DEMANDES+=("$nom") ;;
                *) refuse_modele "$nom" ;;
            esac
        done < <(printf '%s\n' "$MODELE_LISTE" | tr ',' '\n')
    fi
    echo "=== --modele : ${MODELE_LISTE:-aucun}" >>"$journal"
}

# True when model $1 was asked with --modele.
modele_demande_p() {
    case " ${MODELES_DEMANDES[*]:-} " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

# Journal line when requested model $1 starts; other models get no line.
modele_demande_choisi() {
    if modele_demande_p "$1"; then
        # shellcheck disable=SC2059 # the format comes from agent-modele.messages
        printf "$MSG_CHOISI\n" "$1" >>"$2"
    fi
}

# Journal line when requested model $1 is excluded for cause $2, written to the
# journal $3. Other models keep their own lines.
modele_demande_ecart() {
    if modele_demande_p "$1"; then
        # shellcheck disable=SC2059 # the format comes from agent-modele.messages
        printf "$MSG_ECARTE\n" "$1" "$2" >>"$3"
    fi
}

# Cause of the current exclusion of model $1: ecart-<model> gives it, muet-<model>
# has none and counts as muet.
modele_ecart_cause() {
    local f cause=""
    f="$AGENT_ETAT/ecart-$1"
    if [ ! -f "$f" ]; then f="$AGENT_ETAT/muet-$1"; fi
    if [ -f "$f" ]; then read -r _ cause _ <"$f" || true; fi
    echo "${cause:-muet}"
}

# Adds model $1 to ORDRE unless it is already there.
ordre_ajouter() {
    case " ${ORDRE[*]:-} " in
        *" $1 "*) ;;
        *) ORDRE+=("$1") ;;
    esac
}

# Attempt order of the session from rank $1: requested models in their order,
# then the usual rotation (online models, then the local one). Each model
# appears once, so the rotation never tries again a requested model.
modele_ordre() {
    local debut="$1" total i k
    ORDRE=()
    for ((k = 0; k < ${#MODELES_DEMANDES[@]}; k++)); do
        ordre_ajouter "${MODELES_DEMANDES[$k]}"
    done
    total="$(modeles_total)"
    for ((i = 0; i < total; i++)); do
        ordre_ajouter "$(modele_au_rang "$i" "$debut")"
    done
}

# True when the shared rank may advance: no requested model is available.
# A requested model that starts leaves the rank alone, so the rotation of the
# other sessions does not move.
modele_rang_avance() {
    local k
    for ((k = 0; k < ${#MODELES_DEMANDES[@]}; k++)); do
        if ! modele_ecarte "${MODELES_DEMANDES[$k]}"; then return 1; fi
    done
    return 0
}
