#!/usr/bin/env bash
# Volumes MySQL (#440) : choix, liste et suppression des PVC -mysql-0.

# Liste les PVC du namespace mysql dont le nom finit par -mysql-0
mysql_volumes() {
    kubectl --context devzone -n "$NS" get pvc -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null |
        grep -E '\-mysql-0$' || true
}

# Préfixe de claim : 1 PVC → son préfixe, 0 → donnees, >1 → refus (code 2)
mysql_claim_choisir() {
    local liste nb
    liste="$(mysql_volumes)"
    if [ -z "$liste" ]; then echo donnees; return 0; fi
    nb="$(printf '%s\n' "$liste" | grep -c .)"
    if [ "$nb" -eq 1 ]; then echo "${liste%-mysql-0}"; return 0; fi
    echo "devzone : catalogue mysql : plusieurs volumes trouvés :" >&2
    printf '%s\n' "$liste" | sed 's/^/  /' >&2
    echo "devzone : catalogue mysql : choisir avec devzone mysql volume <nom>" >&2
    return 2
}

# Claim porté par le StatefulSet (vide si absent)
mysql_claim_monte() {
    kubectl --context devzone -n "$NS" get statefulset mysql \
        -o jsonpath='{.spec.volumeClaimTemplates[0].metadata.name}' 2>/dev/null || true
}

# Sous-commande volume : liste ou sélectionne/supprime un PVC
mysql_volume() {
    local nom="" oui="" supprimer="" arg reponse pvc monte claim
    for arg in "$@"; do
        case "$arg" in
            --supprimer) supprimer=1 ;;
            --oui) oui=1 ;;
            *) nom="$arg" ;;
        esac
    done
    if [ -n "$supprimer" ]; then
        [ -n "$nom" ] || refuse "volume --supprimer : nom manquant"
        pvc="$nom"
        [[ "$pvc" == *-mysql-0 ]] || pvc="$pvc-mysql-0"
        monte="$(mysql_claim_monte)"
        [ "${pvc%-mysql-0}" != "$monte" ] || refuse "volume monté, suppression refusée : $nom"
        if [ -z "$oui" ]; then
            cluster_interactif || refuse "confirmation impossible sans terminal : devzone mysql volume --supprimer $nom --oui"
            printf 'Supprimer le volume %s ? [o/N] ' "$pvc" >&2
            read -r reponse || reponse=""
            case "$reponse" in
                o | O | oui) ;;
                *) echo "Abandon : rien n'a été supprimé."; return 0 ;;
            esac
        fi
        kubectl --context devzone -n "$NS" delete pvc "$pvc" >/dev/null
        echo "✔ volume $pvc supprimé"
        return 0
    fi
    if [ -z "$nom" ]; then
        monte="$(mysql_claim_monte)"
        mysql_volumes | awk -v m="$monte-mysql-0" 'NF { mark = ($0 == m) ? " (monté)" : ""; printf "  %s%s\n", $0, mark; n++ } END { if (!n) print "  (aucun volume)" }'
        return 0
    fi
    contexte >/dev/null
    installe || refuse "module inactif : devzone activer mysql"
    claim="$nom"
    [[ "$claim" == *-mysql-0 ]] && claim="${claim%-mysql-0}"
    mysql_installer_claim "$claim"
}
