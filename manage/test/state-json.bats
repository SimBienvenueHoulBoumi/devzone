#!/usr/bin/env bats
# Machine output devzone status --json (#308)

setup() {
    load commun
    kube_isole
    kind_vide
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/racine/workspace"
    export DEVZONE_ROOT="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_STATE="$BATS_TEST_TMPDIR/modules"
    : >"$DEVZONE_STATE"
    export GIT_CONFIG_NOSYSTEM=1
    cd "$BATS_TEST_TMPDIR" || return 1

    # no default git user name/email
    # fake kubectl
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
case "$*" in
    "config current-context") echo "docker-desktop" ;;
    *) exit 1 ;;
esac
KUBECTL
    # fake gh
    cat >"$BATS_TEST_TMPDIR/bin/gh" <<'GH'
#!/usr/bin/env bash
case "${GH_ETAT:-absent}" in
    absent) echo "You are not logged into any GitHub hosts." >&2; exit 1 ;;
    without) echo "  - Token scopes: 'gist', 'read:org', 'repo'" ;;
    with) echo "  - Token scopes: 'gist', 'read:org', 'repo', 'workflow'" ;;
esac
GH
    # fake docker
    mkdir -p "$BATS_TEST_TMPDIR/relais"
    cat >"$BATS_TEST_TMPDIR/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
case "${1:-}" in
    ps)
        show_all=0; motif=""
        prec=""
        for a in "$@"; do
            [ "$a" = "-a" ] && show_all=1
            [ "$prec" = --filter ] && motif="$a"
            prec="$a"
        done
        for f in "$T"/relais/*; do
            [ -e "$f" ] || continue
            nom="$(basename "$f")"
            m="${motif#name=^}"
            m="${m%$}"
            if [ "$nom" = "$m" ]; then echo "$nom"; fi
        done
        ;;
esac
exit 0
DOCKER
    # fake curl
    cat >"$BATS_TEST_TMPDIR/bin/curl" <<'CURL'
#!/usr/bin/env bash
for p in ${FAUX_REPOND:-}; do
    case "$*" in *":$p"*) exit 0 ;; esac
done
exit 7
CURL
    cat >"$BATS_TEST_TMPDIR/bin/devzone" <<'DEVZONE'
#!/usr/bin/env bash
case "$*" in
    "cluster clean"*) exit 0 ;;
    "account token")
        if [ -f "$BATS_TEST_TMPDIR/token.fail" ]; then exit 1; fi
        printf '%s\n' 1893456000 >"$BATS_TEST_TMPDIR/expiry"
        echo "kubectl create token devzone-agent -n devzone-system --duration=24h" >>"$BATS_TEST_TMPDIR/kubectl.log"
        ;;
    "account fresh")
        expiry="$(cat "$BATS_TEST_TMPDIR/expiry" 2>/dev/null || echo 0)"
        case "$expiry" in
            ""|*[!0-9]*) exit 1 ;;
        esac
        if [ "$expiry" -gt "$(date +%s)" ]; then exit 0; fi
        exit 1
        ;;
esac
exit 0
DEVZONE
    chmod +x "$BATS_TEST_TMPDIR/bin/"*
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# Fake kubectl for the limited token (#845): a working renewal unless the
# token.fail marker exists; it replaces the default failing fake of setup.
kubectl_jeton() {
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"$BATS_TEST_TMPDIR/kubectl.log"
case "$*" in
    *"config get-contexts -o name"*) echo "kind-devzone" ;;
    *"config current-context"*) echo "kind-devzone" ;;
    *"config view"*)
        case "$*" in
            *'.context.cluster'*) echo cluster-hote ;;
            *'.cluster.server'*) echo "https://127.0.0.1:6443" ;;
        esac
        ;;
    *"config use-context"*) ;;
    *"config set-cluster"* | *"config set "* | *"config set-credentials"* | *"config set-context"*) ;;
    *"auth can-i"*) echo yes ;;
    *"create token"*)
        [ -f "$BATS_TEST_TMPDIR/token.fail" ] && exit 1
        printf 'token-test\n2030-01-01T00:00:00Z\n'
        ;;
    *"create namespace"*) printf 'kind: Namespace\nmetadata:\n  name: devzone-system\n' ;;
    *"create serviceaccount"*) printf 'kind: ServiceAccount\nmetadata:\n  name: devzone-agent\n' ;;
    *"create rolebinding"*) printf 'kind: RoleBinding\nmetadata:\n  name: devzone-agent\n' ;;
    *"get namespaces -l"*) ;;
    *"apply -f -"*) cat >/dev/null ;;
    *) exit 1 ;;
esac
exit 0
KUBE
    chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
}

@test "state-json: schema 2 and valid JSON" {
    run bash "$DEVZONE" status --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | jq -e . >/dev/null
    [ "$(printf '%s\n' "$output" | jq -r '.schema')" = "3" ]
}

@test "state-json: git identity absent → ok false with command" {
    run bash "$DEVZONE" status --json
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | jq -r '.git_identity.ok')" = "false" ]
    [ "$(printf '%s\n' "$output" | jq -r '.git_identity.command')" != "null" ]
}

@test "state-json: git identity present" {
    # non-ASCII name written with octal escapes (UTF-8 e-acute = \303\251), so the source stays ASCII
    nom=$'Nom Accent\303\251 "X"'
    git config --global user.name "$nom" 2>/dev/null || true
    git config --global user.email "a@b.invalid" 2>/dev/null || true
    run bash "$DEVZONE" status --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | jq -e . >/dev/null
    [ "$(printf '%s\n' "$output" | jq -r '.git_identity.name')" = "$nom" ]
}

@test "state-json: module failed → echec and command" {
    printf 'ai=on\n' >"$DEVZONE_STATE"
    echo "failed npm" >"$DEVZONE_STATE-failed-ai"
    run bash "$DEVZONE" status --json
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | jq -r '.modules[] | select(.name=="ai") | .failed')" = "failed npm" ]
    [ "$(printf '%s\n' "$output" | jq -r '.modules[] | select(.name=="ai") | .command')" = "devzone apply" ]
}

@test "state-json: expired limited account token renewed without an alert" {
    printf 'cluster=kind-devzone\n' >"$DEVZONE_STATE"
    export DEVZONE_KUBE_TOKEN_EXPIRY="$BATS_TEST_TMPDIR/expiry"
    printf '%s\n' "$(( $(date +%s) - 10 ))" >"$DEVZONE_KUBE_TOKEN_EXPIRY"
    kubectl_jeton
    run bash "$DEVZONE" status --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | jq -e '.alerts | map(select(.command == "devzone repair")) | length == 0' >/dev/null
    grep -q 'create token' "$BATS_TEST_TMPDIR/kubectl.log"
    [ "$(cat "$DEVZONE_KUBE_TOKEN_EXPIRY")" = 1893456000 ]
}

@test "state-json: failed limited account token renewal → alert with devzone repair" {
    printf 'cluster=kind-devzone\n' >"$DEVZONE_STATE"
    export DEVZONE_KUBE_TOKEN_EXPIRY="$BATS_TEST_TMPDIR/expiry"
    printf '%s\n' "$(( $(date +%s) - 10 ))" >"$DEVZONE_KUBE_TOKEN_EXPIRY"
    kubectl_jeton
    : >"$BATS_TEST_TMPDIR/token.fail"
    run bash "$DEVZONE" status --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | jq -e '.alerts[] | select(.code == "limited_account_token" and .message == "limited account token expired" and .command == "devzone repair")' >/dev/null
}

@test "state-json: gh failing → github null and errors.github" {
    GH_ETAT=absent run bash "$DEVZONE" status --json
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | jq -r '.platform.github')" = "null" ]
    [ "$(printf '%s\n' "$output" | jq -r '.errors.github')" != "null" ]
}

@test "state-json: open port → in ports" {
    printf 'ports=8080\n' >"$DEVZONE_STATE"
    : >"$BATS_TEST_TMPDIR/relais/devzone-devzone-port-8080"
    FAUX_REPOND=8080 run bash "$DEVZONE" status --json
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | jq -r '.ports[] | select(.port==8080) | .port')" = "8080" ]
}

@test "state-json: no secret in the output" {
    printf 'secret-sentinel-123\n' >"$DEVZONE_ROOT/.password"
    cat >"$BATS_TEST_TMPDIR/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "token secret-gh-456" >&2
exit 1
GH
    chmod +x "$BATS_TEST_TMPDIR/bin/gh"
    run bash "$DEVZONE" status --json
    [ "$status" -eq 0 ]
    [[ "$output" != *"secret-sentinel-123"* ]] || false
    [[ "$output" != *"secret-gh-456"* ]] || false
}

@test "state-json: argocd_repo field: the designated GitOps repository" {
    printf '[argocd]\n    repo = https://github.com/tester/devzone-argocd.git\n' >"$DEVZONE_ROOT/.argocd.conf"
    run bash "$DEVZONE" status --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | jq -e . >/dev/null
    [ "$(printf '%s\n' "$output" | jq -r '.argocd_repo')" = "https://github.com/tester/devzone-argocd.git" ]
}

@test "state-json: argocd_repo field: no GitOps repository → null" {
    run bash "$DEVZONE" status --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | jq -e . >/dev/null
    [ "$(printf '%s\n' "$output" | jq -r '.argocd_repo')" = "null" ]
}

@test "state-json: text unchanged (devzone without --json)" {
    run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"devzone: state"* ]] || false
}

@test "state-json: the AI module is named ai, never ia" {
    run bash "$DEVZONE" status --json
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | jq -r '[.modules[] | select(.name=="ai")] | length')" = "1" ]
    [ "$(printf '%s\n' "$output" | jq -r '[.modules[] | select(.name=="ia")] | length')" = "0" ]
}
