#!/usr/bin/env bash
# Fake helm for the tests of the helm-direct path (#559, step 7). `helm template`
# is the real binary (a local rendering, no cluster reached); `helm upgrade
# --install` renders the same chart and applies it with the fake kubectl of the
# test, so that the assertions on the applied objects still hold. Every call is
# logged in helm.log. helm_fake_install is called in setup, before PATH gets the
# test bin folder; the real helm is looked up then and nowhere else.

helm_fake_install() {
    local real
    real="$(command -v helm 2>/dev/null)" || { echo "helm missing: the test cannot run" >&2; return 1; }
    HELM_REAL="$real"
    export HELM_REAL
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat >"$BATS_TEST_TMPDIR/bin/helm" <<'HELM'
#!/usr/bin/env bash
echo "helm $*" >>"$BATS_TEST_TMPDIR/helm.log"
# --kube-context NAME is dropped: the rendering is local
if [ "${1:-}" = --kube-context ]; then shift 2; fi
case "${1:-}" in
    template) shift; exec "$HELM_REAL" template "$@" ;;
    upgrade)
        shift
        [ "${1:-}" = --install ] && shift
        # helm puts the objects without a namespace in the one of -n
        ns=""
        prev=""
        for arg in "$@"; do
            if [ "$prev" = -n ]; then ns="$arg"; fi
            prev="$arg"
        done
        "$HELM_REAL" template "$@" | kubectl --context devzone -n "${ns:-default}" apply -f - >/dev/null
        ;;
esac
HELM
    chmod +x "$BATS_TEST_TMPDIR/bin/helm"
    : >"$BATS_TEST_TMPDIR/helm.log"
}
