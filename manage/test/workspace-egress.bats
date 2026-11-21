#!/usr/bin/env bats
# devzone workspace egress (#633): mode, allow and deny, status, and the replay
# of these settings by workspace_deploy. Fake kubectl, helm, curl and gh in
# $BATS_TEST_TMPDIR/bin: no cluster, no registry and no network is touched.

setup() {
    load commun
    kube_isole
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CLI="$RACINE/manage/devzone"
    T="$BATS_TEST_TMPDIR"
    R="$T/racine"
    export DEVZONE_ROOT="$R"
    mkdir -p "$T/bin" "$R/workspace"
    : >"$T/kubectl.log"; : >"$T/helm.log"
    cat >"$T/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
echo "kubectl $*" >>"$T/kubectl.log"
case "$*" in
    "config get-contexts -o name") echo docker-desktop ;;
    *"cluster-info"*) [ -z "${FAKE_CLUSTER_DOWN:-}" ]; exit $? ;;
    *"get namespace devzone-argocd"*) [ -f "$T/argocd-ns" ]; exit $? ;;
    *"get application.argoproj.io devzone-workspace -o jsonpath"*) [ -f "$T/app-current" ] && cat "$T/app-current" ;;
    *"get service egress-proxy"*) [ -n "${FAKE_EGRESS_MODE:-}" ] && printf '%s' "$FAKE_EGRESS_MODE" || exit 1 ;;
    *"get deployment devzone-workspace-egress-proxy"*) printf '%s' "${FAKE_PROXY_READY:-}" ;;
    *"get configmap devzone-workspace-egress-proxy"*) [ -f "$T/squid.conf" ] && cat "$T/squid.conf" ;;
    *"logs deployment/devzone-workspace-egress-proxy"*) [ -f "$T/access.log" ] && cat "$T/access.log" ;;
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
    printf 'workspace=kubernetes\nargocd=off\n' >"$R/.devzone.modules"
}

# Argo CD installed, the workspace an Application at v0.48.0 (image 0.48.0)
argo_on() {
    printf 'workspace=kubernetes\nargocd=on\n' >"$R/.devzone.modules"; printf '[argocd]\n    repo = none\n' >"$R/.argocd.conf"
    : >"$T/argocd-ns"; printf 'v0.48.0 0.48.0' >"$T/app-current"
}

# One function of manage/workspace.sh, sourced without argument (no dispatch)
ws_call() {
    WS="$RACINE/manage/workspace.sh" bash -c 'f="$1"; shift; args=("$@"); set --; . "$WS" >/dev/null 2>&1; "$f" ${args[@]+"${args[@]}"}' _ "$@"
}

# Helm or Argo CD writes: nothing must have been written for the proxy
no_proxy_write() {
    if grep -q 'egressProxy' "$T/helm.log"; then false; fi
    if grep -q 'egressProxy' "$T/applied.yaml" 2>/dev/null; then false; fi
    if grep -q 'rollout status' "$T/kubectl.log"; then false; fi
}

@test "egress observation: memorised, Application redeployed at the same revision and image tag, proxy waited" {
    argo_on
    run bash "$CLI" workspace egress observation </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"egress observation"* ]] || false
    grep -qx 'egress=observation' "$R/.devzone.modules" || false
    grep -q 'targetRevision: v0.48.0' "$T/applied.yaml" || false
    grep -A1 'name: image.tag' "$T/applied.yaml" | grep -q 'value: "0.48.0"' || false
    grep -A1 'name: egressProxy.mode' "$T/applied.yaml" | grep -q 'observation' || false
    grep -q 'rollout status deployment/devzone-workspace-egress-proxy' "$T/kubectl.log" || false
}

@test "egress strict: memorised, filtered sessions only, the workspace stays open" {
    argo_on
    run bash "$CLI" workspace egress strict </dev/null
    [ "$status" -eq 0 ]
    grep -qx 'egress=strict' "$R/.devzone.modules" || false
    grep -A1 'name: egressProxy.mode' "$T/applied.yaml" | grep -q 'strict' || false
    [[ "$output" == *"only the devzone agent sessions started with --pod are filtered"* ]] || false
    [[ "$output" == *"the workspace stays open"* ]] || false
}

@test "egress off: memorised, no proxy parameter, no wait" {
    argo_on
    printf 'egress=strict\n' >>"$R/.devzone.modules"
    run bash "$CLI" workspace egress off </dev/null
    [ "$status" -eq 0 ]
    grep -qx 'egress=off' "$R/.devzone.modules" || false
    if grep -q 'egressProxy.enabled' "$T/applied.yaml"; then false; fi
    if grep -q 'rollout status' "$T/kubectl.log"; then false; fi
}

@test "egress: without Argo CD Application the setting is kept, nothing is deployed" {
    run bash "$CLI" workspace egress strict </dev/null
    [ "$status" -eq 0 ]
    grep -qx 'egress=strict' "$R/.devzone.modules" || false
    [[ "$output" == *"devzone workspace start applies it"* ]] || false
    no_proxy_write
    [ ! -s "$T/helm.log" ] || false
}

@test "egress: proxy not ready after 120 s, the setting stays memorised" {
    argo_on
    export FAKE_ROLLOUT_FAIL=1
    run bash "$CLI" workspace egress strict </dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"not ready after 120 s"* ]] || false
    grep -qx 'egress=strict' "$R/.devzone.modules" || false
}

@test "egress: cluster unreachable refused before any write" {
    argo_on
    export FAKE_CLUSTER_DOWN=1
    run bash "$CLI" workspace egress strict </dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"✖"* ]] || false
    if grep -q '^egress=' "$R/.devzone.modules"; then false; fi
}

@test "egress: unknown or missing argument refused" {
    run bash "$CLI" workspace egress foo </dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown egress argument: foo"* ]] || false
    run bash "$CLI" workspace egress </dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown egress argument: none"* ]] || false
}

@test "egress allow: invalid domains refused, nothing written" {
    for bad in "Bad.Example.com" "a,b.example.com" "*.example.com" "a/b.example.com" "nodot" "a b.example.com" "a..example.com"; do
        run bash "$CLI" workspace egress allow "$bad" </dev/null
        [ "$status" -eq 1 ] || { echo "accepted: $bad"; false; }
        [[ "$output" == *"domain not valid"* ]] || false
    done
    if grep -q '^egress_domains=' "$R/.devzone.modules"; then false; fi
}

@test "egress allow: a valid domain, once only, replayed on the Application" {
    argo_on
    printf 'egress=strict\n' >>"$R/.devzone.modules"
    run bash "$CLI" workspace egress allow api.example.com </dev/null
    [ "$status" -eq 0 ]
    grep -qx 'egress_domains=api.example.com' "$R/.devzone.modules" || false
    grep -q 'api.example.com' "$T/applied.yaml" || false
    run bash "$CLI" workspace egress allow api.example.com </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"already allowed"* ]] || false
    [ "$(grep -c '^egress_domains=' "$R/.devzone.modules")" -eq 1 ] || false
    run bash "$CLI" workspace egress allow .cdn.example.org </dev/null
    [ "$status" -eq 0 ]
    grep -qx 'egress_domains=api.example.com,.cdn.example.org' "$R/.devzone.modules" || false
}

@test "egress deny: removes an added domain only, refuses the base list and unknown domains" {
    printf 'egress_domains=a.example.com,b.example.org\n' >>"$R/.devzone.modules"
    run bash "$CLI" workspace egress deny a.example.com </dev/null
    [ "$status" -eq 0 ]
    grep -qx 'egress_domains=b.example.org' "$R/.devzone.modules" || false
    run bash "$CLI" workspace egress deny a.example.com </dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"was not added"* ]] || false
    run bash "$CLI" workspace egress deny .github.com </dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"egressProxy.allowedDomains"* ]] || false
    grep -qx 'egress_domains=b.example.org' "$R/.devzone.modules" || false
    run bash "$CLI" workspace egress deny b.example.org </dev/null
    [ "$status" -eq 0 ]
    grep -qx 'egress_domains=' "$R/.devzone.modules" || false
}

@test "egress allow: a base domain is already allowed, nothing added" {
    run bash "$CLI" workspace egress allow .npmjs.org </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"base list"* ]] || false
    if grep -q '^egress_domains=' "$R/.devzone.modules"; then false; fi
}

@test "egress status: domains contacted from the access log, CONNECT only, with state" {
    export FAKE_EGRESS_MODE=strict FAKE_PROXY_READY=1
    printf '    acl allowed dstdomain .opencode.ai\n    acl allowed dstdomain .npmjs.org\n    acl allowed dstdomain .github.com\n' >"$T/squid.conf"
    cat >"$T/access.log" <<'LOG'
1700000000.000 5 10.0.0.1 TCP_TUNNEL/200 1234 CONNECT .opencode.ai:443 - HIER_DIRECT/1.2.3.4 -
1700000001.000 5 10.0.0.1 TCP_TUNNEL/200 1234 CONNECT .opencode.ai:443 - HIER_DIRECT/1.2.3.4 -
1700000002.000 0 10.0.0.1 TCP_DENIED/403 3456 CONNECT evil.example.net:443 - HIER_NONE/- text/html
1700000003.000 5 10.0.0.1 TCP_TUNNEL/200 1234 CONNECT registry.npmjs.org:443 - HIER_DIRECT/1.2.3.4 -
1700000004.000 5 10.0.0.1 TCP_MISS/200 1234 GET http://plain.example.org/ - HIER_DIRECT/1.2.3.4 text/html
LOG
    run bash "$CLI" workspace egress status </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"egress strict, proxy ready, allowed domains: 3"* ]] || false
    [[ "$output" == *".opencode.ai"*"2  allowed"* ]] || false
    [[ "$output" == *"evil.example.net"*"1  refused"* ]] || false
    [[ "$output" == *"registry.npmjs.org"*"1  allowed"* ]] || false
    [[ "$output" != *"plain.example.org"* ]] || false
    export FAKE_EGRESS_MODE=observation
    run bash "$CLI" workspace egress status </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *".opencode.ai"*"2  observed"* ]] || false
}

@test "egress status: no proxy, egress off" {
    run bash "$CLI" workspace egress status </dev/null
    [ "$status" -eq 0 ]
    [ "$output" = "egress off" ] || false
}

@test "egress: a start replays the mode and the added domains to helm direct" {
    printf 'egress=strict\negress_domains=a.example.com,b.example.org\n' >>"$R/.devzone.modules"
    ws_call workspace_deploy ghcr.io/simbienvenuehoulboumi/devzone-workspace 0.48.0 ""
    grep -q -F 'egressProxy.enabled=true' "$T/helm.log" || false
    grep -q -F 'egressProxy.mode=strict' "$T/helm.log" || false
    grep -q -F 'egressProxy.extraDomains=a.example.com\,b.example.org' "$T/helm.log" || false
}

@test "egress: an update keeps the setting in helm direct and with Argo CD" {
    printf 'egress=observation\n' >>"$R/.devzone.modules"
    run bash "$CLI" workspace update --version 0.48.0 --yes </dev/null
    [ "$status" -eq 0 ]
    grep -q -F 'egressProxy.mode=observation' "$T/helm.log" || false
    argo_on
    printf 'egress=strict\n' >>"$R/.devzone.modules"
    printf 'v0.47.0 0.47.0' >"$T/app-current"
    run bash "$CLI" workspace update --version 0.48.0 --yes </dev/null
    [ "$status" -eq 0 ]
    grep -A1 'name: egressProxy.mode' "$T/applied.yaml" | grep -q 'strict' || false
    grep -A1 'name: image.tag' "$T/applied.yaml" | grep -q 'value: "0.48.0"' || false
}

@test "egress: no setting, no egress parameter on start" {
    ws_call workspace_deploy ghcr.io/simbienvenuehoulboumi/devzone-workspace 0.48.0 ""
    no_proxy_write
}

@test "egress: listed in the help of workspace" {
    run bash "$CLI" workspace --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"egress observation|strict|off|status|allow <domain>|deny <domain>"* ]] || false
}
