#!/usr/bin/env bash
# Enveloppe de kind (#291), installée comme /usr/local/bin/kind ; le vrai
# binaire est kind-reel. Avec le Docker de l'hôte, un cluster créé par
# « kind create cluster » écrit server: https://127.0.0.1:<port> : injoignable
# depuis le conteneur. Après une création ou un export de kubeconfig réussis,
# l'adresse est rendue joignable (kube-joignable.sh). Tout le reste passe tel quel.
set -uo pipefail

KIND_REEL="${DEVZONE_KIND_REEL:-/usr/local/bin/kind-reel}"
ICI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$ICI/kube-joignable.sh" ]; then
    # shellcheck source=SCRIPTDIR/kube-joignable.sh
    . "$ICI/kube-joignable.sh"
else
    # shellcheck source=/dev/null
    . /usr/local/lib/devzone/kube-joignable.sh
fi

"$KIND_REEL" "$@"
code=$?
[ "$code" -eq 0 ] || exit "$code"

case "${1:-} ${2:-}" in
    "create cluster" | "export kubeconfig") ;;
    *) exit 0 ;;
esac

# Fichier écrit par kind : --kubeconfig s'il est donné, sinon le premier de
# KUBECONFIG, sinon ~/.kube/config (même règle que kind)
fichier=""
precedent=""
for arg in "$@"; do
    case "$arg" in
        --kubeconfig=*) fichier="${arg#--kubeconfig=}" ;;
    esac
    [ "$precedent" = "--kubeconfig" ] && fichier="$arg"
    precedent="$arg"
done
if [ -z "$fichier" ] && [ -n "${KUBECONFIG:-}" ]; then
    fichier="${KUBECONFIG%%:*}"
fi
[ -n "$fichier" ] || fichier="$HOME/.kube/config"

kube_joignable_depuis_conteneur "$fichier"
exit 0
