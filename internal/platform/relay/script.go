package relay

// loopScript follows the ready pod behind a service and restarts port-forward
// when it changes. It is the script started by relay_start of cluster.sh.
const loopScript = `
pod() {
    case "$2" in
        svc/*) kubectl --context "$0" -n "$1" get endpoints "${2#svc/}" -o jsonpath="{.subsets[*].addresses[*].targetRef.uid}" 2>/dev/null ;;
        *) echo fixe ;;
    esac
}
while :; do
    until [ -n "$(pod "$@")" ]; do sleep 2; done
    actuel="$(pod "$@")"
    kubectl --context "$0" -n "$1" port-forward --address 127.0.0.1 "$2" "${@:3}" &
    pf=$!
    while kill -0 "$pf" 2>/dev/null; do
        sleep 5
        [ "$(pod "$@")" = "$actuel" ] || { kill "$pf" 2>/dev/null; break; }
    done
    wait "$pf" 2>/dev/null
    sleep 1
done`
