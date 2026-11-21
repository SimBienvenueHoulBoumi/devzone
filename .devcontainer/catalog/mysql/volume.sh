#!/usr/bin/env bash
# MySQL volumes (#440): choice, listing and deletion of the -mysql-0 PVCs.

# Lists the PVCs of the namespace whose name ends with -mysql-0
mysql_volumes() {
    local ns="$1"
    kubectl --context devzone -n "$ns" get pvc -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null |
        grep -E '\-mysql-0$' || true
}

# Claim prefix: 1 PVC -> its prefix, 0 -> donnees, >1 -> refusal (code 2)
mysql_claim_choose() {
    local ns="$1" list count
    list="$(mysql_volumes "$ns")"
    if [ -z "$list" ]; then echo donnees; return 0; fi
    count="$(printf '%s\n' "$list" | grep -c .)"
    if [ "$count" -eq 1 ]; then echo "${list%-mysql-0}"; return 0; fi
    echo "devzone : catalog mysql : several volumes found:" >&2
    printf '%s\n' "$list" | sed 's/^/  /' >&2
    echo "devzone : catalog mysql : choose one with devzone mysql volume <name>" >&2
    return 2
}

# Claim carried by the StatefulSet (empty if absent)
mysql_claim_mounted() {
    local ns="$1"
    kubectl --context devzone -n "$ns" get statefulset mysql \
        -o jsonpath='{.spec.volumeClaimTemplates[0].metadata.name}' 2>/dev/null || true
}

# volume subcommand: lists, or selects/deletes a PVC
mysql_volume() {
    local ns="$1" name="" yes="" delete="" arg answer pvc mounted claim
    shift
    for arg in "$@"; do
        case "$arg" in
            --delete) delete=1 ;;
            --yes) yes=1 ;;
            *) name="$arg" ;;
        esac
    done
    if [ -n "$delete" ]; then
        [ -n "$name" ] || refuse "volume --delete: missing name"
        pvc="$name"
        [[ "$pvc" == *-mysql-0 ]] || pvc="$pvc-mysql-0"
        mounted="$(mysql_claim_mounted "$ns")"
        [ "${pvc%-mysql-0}" != "$mounted" ] || refuse "mounted volume, deletion refused: $name"
        if [ -z "$yes" ]; then
            cluster_interactive || refuse "confirmation needs a terminal: devzone mysql volume --delete $name --yes"
            printf 'Delete volume %s? [y/N] ' "$pvc" >&2
            read -r answer || answer=""
            case "$answer" in
                y | Y | yes) ;;
                *) echo "Aborted: nothing was deleted."; return 0 ;;
            esac
        fi
        kubectl --context devzone -n "$ns" delete pvc "$pvc" >/dev/null
        echo "✔ volume $pvc deleted"
        return 0
    fi
    if [ -z "$name" ]; then
        mounted="$(mysql_claim_mounted "$ns")"
        mysql_volumes "$ns" | awk -v m="$mounted-mysql-0" 'NF { mark = ($0 == m) ? " (mounted)" : ""; printf "  %s%s\n", $0, mark; n++ } END { if (!n) print "  (no volume)" }'
        return 0
    fi
    module_context >/dev/null
    installed || refuse "module disabled: devzone enable mysql"
    claim="$name"
    [[ "$claim" == *-mysql-0 ]] && claim="${claim%-mysql-0}"
    mysql_install_claim "$ns" "$claim"
}
