#!/usr/bin/env bash
# shellcheck shell=bash
# devzone, working cluster: change, use.
# Sourced by .devcontainer/devzone (split of the 1 600 lines file, #722):
# functions only, shared variables are defined in devzone.

# Toutes les bases disparaissent : confirmation en terminal (sans terminal, la
# commande est explicite) ; un oui ou --yes marque SUPPRIMER_DONNEES, lu par
# appliquer_mysql pour lancer delete-data (#441). Les arguments passent
# par reject_renamed : --oui est refusé avant d'arriver ici, seul --yes passe (#695).
confirmer_suppression() {
    local app="$1" reponse arg
    SUPPRIMER_DONNEES=""
    [ "$(valeur "$app")" = on ] || return 0
    for arg in "${@:2}"; do
        case "$arg" in --yes) SUPPRIMER_DONNEES=1 ;; esac
    done
    [ -z "$SUPPRIMER_DONNEES" ] || return 0
    cluster_interactive || return 0
    # mysql : la question porte sur le namespace (volume et bases restent) ;
    # postgres : tout part, le refus annule ; gitlab : le secret Rails reste,
    # sa suppression n'a lieu que sur une désinstallation complète voulue
    if [ "$app" = mysql ]; then
        printf 'Désactiver mysql retire le serveur, le volume et les bases restent. Supprimer aussi le namespace devzone-mysql et ses volumes ? [o/N] ' >&2
    elif [ "$app" = gitlab ]; then
        printf 'Désactiver gitlab garde le secret Rails (sessions du navigateur valides à la réinstallation). Supprimer aussi le secret Rails ? [o/N] ' >&2
    else
        printf 'Désactiver %s supprime toutes ses bases. Continuer ? [o/N] ' "$app" >&2
    fi
    read -r reponse || reponse=""
    case "$reponse" in
        o | O | oui) SUPPRIMER_DONNEES=1; return 0 ;;
    esac
    # refus : mysql et gitlab désactivent quand même (données gardées), postgres annule
    case "$app" in
        mysql | gitlab) return 0 ;;
        *) echo "Abandon : rien n'a été supprimé."; return 1 ;;
    esac
}

# devzone cluster [CTX] [--yes] : affiche le cluster des services, ou les y
# déplace (désinstallés de l'ancien, installés sur le nouveau : données non
# migrées, d'où la confirmation)
changer_cluster() {
    local voulu="" oui="" confirmer="" attendre="" arg actuel nouveau reponse ctx_ancien ctx_new NS
    NS=devzone-postgres
    for arg in "$@"; do
        if [ -n "$attendre" ]; then
            confirmer="$arg"
            attendre=""
            continue
        fi
        case "$arg" in
            --yes) oui=1 ;;
            --confirm) attendre=1 ;;
            -*) echo "devzone : argument inconnu : $arg (devzone cluster [CTX] [--yes] [--confirm CTX])" >&2; return 2 ;;
            *) voulu="$arg" ;;
        esac
    done
    if [ -n "$attendre" ]; then
        echo "devzone : --confirm attend un contexte" >&2
        return 2
    fi
    actuel="$(cluster_saved)"
    if [ -z "$voulu" ]; then
        if [ -z "$actuel" ]; then
            echo "devzone : aucun cluster choisi (fixé à l'activation d'un module : devzone enable postgres)"
        elif cluster_is_dedicated "$actuel"; then
            echo "devzone : cluster $actuel (kind dédié, dans le conteneur)"
        else
            echo "devzone : cluster $actuel (cluster de l'hôte)"
        fi
        echo "  possibles : $(cluster_candidates | tr '\n' ' ')"
        return 0
    fi
    if [ -n "$confirmer" ]; then
        nouveau="$(cluster_choose "$voulu" --confirm "$confirmer")" || return 2
    else
        nouveau="$(cluster_choose "$voulu")" || return 2
    fi
    if [ "$nouveau" = "$actuel" ]; then
        echo "devzone : déjà sur $nouveau, rien à faire."
        return 0
    fi
    ctx_ancien="$actuel"
    ctx_new="$nouveau"
    if [ "$(valeur postgres)" = on ]; then
        if [ -z "$oui" ]; then
            if ! cluster_interactive; then
                echo "devzone : les bases postgres seront supprimées de $ctx_ancien (non migrées) : devzone cluster $ctx_new --yes" >&2
                return 1
            fi
            printf 'postgres sera réinstallé sur %s, ses bases supprimées de %s (non migrées). Continuer ? [o/N] ' "$ctx_new" "$ctx_ancien" >&2
            read -r reponse || reponse=""
            case "$reponse" in
                o | O | oui) ;;
                *) echo "Abandon : rien n'a changé."; return 0 ;;
            esac
        fi
        # Retire PostgreSQL de l'ancien cluster (contexte explicite) ;
        # namespace et RoleBinding par l'administrateur (#430)
        export KUBECONFIG="$HOME/.kube/config:$HOME/.kube/hote.config"
        account_remove "$ctx_ancien" "$NS" >/dev/null 2>&1 || true
        account_admin "$ctx_ancien" delete namespace "$NS" --wait=true >/dev/null 2>&1 || true
        cluster_release "$ctx_ancien"
        # Le nouveau cluster devient le contexte devzone
        cluster_save "$ctx_new"
        # Pose le contexte devzone sur le nouveau cluster (cluster + user :
        # commande importante, échec affiché et rendu #396)
        if ! devzone_context_set "$ctx_new"; then
            echo "devzone : impossible de poser le contexte devzone sur $ctx_new" >&2
            return 1
        fi
        # Installe PostgreSQL sur le nouveau cluster (via --context devzone qui pointe maintenant dessus)
        bash "$ICI/postgres/postgres.sh" install
    else
        cluster_save "$ctx_new"
        # Pose le contexte devzone sur le nouveau cluster (cluster + user :
        # commande importante, échec affiché et rendu #396)
        if ! devzone_context_set "$ctx_new"; then
            echo "devzone : impossible de poser le contexte devzone sur $ctx_new" >&2
            return 1
        fi
    fi
    echo "devzone : cluster des services : $ctx_new"
}

# Bascule le cluster de travail de l'utilisateur (#341). Ne touche jamais au
# cluster des services de devzone : aucun cluster_save, aucune ligne
# cluster= dans l'état.
utiliser() {
    local ctx="" confirmer="" namespace="" reponse arg courant
    while [ "$#" -gt 0 ]; do
        arg="$1"
        shift
        case "$arg" in
            -n | --namespace)
                if [ "$#" -eq 0 ]; then
                    echo "devzone : -n attend un namespace" >&2
                    return 2
                fi
                namespace="$1"
                shift
                ;;
            --namespace=*) namespace="${arg#*=}" ;;
            --confirm)
                if [ "$#" -eq 0 ]; then
                    echo "devzone : --confirm attend un contexte" >&2
                    return 2
                fi
                confirmer="$1"
                shift
                ;;
            --confirm=*) confirmer="${arg#*=}" ;;
            -*)
                echo "devzone : argument inconnu : $arg (devzone use CTX [-n NS] [--confirm CTX])" >&2
                return 2
                ;;
            *)
                if [ -n "$ctx" ]; then
                    echo "devzone : argument inconnu : $arg (devzone use CTX [-n NS] [--confirm CTX])" >&2
                    return 2
                fi
                ctx="$arg"
                ;;
        esac
    done
    if [ -z "$ctx" ]; then
        if [ -z "$namespace" ]; then
            echo "devzone : contexte manquant : devzone use CTX" >&2
            return 2
        fi
        courant="$(kubectl config current-context 2>/dev/null || true)"
        if [ -z "$courant" ]; then
            echo "devzone : aucun contexte courant" >&2
            return 2
        fi
        ctx="$courant"
    fi
    if ! kubectl config get-contexts -o name 2>/dev/null | grep -qxF -- "$ctx"; then
        echo "devzone : contexte inconnu : $ctx (voir kubectl config get-contexts)" >&2
        return 2
    fi
    courant="$(kubectl config current-context 2>/dev/null || true)"
    if [ "$ctx" != "$courant" ]; then
        if ! cluster_is_local "$ctx"; then
            if [ -n "$confirmer" ]; then
                if [ "$confirmer" != "$ctx" ]; then
                    echo "devzone : cluster distant refusé : $ctx (--confirm $ctx)" >&2
                    return 2
                fi
            elif cluster_interactive; then
                printf 'cluster distant : %s ; tape son nom pour confirmer : ' "$ctx" >&2
                read -r reponse || reponse=""
                if [ "$reponse" != "$ctx" ]; then
                    echo "devzone : cluster distant refusé : $ctx (--confirm $ctx)" >&2
                    return 2
                fi
            else
                echo "devzone : cluster distant refusé : $ctx (--confirm $ctx)" >&2
                return 2
            fi
        fi
        kubectl config use-context "$ctx" >/dev/null
    fi
    if [ -n "$namespace" ]; then
        kubectl config set-context "$ctx" --namespace "$namespace" >/dev/null
    fi
    echo "cluster de travail : $ctx"
    [ -z "$namespace" ] || echo "namespace : $namespace"
}
