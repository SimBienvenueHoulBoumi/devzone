#!/usr/bin/env bash
# kind wrapper (#291), installed as /usr/local/bin/kind; the real binary is
# kind-reel. With the host's Docker, a cluster created by « kind create cluster »
# writes server: https://127.0.0.1:<port>: unreachable from the container. After
# a successful creation or kubeconfig export, the address is made reachable
# (kube-reachable.sh). Everything else passes through unchanged.
set -uo pipefail

KIND_REEL="${DEVZONE_KIND_REEL:-/usr/local/bin/kind-reel}"
ICI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$ICI/kube-reachable.sh" ]; then
    # shellcheck source=SCRIPTDIR/kube-reachable.sh
    . "$ICI/kube-reachable.sh"
else
    # shellcheck source=/dev/null
    . /usr/local/lib/devzone/kube-reachable.sh
fi

"$KIND_REEL" "$@"
code=$?
[ "$code" -eq 0 ] || exit "$code"

case "${1:-} ${2:-}" in
    "create cluster" | "export kubeconfig") ;;
    *) exit 0 ;;
esac

# File written by kind: --kubeconfig if given, otherwise the first of KUBECONFIG,
# otherwise ~/.kube/config (same rule as kind)
file=""
previous=""
for arg in "$@"; do
    case "$arg" in
        --kubeconfig=*) file="${arg#--kubeconfig=}" ;;
    esac
    [ "$previous" = "--kubeconfig" ] && file="$arg"
    previous="$arg"
done
if [ -z "$file" ] && [ -n "${KUBECONFIG:-}" ]; then
    file="${KUBECONFIG%%:*}"
fi
[ -n "$file" ] || file="$HOME/.kube/config"

kube_reachable_from_container "$file"
exit 0
