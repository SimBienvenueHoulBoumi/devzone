#!/usr/bin/env bash
# CI check: the files listed in .english must be written in English (#502).
# A file fails when one of its lines contains a French accented letter or one
# of the frequent French words, whole word, case-insensitive. Each fault is
# printed as "path:line: text" and the run exits 1; otherwise it prints
# "english check: N files ok" and exits 0. A listed file that is missing is
# an error too.

set -u

ICI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$ICI/../.." && pwd)"
LIST="$ROOT/.english"

# Byte escapes and split fragments, so this file never matches its own rules
# (a literal accented letter or whole word here would be reported).
ACCENTS="$(printf '[\303\305][\200\202\204\206\207\210\211\212\213\216\217\222\223\224\226\231\233\234\240\242\244\246\247\250\251\252\253\256\257\264\266\270\271\273\274\277]')"
WORDS="$(printf 'le_s|de_s|un_e|po_ur|av_ec|sa_ns|da_ns|fich_ier|doss_ier' | tr -d '_')"
PATTERN="$ACCENTS|\\b($WORDS)\\b"

# Byte matching only: the accents are matched as UTF-8 byte sequences
LC_ALL=C
export LC_ALL

if [ ! -f "$LIST" ]; then
    echo "check-english: list not found: $LIST" >&2
    exit 1
fi

fails=0
count=0
while IFS= read -r f; do
    case "$f" in
        '' | '#'*) continue ;;
    esac
    file="$ROOT/$f"
    if [ ! -f "$file" ]; then
        echo "check-english: file listed but missing: $f" >&2
        fails=1
        continue
    fi
    count=$((count + 1))
    matches="$(grep -Ein -- "$PATTERN" "$file")" || matches=""
    while IFS= read -r m; do
        [ -n "$m" ] || continue
        n="${m%%:*}"
        printf '%s:%s: %s\n' "$f" "$n" "${m#*:}"
        fails=1
    done <<EOF
$matches
EOF
done <"$LIST"

if [ "$fails" -ne 0 ]; then
    exit 1
fi
echo "english check: $count files ok"
