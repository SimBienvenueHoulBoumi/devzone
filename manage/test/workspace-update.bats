#!/usr/bin/env bats
# devzone workspace update (#622): latest stable release from the tags, image
# checked on ghcr.io before any write, confirmation, then the same deployment
# as workspace start. Fake git, curl, kubectl, helm and gh in
# $BATS_TEST_TMPDIR/bin: no cluster, no registry and no network is touched.

setup() {
    load commun
    kube_isole
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CLI="$RACINE/manage/devzone"
    T="$BATS_TEST_TMPDIR"
    REAL_GIT="$(command -v git)"
    export REAL_GIT
    mkdir -p "$T/bin" "$T/workspace"
    : >"$T/kubectl.log"
    : >"$T/helm.log"
    : >"$T/curl.log"
    : >"$T/git.log"
    # Stable releases, a pre-release and an old version (order by version, not text)
    printf '%s\t%s\n' 1111 refs/tags/v0.47.0 2222 refs/tags/v0.48.0 \
        3333 refs/tags/v0.48.0-next.1 4444 refs/tags/v0.9.0 >"$T/tags"
    cat >"$T/bin/git" <<'GIT'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
if [ "$1" = ls-remote ]; then
    echo "git $*" >>"$T/git.log"
    [ -z "${FAKE_GIT_FAIL:-}" ] || exit 128
    cat "$T/tags"
    exit 0
fi
exec "$REAL_GIT" "$@"
GIT
    # The URL is logged, never the Authorization header (it holds the token)
    cat >"$T/bin/curl" <<'CURL'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
url="${!#}"
echo "curl $url" >>"$T/curl.log"
case "$url" in
    *"/token?"*)
        [ -z "${FAKE_NO_TOKEN:-}" ] || exit 6
        echo '{"token":"SECRET-TOKEN-7F3A","access_token":"SECRET-TOKEN-7F3A"}'
        ;;
    *"/manifests/"*)
        tag="${url##*/manifests/}"
        case " ${FAKE_IMAGES:-} " in *" $tag "*) exit 0 ;; esac
        exit 22
        ;;
esac
exit 0
CURL
    cat >"$T/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
echo "kubectl $*" >>"$T/kubectl.log"
case "$*" in
    "config get-contexts -o name") echo docker-desktop ;;
    *"cluster-info"*) [ -z "${FAKE_CLUSTER_DOWN:-}" ]; exit $? ;;
    *"get namespace devzone-argocd"*) [ -f "$T/argocd-ns" ]; exit $? ;;
    *"get application.argoproj.io devzone-workspace -o jsonpath"*)
        [ -f "$T/app-current" ] && cat "$T/app-current"
        ;;
    *"apply -f -"*) cat >>"$T/applied.yaml" ;;
esac
exit 0
KUBE
    cat >"$T/bin/helm" <<'HELM'
#!/usr/bin/env bash
echo "helm $*" >>"$BATS_TEST_TMPDIR/helm.log"
exit 0
HELM
    # gh answers no: the GitOps repository is off, no network
    cat >"$T/bin/gh" <<'GH'
#!/usr/bin/env bash
exit 1
GH
    chmod +x "$T/bin/"*
    export PATH="$T/bin:$PATH"
    # Devzone folder of the workstation: Kubernetes workspace, Argo CD off by default
    cd "$T" || return 1
    printf 'workspace=kubernetes\nargocd=off\n' >"$T/.devzone.modules"
}

# Helm writes or Argo CD writes: nothing must have been applied
nothing_written() {
    [ ! -s "$T/helm.log" ] || return 1
    [ ! -s "$T/applied.yaml" ] || return 1
    ! grep -q -e 'apply -f' -e 'upgrade' "$T/kubectl.log" || false
}

@test "update: the latest stable release is chosen by version order, pre-releases and v0.9.0 ignored" {
    export FAKE_IMAGES="0.48.0"
    run bash "$CLI" workspace update --yes </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"workspace on v0.48.0"* ]] || false
    grep -q -- 'image.tag=0.48.0' "$T/helm.log"
    ! grep -q -- 'image.tag=0.9.0' "$T/helm.log" || false
}

@test "update --version 0.9.0: the given version is used, not the latest" {
    export FAKE_IMAGES="0.9.0"
    run bash "$CLI" workspace update --version 0.9.0 --yes </dev/null
    [ "$status" -eq 0 ]
    grep -q -- 'image.tag=0.9.0' "$T/helm.log"
    grep -q 'manifests/0.9.0' "$T/curl.log"
    ! grep -q 'image.tag=0.48.0' "$T/helm.log" || false
}

@test "update --version: anything but X.Y.Z refused, nothing written" {
    export FAKE_IMAGES="0.48.0"
    run bash "$CLI" workspace update --version v0.48.0 --yes </dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"expected X.Y.Z"* ]] || false
    nothing_written
}

@test "update: unknown option refused, nothing written" {
    run bash "$CLI" workspace update --force </dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown option: --force"* ]] || false
    nothing_written
}

@test "update: no stable release (only a pre-release, or no answer from the repository) refused with a clear message" {
    printf '%s\t%s\n' 3333 refs/tags/v0.48.0-next.1 >"$T/tags"
    run bash "$CLI" workspace update --yes </dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"no stable release found"* ]] || false
    nothing_written
    export FAKE_GIT_FAIL=1
    run bash "$CLI" workspace update --yes </dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"no stable release found"* ]] || false
    nothing_written
}

@test "update: image missing on ghcr.io refused before any write" {
    export FAKE_IMAGES=""
    run bash "$CLI" workspace update --yes </dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"image"*"not found on ghcr.io"* ]] || false
    [[ "$output" == *"nothing changed"* ]] || false
    nothing_written
}

@test "update: registry unreachable (no anonymous token) refused, nothing written" {
    export FAKE_IMAGES="0.48.0" FAKE_NO_TOKEN=1
    run bash "$CLI" workspace update --yes </dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"not found on ghcr.io"* ]] || false
    nothing_written
}

@test "update: already up to date, exit 0 and nothing written" {
    export FAKE_IMAGES="0.48.0"
    printf 'v0.48.0 0.48.0' >"$T/app-current"
    run bash "$CLI" workspace update --yes </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"already up to date: v0.48.0"* ]] || false
    nothing_written
}

@test "update: without terminal and without --yes refused, nothing written" {
    export FAKE_IMAGES="0.48.0"
    run bash "$CLI" workspace update </dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"no terminal to confirm"*"--yes"* ]] || false
    nothing_written
}

@test "update: cluster unreachable refused before any write" {
    export FAKE_IMAGES="0.48.0" FAKE_CLUSTER_DOWN=1
    run bash "$CLI" workspace update --yes </dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"✖"* ]] || false
    nothing_written
}

@test "update --yes with Argo CD: Application at revision v0.48.0 and image.tag 0.48.0, Argo CD path only" {
    export FAKE_IMAGES="0.48.0"
    printf 'workspace=kubernetes\nargocd=on\n' >"$T/.devzone.modules"
    printf '[argocd]\n    repo = none\n' >"$T/.argocd.conf"
    : >"$T/argocd-ns"
    run bash "$CLI" workspace update --yes </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"workspace on v0.48.0"* ]] || false
    grep -q 'targetRevision: v0.48.0' "$T/applied.yaml"
    grep -A1 'name: image.tag' "$T/applied.yaml" | grep -q 'value: "0.48.0"'
    ! grep -q -- 'upgrade --install devzone-workspace' "$T/helm.log" || false
}

@test "update --yes: the registry token never appears in the output or in the logs" {
    export FAKE_IMAGES="0.48.0"
    run bash "$CLI" workspace update --yes </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" != *"SECRET-TOKEN"* ]] || false
    ! grep -q 'SECRET-TOKEN' "$T"/*.log || false
}

@test "update: listed in the help of workspace" {
    run bash "$CLI" workspace --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"update [--version X.Y.Z] [--yes]"* ]] || false
}
