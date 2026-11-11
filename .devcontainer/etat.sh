#!/usr/bin/env bash
# Écriture sûre de l'état des modules (#417) : le seul endroit qui pose,
# remplace ou retire une ligne de $ETAT. Un verrou mkdir empêche deux
# écritures simultanées, le temporaire est créé dans le dossier de l'état
# (le mv reste atomique : le fichier n'est jamais absent ni incomplet pour
# un lecteur) et une copie de secours $ETAT.prec précède chaque
# remplacement. Le même fichier crée l'état quand il manque : ancien état
# global repris une fois, copie de secours restaurée, état reconstruit
# depuis le cluster des services, sinon première installation.
# Bibliothèque sourcée : l'appelant définit ETAT.
#   etat_ecrire <clé> <valeur>    pose ou remplace la ligne <clé>=<valeur>
#   etat_retirer <clé>            retire la ligne <clé>=
#   etat_poser <fichier>          remplace tout l'état par ce fichier
#   etat_verrou_prendre / etat_verrou_lacher    verrou d'écriture
#   etat_recouvrement_*           état restauré ou reconstruit (étape 4)
#   etat_initialiser [modules…]   crée l'état s'il manque

# Verrou d'écriture (#476) : etat_verrou_prendre, etat_verrou_lacher
# shellcheck source=SCRIPTDIR/etat-verrou.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/etat-verrou.sh"

# Abandon sous verrou : le temporaire part, le verrou est lâché
etat_echec() {
    rm -f "${1:-}"
    etat_verrou_lacher
    return 1
}

# Copie de secours de l'état courant, avant remplacement
etat_sauvegarder() {
    [ -f "$ETAT" ] || return 0
    cp "$ETAT" "${ETAT}.prec"
}

# L'état sans la ligne $1, écrit dans le fichier temporaire $2
etat_filtrer() {
    local cle="$1" dst="$2" code=0
    [ -f "$ETAT" ] || return 0
    grep -vE "^${cle}=" "$ETAT" >"$dst" || code=$?
    [ "$code" -le 1 ] || return 1
    return 0
}

# Sous verrou : remplace tout l'état par un fichier, $ETAT.prec sauvegardé
etat_poser() {
    local src="$1" tmp
    [ -f "$src" ] || return 1
    etat_verrou_prendre || return 1
    etat_sauvegarder || { etat_verrou_lacher; return 1; }
    tmp="$(mktemp "${ETAT}.XXXXXX")" || { etat_verrou_lacher; return 1; }
    cat "$src" >"$tmp" || { etat_echec "$tmp"; return 1; }
    mv "$tmp" "$ETAT" || { etat_echec "$tmp"; return 1; }
    etat_verrou_lacher
    return 0
}

# Sous verrou : nouvelle valeur d'une clé, sans perdre les autres lignes
etat_ecrire() {
    local cle="$1" valeur="$2" tmp
    etat_verrou_prendre || return 1
    etat_sauvegarder || { etat_verrou_lacher; return 1; }
    tmp="$(mktemp "${ETAT}.XXXXXX")" || { etat_verrou_lacher; return 1; }
    etat_filtrer "$cle" "$tmp" || { etat_echec "$tmp"; return 1; }
    printf '%s=%s\n' "$cle" "$valeur" >>"$tmp" || { etat_echec "$tmp"; return 1; }
    mv "$tmp" "$ETAT" || { etat_echec "$tmp"; return 1; }
    etat_verrou_lacher
    return 0
}

# Sous verrou : retire une clé (#417) ; sans état, rien à retirer
etat_retirer() {
    local cle="$1" tmp
    etat_verrou_prendre || return 1
    [ -f "$ETAT" ] || { etat_verrou_lacher; return 0; }
    etat_sauvegarder || { etat_verrou_lacher; return 1; }
    tmp="$(mktemp "${ETAT}.XXXXXX")" || { etat_verrou_lacher; return 1; }
    etat_filtrer "$cle" "$tmp" || { etat_echec "$tmp"; return 1; }
    mv "$tmp" "$ETAT" || { etat_echec "$tmp"; return 1; }
    etat_verrou_lacher
    return 0
}

# Signale un état restauré ou reconstruit : les veilleurs attendent (#417)
etat_recouvrement_marquer() {
    date +%s >"${ETAT}.recouvre" 2>/dev/null || true
}

# 0 (à attendre) moins de 60 s après une restauration ou une reconstruction
etat_recouvrement_attente() {
    local marque
    [ -f "${ETAT}.recouvre" ] || return 1
    marque="$(cat "${ETAT}.recouvre" 2>/dev/null || true)"
    case "$marque" in
        '' | *[!0-9]*) return 1 ;;
    esac
    [ "$(( $(date +%s) - marque ))" -lt 60 ]
}

# 0 si l'état restauré ou reconstruit n'est pas encore confirmé (#417)
etat_recouvrement_en_attente() {
    [ -f "${ETAT}.recouvre" ]
}

# L'utilisateur a confirmé l'état (devzone appliquer) : plus de garde
etat_recouvrement_confirmer() {
    rm -f "${ETAT}.recouvre" 2>/dev/null || true
    return 0
}

# Première installation (#417) : l'état par défaut, écrit d'un bloc
etat_defaut() {
    local stage code=0
    stage="$(mktemp)" || return 1
    printf 'ia=off\nkubernetes=off\ngitlab=off\n' >"$stage"
    etat_poser "$stage" || code=$?
    rm -f "$stage"
    return "$code"
}

# Contexte de l'hôte (KUBECONFIG de l'hôte) qui pointe sur le cluster donné :
# le cluster= de l'état attend ce contexte, pas « devzone » (cluster des services)
contexte_hote_du_cluster() {
    local cluster="$1" hote ctx
    hote="${DEVZONE_KUBE_HOTE:-$HOME/.kube/hote.config}"
    while IFS= read -r ctx; do
        [ -n "$ctx" ] || continue
        # Le contexte « devzone » est posé sur le cluster des services : on
        # cherche le contexte de l'hôte qui y pointe
        [ "$ctx" = devzone ] && continue
        if [ "$(KUBECONFIG="$hote" kubectl config view -o jsonpath="{.contexts[?(@.name=\"$ctx\")].context.cluster}" 2>/dev/null || true)" = "$cluster" ]; then
            echo "$ctx"
            return 0
        fi
    done < <(KUBECONFIG="$hote" kubectl config get-contexts -o name 2>/dev/null)
    return 1
}

# État absent sans copie de secours (#417, étape 3) : reconstruit depuis les
# namespaces étiquetés devzone du cluster des services (module à on si son
# namespace existe, cluster= du contexte devzone) ; rend 1 sinon.
etat_reconstruire() {
    local nss m v stage vu=0 code=0 cluster_ctx cluster_hote etiquette
    etiquette="${CLUSTER_ETIQUETTE:-app.kubernetes.io/managed-by=devzone}"
    command -v kubectl >/dev/null 2>&1 || return 1
    nss="$(kubectl get namespaces -l "$etiquette" -o name 2>/dev/null || true)"
    [ -n "$nss" ] || return 1
    stage="$(mktemp)" || return 1
    for m in "$@"; do
        v=off
        printf '%s\n' "$nss" | grep -qx "namespace/devzone-$m" && { v=on; vu=1; }
        printf '%s=%s\n' "$m" "$v" >>"$stage" || code=1
    done
    # Contexte devzone -> cluster des services ; le cluster= attend le contexte
    # réel de l'hôte qui y pointe (ex. docker-desktop). Sans hôte : aucune ligne.
    cluster_ctx="$(kubectl config view -o jsonpath="{.contexts[?(@.name=\"devzone\")].context.cluster}" 2>/dev/null || true)"
    cluster_hote=""
    if [ -n "$cluster_ctx" ]; then
        cluster_hote="$(contexte_hote_du_cluster "$cluster_ctx")"
        if [ -n "$cluster_hote" ]; then
            printf 'cluster=%s\n' "$cluster_hote" >>"$stage" || code=1
        fi
    fi
    if [ "$code" -eq 0 ] && [ "$vu" -eq 1 ] && etat_poser "$stage"; then
        echo "devzone : état reconstruit depuis les namespaces du cluster des services : $ETAT (confirmez par devzone appliquer)" >&2
        [ -n "$cluster_hote" ] || echo "devzone : aucun contexte d'hôte ne pointe sur le cluster des services : pas de ligne cluster= dans $ETAT" >&2
        rm -f "$stage"
        return 0
    fi
    rm -f "$stage"
    return 1
}

# Premier démarrage (aucun état) : ancien état global repris une fois, sinon
# copie de secours restaurée, sinon état reconstruit, sinon tout désactivé
etat_initialiser() {
    [ -f "$ETAT" ] && return 0

    # Migration : ancien état global (~/.config/devzone/modules) vers l'état
    # de l'instance ; déplacé, pas copié : le premier devzone démarré après
    # la mise à jour garde ses choix
    if [ -f "$HOME/.config/devzone/modules" ]; then
        if etat_poser "$HOME/.config/devzone/modules"; then
            rm -f "$HOME/.config/devzone/modules"
            return 0
        fi
    fi

    etat_verrou_prendre || return 1
    if [ -f "$ETAT" ]; then
        etat_verrou_lacher
        return 0
    fi
    # 1. Copie de secours laissée par la dernière écriture (#417)
    if [ -f "${ETAT}.prec" ] && etat_poser "${ETAT}.prec"; then
        echo "devzone : état restauré depuis la copie de secours : $ETAT (confirmez par devzone appliquer)" >&2
        etat_recouvrement_marquer
        etat_verrou_lacher
        return 0
    fi
    # 2. Reconstruction depuis le cluster des services (#417)
    if etat_reconstruire "$@"; then
        etat_recouvrement_marquer
        etat_verrou_lacher
        return 0
    fi
    # 3. Première installation : tout désactivé (#417)
    if ! etat_defaut; then
        etat_verrou_lacher
        return 1
    fi
    etat_verrou_lacher
    # Connexion déjà établie par une autre devzone (volumes partagés) :
    # signalée une seule fois, à la création de l'état de cette instance ;
    # stderr : initialiser est aussi appelé dans $(valeur …)
    if [ -f "$HOME/.claude/.credentials.json" ] || [ -f "$HOME/.local/share/opencode/auth.json" ]; then
        echo "devzone : connexion Claude Code/opencode partagée trouvée : devzone activer ia pour l'utiliser ici" >&2
    fi
    return 0
}
