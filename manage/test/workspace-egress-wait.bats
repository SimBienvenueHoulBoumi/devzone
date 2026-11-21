#!/usr/bin/env bats
# devzone workspace egress (#633): the wait for the proxy after a redeploy. Argo
# CD creates the proxy Deployment late: the wait looks it up first, then its
# rollout. Fake kubectl in $BATS_TEST_TMPDIR/bin: no cluster, no network. Waits
# are shortened (DEVZONE_EGRESS_WAIT 2, DEVZONE_EGRESS_STEP 1, rollout 1 s).

setup() {
    load commun
    kube_isole
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CLI="$RACINE/manage/devzone"
    T="$BATS_TEST_TMPDIR"
    R="$T/racine"
    export DEVZONE_ROOT="$R"
    export DEVZONE_EGRESS_WAIT=2 DEVZONE_EGRESS_STEP=1 DEVZONE_EGRESS_ROLLOUT=1
    mkdir -p "$T/bin" "$R/workspace"
    : >"$T/kubectl.log"; : >"$T/helm.log"
    # FAKE_DEPLOY_ABSENT : number of « not found » answers to get deployment
    # before the Deployment exists (default 0: it exists at once)
    cat >"$T/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
echo "kubectl $*" >>"$T/kubectl.log"
case "$*" in
    "config get-contexts -o name") echo docker-desktop ;;
    *"cluster-info"*) exit 0 ;;
    *"get namespace devzone-argocd"*) exit 0 ;;
    *"get application.argoproj.io devzone-workspace -o jsonpath"*) cat "$T/app-current" ;;
    *"get deployment devzone-workspace-egress-proxy"*)
        n="$(grep -c 'get deployment devzone-workspace-egress-proxy' "$T/kubectl.log")"
        if [ "$n" -le "${FAKE_DEPLOY_ABSENT:-0}" ]; then
            echo 'Error from server (NotFound): deployments.apps "devzone-workspace-egress-proxy" not found' >&2
            exit 1
        fi
        exit 0
        ;;
    *"rollout status"*) [ -z "${FAKE_ROLLOUT_FAIL:-}" ]; exit $? ;;
    *"apply -f -"*) cat >>"$T/applied.yaml" ;;
esac
exit 0
KUBE
    cat >"$T/bin/helm" <<'HELM'
#!/usr/bin/env bash
echo "helm $*" >>"$BATS_TEST_TMPDIR/helm.log"
HELM
    # Registry answers: the image of every requested tag exists
    cat >"$T/bin/curl" <<'CURL'
#!/usr/bin/env bash
case "$*" in *"/token?"*) echo '{"token":"FAKE-TOKEN"}' ;; esac
CURL
    # gh answers no: the GitOps repository is off, no network
    cat >"$T/bin/gh" <<'GH'
#!/usr/bin/env bash
exit 1
GH
    chmod +x "$T/bin/"*; export PATH="$T/bin:$PATH"
    cd "$R" || return 1
    printf 'workspace=kubernetes\nargocd=on\n' >"$R/.devzone.modules"
    printf '[argocd]\n    repo = none\n' >"$R/.argocd.conf"
    : >"$T/argocd-ns"; printf 'v0.48.0 0.48.0' >"$T/app-current"
}

@test "egress wait: the Deployment created late, found on the third look, then rolled out" {
    export FAKE_DEPLOY_ABSENT=2
    run bash "$CLI" workspace egress strict </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"egress strict"* ]] || false
    [[ "$output" != *"not created by Argo CD"* ]] || false
    [[ "$output" != *"not ready"* ]] || false
    [ "$(grep -c 'get deployment devzone-workspace-egress-proxy' "$T/kubectl.log")" -eq 3 ] || false
    grep -q 'rollout status deployment/devzone-workspace-egress-proxy --timeout=1s' "$T/kubectl.log" || false
    grep -qx 'egress=strict' "$R/.devzone.modules" || false
}

@test "egress wait: the Deployment never created, message, non-zero code, setting kept" {
    export FAKE_DEPLOY_ABSENT=999
    run bash "$CLI" workspace egress strict </dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"the egress proxy was not created by Argo CD after 2 s: the setting is kept, check devzone workspace argocd status"* ]] || false
    if grep -q 'rollout status' "$T/kubectl.log"; then false; fi
    grep -qx 'egress=strict' "$R/.devzone.modules" || false
}

@test "egress wait: the Deployment exists but the rollout fails, message not ready, setting kept" {
    export FAKE_ROLLOUT_FAIL=1
    run bash "$CLI" workspace egress strict </dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"egress proxy not ready after 1 s: the setting is kept, see devzone workspace egress status"* ]] || false
    [[ "$output" != *"not created by Argo CD"* ]] || false
    grep -qx 'egress=strict' "$R/.devzone.modules" || false
}

@test "egress wait: mode off waits for nothing, no look at the Deployment" {
    printf 'egress=strict\n' >>"$R/.devzone.modules"
    export FAKE_DEPLOY_ABSENT=999
    run bash "$CLI" workspace egress off </dev/null
    [ "$status" -eq 0 ]
    grep -qx 'egress=off' "$R/.devzone.modules" || false
    if grep -q 'get deployment devzone-workspace-egress-proxy' "$T/kubectl.log"; then false; fi
    if grep -q 'rollout status' "$T/kubectl.log"; then false; fi
}
