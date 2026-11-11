#!/usr/bin/env bash
# Retour arrière du workspace Kubernetes vers le poste Docker (#403) : devzone workspace
# revenir [--rapatrier]. Sourcé par manage/workspace.sh après migrer.sh (utilise
# copier_depuis, noter_workspace, echec et kc). Avec --rapatrier, la version du poste
# d'un projet est déplacée dans .devzone.sauvegarde/<date>/ avant d'être remplacée.

# Dossier de sauvegarde de cette exécution (relatif au devzone), même convention que
# devzone mettre-a-jour : .devzone.sauvegarde/<AAAAMMJJ-HHMMSS>, suffixe -n si pris.
dossier_sauvegarde() {
    local base dossier n=1
    base=".devzone.sauvegarde/$(date +%Y%m%d-%H%M%S)"
    dossier="$base"
    while [ -e "$dossier" ]; do
        n=$((n + 1))
        dossier="$base-$n"
    done
    printf '%s' "$dossier"
}

# Rapatrie le projet $1 du pod ; sa version du poste ($2 : dossier de sauvegarde) est
# déplacée d'abord. Si le déplacement échoue, rien n'est écrasé.
rapatrier_projet() {
    local p="$1" sauvegarde="$2"
    if [ -e "workspace/$p" ]; then
        mkdir -p "$sauvegarde/workspace" && mv "workspace/$p" "$sauvegarde/workspace/$p" || {
            echec "sauvegarde de workspace/$p impossible : rien n'a été écrasé"
            return 1
        }
        echo "projet $p : version du poste sauvegardée dans $sauvegarde/"
    fi
    copier_depuis "$PWD/workspace/$p" || {
        echec "rapatriement de $p échoué (version du poste : $sauvegarde/workspace/$p)"
        return 1
    }
}

# devzone workspace revenir [--rapatrier] : workspace=docker ; --rapatrier recopie d'abord les projets du pod.
revenir() {
    local rapatrier p liste sauvegarde
    rapatrier="$(lire_option --rapatrier "revenir [--rapatrier]" "$@")" || return 1
    if [ "$rapatrier" = 1 ]; then
        echo "▶ rapatriement : projets du pod vers ./workspace (la version du poste est sauvegardée d'abord)"
        liste="$(kc exec "$POD" -c workspace -- ls -1 "$DOSSIER_PROJETS")" || { echec "liste des projets du pod illisible"; return 1; }
        mkdir -p workspace
        sauvegarde="$(dossier_sauvegarde)"
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            echo "  … $p"
            rapatrier_projet "$p" "$sauvegarde" || return 1
        done <<<"$liste"
    fi
    noter_workspace docker || { echec "écriture de .devzone.modules impossible"; return 1; }
    echo "✔ workspace=docker : le poste Docker et ses volumes sont intacts. Relance-le : make shell"
}
