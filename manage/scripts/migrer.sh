#!/usr/bin/env bash
# Migration du poste Docker vers le workspace Kubernetes, et retour arrière (#403).
# Sourcé par manage/workspace.sh : utilise POD, NAMESPACE, DOSSIER_PROJETS,
# drapeau_kubectl, copier_vers et copier_depuis. Rien n'est jamais supprimé, sauf
# par nettoyer-docker, après confirmation. Lancé depuis le dossier devzone du poste.

# Home de vscode dans le pod et image des copies de volumes Docker.
HOME_POD="/home/vscode"
IMAGE_COPIE="${DEVZONE_IMAGE_COPIE:-busybox:1.36}"
# Volumes Docker du poste : devzone-<x>, ou $DEVZONE_VOLUMES-<x> (tests fonctionnels).
VOLUMES_DOCKER=(gh git claude opencode-config opencode-data agent config m2 gradle pnpm)
# Mesure d'un dossier ($1) : « nombre de fichiers octets ».
MESURE='n=$(find "$1" -type f | wc -l | tr -d " "); o=$(find "$1" -type f -exec wc -c {} + 2>/dev/null | awk '\''$2!="total"{s+=$1} END{print s+0}'\''); echo "$n $o"'

# kubectl du poste, contexte devzone s'il existe, namespace du workspace.
kc() {
    local drapeau
    drapeau="$(drapeau_kubectl)"
    # shellcheck disable=SC2086
    kubectl $drapeau --namespace "$NAMESPACE" "$@"
}

# Erreur claire sur stderr (le code 1 est rendu par l'appelant).
echec() {
    echo "✖ $*" >&2
}

# Lit l'unique option acceptée ($1) des arguments suivants ($3…) : affiche 1 si
# présente, 0 sinon ; toute autre option : erreur avec l'usage ($2), code 1.
lire_option() {
    local option="$1" usage="$2" a trouve=0
    shift 2
    for a in "$@"; do
        if [ "$a" = "$option" ]; then trouve=1; continue; fi
        echec "option inconnue : $a (devzone workspace $usage)"
        return 1
    done
    echo "$trouve"
}

# Chemin du volume etat (relatif au home de vscode) d'un volume Docker devzone-<x> ;
# vide si le chart n'en monte aucun (persistence.etat.chemins).
chemin_etat() {
    case "$1" in
        gh) echo .config/gh ;;
        git) echo .config/git ;;
        claude) echo .claude ;;
        opencode-config) echo .config/opencode ;;
        opencode-data) echo .local/share/opencode ;;
        agent) echo .local/state/oc-lancer ;;
        m2) echo .m2 ;;
        gradle) echo .gradle ;;
        pnpm) echo .local/share/pnpm ;;
    esac
}

# Nom du volume Docker de <x>.
volume_docker() {
    printf '%s-%s' "${DEVZONE_VOLUMES:-devzone}" "$1"
}

# Demande [o/N] ($1 : question, $2 : 1 si --oui). Sans terminal et sans --oui : refus.
confirmer() {
    local rep=""
    [ "${2:-0}" = 1 ] && return 0
    if [ ! -t 0 ]; then
        echo "✖ pas de terminal : confirmation impossible, relance avec --oui" >&2
        return 1
    fi
    read -r -p "$1 [o/N] " rep || true
    case "$rep" in o | O | oui | OUI | Oui) return 0 ;; esac
    echo "✖ annulé, rien n'a été modifié" >&2
    return 1
}

# Compare le dossier du poste ($1) à celui du pod ($2) : mêmes fichiers, même taille.
verifier_copie() {
    local poste pod
    poste="$(sh -c "$MESURE" _ "$1")"
    pod="$(kc exec "$POD" -c workspace -- sh -c "$MESURE" _ "$2")" || pod="illisible"
    if [ "$poste" != "$pod" ]; then
        echec "copie différente pour $2 : poste « $poste », pod « $pod » (fichiers octets)"
        return 1
    fi
    echo "  ✔ $2 : ${poste% *} fichier(s), ${poste#* } octet(s)"
}

# Étape 1 : cluster joignable, pod démarré, place suffisante pour les projets.
etape_verifs() {
    local phase besoin libre
    echo "▶ [1/5] vérifications : cluster, workspace, espace"
    kc get --raw /readyz >/dev/null 2>&1 || {
        echec "cluster injoignable : vérifie le contexte kubectl (kubectl config get-contexts)"
        return 1
    }
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || {
        echec "Docker ne répond pas : il faut lire les volumes devzone-* du poste"
        return 1
    }
    phase="$(kc get pod "$POD" -o 'jsonpath={.status.phase}' 2>/dev/null || true)"
    [ "$phase" = "Running" ] || { echec "workspace non démarré (pod $POD : ${phase:-absent}) : devzone workspace demarrer"; return 1; }
    besoin=0
    [ -d workspace ] && besoin="$(du -sk workspace | cut -f1)"
    libre="$(kc exec "$POD" -c workspace -- df -Pk "$DOSSIER_PROJETS" | awk 'NR==2{print $4}')" || libre=0
    if [ "${libre:-0}" -lt "$besoin" ]; then
        echec "espace insuffisant sur $DOSSIER_PROJETS : ${libre:-0} Ko libres, $besoin Ko de projets"
        return 1
    fi
    echo "  ✔ cluster joignable, pod $POD prêt, $libre Ko libres pour $besoin Ko de projets"
}

# Étape 2 : chaque projet de ./workspace copié dans le pod, puis vérifié.
etape_projets() {
    local d nom
    echo "▶ [2/5] projets : ./workspace/<projet> vers $DOSSIER_PROJETS (.git compris)"
    for d in workspace/*/; do
        [ -d "$d" ] || continue
        nom="$(basename "$d")"
        echo "  … $nom"
        (copier_vers "$d") || { echec "copie du projet $nom échouée"; return 1; }
        verifier_copie "$d" "$DOSSIER_PROJETS/$nom" || return 1
    done
}

# Copie le volume Docker <x> ($1) vers $2 du home du pod, par un conteneur en lecture seule.
copier_volume() {
    local v cible="$HOME_POD/$2" tmp statut=0
    v="$(volume_docker "$1")"
    tmp="$(mktemp -d)"
    if ! docker run --rm -v "$v:/src:ro" "$IMAGE_COPIE" tar cf - -C /src . | tar xf - -C "$tmp"; then
        echec "lecture du volume $v échouée"
        statut=1
    elif ! kc cp "$tmp/." "$POD:$cible" -c workspace; then
        echec "copie de $v vers $cible échouée"
        statut=1
    else
        verifier_copie "$tmp" "$cible" || statut=1
    fi
    rm -rf "$tmp"
    return "$statut"
}

# Étape 3 : identités et caches, volumes Docker vers les chemins du volume etat.
etape_identites() {
    local x chemin v
    echo "▶ [3/5] identités et caches : volumes Docker vers le volume etat"
    for x in "${VOLUMES_DOCKER[@]}"; do
        chemin="$(chemin_etat "$x")"
        v="$(volume_docker "$x")"
        if [ -z "$chemin" ]; then
            echo "  – $v : aucun chemin dans le volume etat du chart, ignoré"
        elif ! docker volume inspect "$v" >/dev/null 2>&1; then
            echo "  – $v : absent, ignoré"
        else
            echo "  … $v → $HOME_POD/$chemin"
            copier_volume "$x" "$chemin" || return 1
        fi
    done
}

# Étape 4 : .devzone.modules et .devzone.paquets du poste copiés dans le pod.
etape_etat() {
    local f
    echo "▶ [4/5] état : .devzone.modules et .devzone.paquets vers $DOSSIER_PROJETS"
    for f in .devzone.modules .devzone.paquets; do
        if [ ! -f "$f" ]; then
            echo "  – $f : absent du poste, ignoré"
            continue
        fi
        kc cp "$PWD/$f" "$POD:$DOSSIER_PROJETS/$f" -c workspace \
            && kc exec "$POD" -c workspace -- test -f "$DOSSIER_PROJETS/$f" || { echec "copie de $f échouée ou absente du pod"; return 1; }
        echo "  ✔ $f"
    done
}

# Note workspace=$1 dans .devzone.modules du poste (ligne remplacée, le reste intact).
noter_workspace() {
    local f=".devzone.modules" tmp
    tmp="$f.tmp.$$"
    {
        if [ -f "$f" ]; then grep -v '^workspace=' "$f" || true; fi
        echo "workspace=$1"
    } >"$tmp" && mv "$tmp" "$f"
}

# Étape 5 : bascule, workspace=kubernetes noté sur le poste ; rien n'est supprimé.
etape_bascule() {
    echo "▶ [5/5] bascule : workspace=kubernetes dans .devzone.modules"
    noter_workspace kubernetes || { echec "écriture de .devzone.modules impossible"; return 1; }
    echo "  ✔ fait ; le poste Docker et ses volumes sont intacts (retour : devzone workspace revenir)"
}

# devzone workspace migrer [--oui] : les cinq étapes, arrêt à la première erreur.
migrer() {
    local oui
    oui="$(lire_option --oui "migrer [--oui]" "$@")" || return 1
    confirmer "Migrer ce poste Docker vers le workspace Kubernetes (copie, rien n'est supprimé) ?" "$oui" || return 1
    etape_verifs || return 1
    etape_projets || return 1
    etape_identites || return 1
    etape_etat || return 1
    etape_bascule || return 1
    echo "✔ migration terminée"
}

# devzone workspace nettoyer-docker [--oui] : supprime les volumes Docker devzone-*, après confirmation.
nettoyer_docker() {
    local oui x v presents=()
    oui="$(lire_option --oui "nettoyer-docker [--oui]" "$@")" || return 1
    for x in "${VOLUMES_DOCKER[@]}"; do
        v="$(volume_docker "$x")"
        ! docker volume inspect "$v" >/dev/null 2>&1 || presents+=("$v")
    done
    if [ "${#presents[@]}" -eq 0 ]; then
        echo "Aucun volume Docker devzone à supprimer."
        return 0
    fi
    echo "Volumes Docker à supprimer (irréversible, « revenir » ne les retrouvera plus) :"
    printf '  %s\n' "${presents[@]}"
    confirmer "Supprimer ces ${#presents[@]} volume(s) ?" "$oui" || return 1
    for v in "${presents[@]}"; do
        docker volume rm "$v" >/dev/null || { echec "suppression de $v échouée"; return 1; }
        echo "  ✔ $v supprimé"
    done
}
