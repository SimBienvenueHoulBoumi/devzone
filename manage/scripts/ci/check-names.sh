#!/usr/bin/env bash
# CI check: the names of the files and folders tracked by git are in English
# (#716). A path fails when one of its words (split on - . _ and /) is in the
# list of French words below. Each fault is printed as "path: word" and the
# run exits 1; otherwise it prints "names check: N paths ok" and exits 0.
# Not checked: .github/ (the workflow names are referenced by the repowarden
# checks) and the names listed in ALLOWED (user data kept under its name, and
# the migration script, which must hold the former names). bash 3.2 (macOS).

set -u

ICI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$ICI/../../.." && pwd)"

# French words that must not appear in a name. Split fragments, so this file
# does not match its own rules (the check-english convention).
FRENCH=" cre_er desinst_aller migr_er ret_our et_at demarr_age catalog_ue paqu_ets plate_forme memo_ire rel_ais verr_ou veill_eur dro_its err_eurs mod_ele mod_eles ec_arts chem_ins para_llele ho_te san_s ave_c envel_oppe join_gnable isole_ment comp_te lan_cer rep_arer util_iser garde_ mett_re identi_te invi_te "
FRENCH="$(printf '%s' "$FRENCH" | tr -d '_')"

# Names of the user data kept as they are, and the migration script (#733, it
# holds the former names to rename them)
ALLOWED=" .devzone.modules .devzone.version .devcontainer/rename-legacy-files.sh "

if ! paths="$(git -C "$ROOT" ls-files --cached --others --exclude-standard)"; then
    echo "check-names: git ls-files fails in $ROOT" >&2
    exit 1
fi

fails=0
count=0
while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$path" in
        .github/*) continue ;;
    esac
    count=$((count + 1))
    words="$(printf '%s' "$path" | tr '/._-' '    ')"
    for word in $words; do
        case "$FRENCH" in
            *" $word "*)
                skip=0
                for allowed in $ALLOWED; do
                    case "$path" in
                        "$allowed" | "$allowed"/*) skip=1 ;;
                    esac
                done
                if [ "$skip" -eq 0 ]; then
                    printf '%s: %s\n' "$path" "$word"
                    fails=1
                fi
                ;;
        esac
    done
done <<LISTE
$paths
LISTE

if [ "$fails" -ne 0 ]; then
    exit 1
fi
echo "names check: $count paths ok"
