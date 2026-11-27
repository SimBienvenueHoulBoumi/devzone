#!/usr/bin/env bats
# Workstation commands for the Kubernetes workspace (#398). Fake helm and kubectl
# in $BATS_TEST_TMPDIR/bin: no cluster is touched. The Go binary is built once
# for the file: the shell start path calls it for the wait and the guard, and the
# status branch calls it for a command already ported.

setup() {
    load commun
    devzone_go_pret
    kube_isole
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CLI="$ROOT/manage/devzone"
    T="$BATS_TEST_TMPDIR"
    mkdir -p "$T/bin"
    cat >"$T/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
echo "kubectl $*" >>"$T/kubectl.log"
case "$*" in
    "config get-contexts -o name")
        for c in ${FAKE_CONTEXTS:-docker-desktop}; do
            [ -n "$c" ] && echo "$c"
        done
        ;;
    "config current-context")
        echo "${FAKE_CURRENT_CONTEXT:-docker-desktop}"
        ;;
    *"cluster-info"*)
        [ "${FAKE_KUBE_CLUSTER_INFO:-ok}" = ok ]
        exit $?
        ;;
    *"get statefulset devzone-workspace "*)
        echo "${FAKE_REVISION:-rev-1}"
        ;;
    *"get pod devzone-workspace-0 "*controller-revision-hash*)
        if [ -n "${FAKE_POD_REVISIONS:-}" ]; then
            read -r -a revisions <<<"$FAKE_POD_REVISIONS"
            index=0
            [ -f "$T/pod-revision.count" ] && index="$(cat "$T/pod-revision.count")"
            [ "$index" -ge "${#revisions[@]}" ] && index=$((${#revisions[@]} - 1))
            echo "${revisions[$index]}"
            echo "$index" >"$T/pod-revision.index"
            echo "$((index + 1))" >"$T/pod-revision.count"
        else
            echo "${FAKE_REVISION:-rev-1}"
        fi
        ;;
    *"get pod devzone-workspace-0 "*)
        if [ -n "${FAKE_POD_STATES:-}" ]; then
            read -r -a states <<<"$FAKE_POD_STATES"
            index=0
            [ -f "$T/pod-revision.index" ] && index="$(cat "$T/pod-revision.index")"
            [ "$index" -ge "${#states[@]}" ] && index=$((${#states[@]} - 1))
            echo "${states[$index]}"
        else
            echo "${FAKE_POD:-Running}"
        fi
        ;;
    *"get events "*)
        echo "${FAKE_EVENTS:-}"
        ;;
    *"get nodes "*)
        echo "${FAKE_ARCH:-arm64}"
        ;;
    *"get namespace devzone-argocd"*) [ -n "${FAUX_ARGOCD:-}" ]; exit $? ;;
    *"get application.argoproj.io devzone-workspace"*) [ -n "${FAUX_APP:-}" ]; exit $? ;;
esac
exit 0
KUBE
    cat >"$T/bin/helm" <<'HELM'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
echo "helm $*" >>"$T/helm.log"
exit 0
HELM
    # Fake docker (#565): Docker Desktop stopped when FAKE_DOCKER=down; never the real one
    cat >"$T/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
echo "docker $*" >>"$BATS_TEST_TMPDIR/docker.log"
[ "${FAKE_DOCKER:-up}" = up ]
DOCKER
    chmod +x "$T/bin/kubectl" "$T/bin/helm" "$T/bin/docker"
    export PATH="$T/bin:$PATH"
    export DEVZONE_WORKSPACE_WAIT=1 DEVZONE_WORKSPACE_STEP=0.1
    # Devzone folder of the workstation: its state, never the real one; Argo CD
    # off here (its own tests: workspace-argocd.bats, #516)
    cd "$T" || return 1
    printf 'workspace=kubernetes\nargocd=off\n' >"$T/.devzone.modules"
}

@test "workspace start: helm upgrade --install with devzone context when it exists" {
    export FAKE_CONTEXTS="devzone docker-desktop"
    : >"$T/helm.log"
    run bash "$CLI" workspace start
    [ "$status" -eq 0 ]
    grep -q -- "--kube-context devzone" "$T/helm.log" || false
    grep -q -- "upgrade --install devzone-workspace" "$T/helm.log" || false
    grep -q "charts/devzone-workspace" "$T/helm.log" || false
    grep -q -- "--namespace devzone-workspace" "$T/helm.log" || false
}

@test "workspace start: cluster stopped (Docker Desktop), one message, no helm, no Argo CD" {
    export FAKE_KUBE_CLUSTER_INFO=fail FAKE_DOCKER=down FAKE_CONTEXTS=docker-desktop
    export FAKE_CURRENT_CONTEXT=docker-desktop
    : >"$T/helm.log"
    : >"$T/kubectl.log"
    run bash "$CLI" workspace start
    [ "$status" -eq 1 ]
    [[ "$output" == *"✖ Kubernetes cluster"*"unreachable"* ]] || false
    [[ "$output" == *"Check the contexts: kubectl config get-contexts"* ]] || false
    [ "$(grep -c '^✖' <<<"$output")" -eq 1 ]
    [[ "$output" != *"helm directly"* ]] || false
    [ ! -s "$T/helm.log" ]
    ! grep -q 'namespace\|get pod\|apply\|get statefulset' "$T/kubectl.log" || false
}

@test "workspace start: current context when devzone is missing" {
    export FAKE_CONTEXTS="docker-desktop"
    export FAKE_CURRENT_CONTEXT="docker-desktop"
    : >"$T/helm.log"
    run bash "$CLI" workspace start
    [ "$status" -eq 0 ]
    ! grep -q -- "--kube-context" "$T/helm.log" || false
    grep -q -- "upgrade --install devzone-workspace" "$T/helm.log" || false
}

@test "workspace stop: helm uninstall" {
    export FAKE_CONTEXTS="devzone docker-desktop"
    : >"$T/helm.log"
    run bash "$CLI" workspace stop
    [ "$status" -eq 0 ]
    grep -q -- "--kube-context devzone" "$T/helm.log" || false
    grep -q -- "uninstall devzone-workspace" "$T/helm.log" || false
}

@test "workspace status: kubectl get pods" {
    export FAKE_CONTEXTS="docker-desktop"
    export FAKE_CURRENT_CONTEXT="docker-desktop"
    : >"$T/kubectl.log"
    run bash "$CLI" workspace status
    [ "$status" -eq 0 ]
    grep -q -- "get pods" "$T/kubectl.log" || false
    grep -q -- "--namespace devzone-workspace" "$T/kubectl.log" || false
}

@test "workspace shell: kubectl exec in workspace container" {
    export FAKE_CONTEXTS="devzone docker-desktop"
    : >"$T/kubectl.log"
    run bash "$CLI" workspace shell
    [ "$status" -eq 0 ]
    grep -q -- "exec -it devzone-workspace-0" "$T/kubectl.log" || false
    grep -q -- "-c workspace" "$T/kubectl.log" || false
}

@test "workspace help: lists all subcommands" {
    run bash "$CLI" workspace
    [ "$status" -eq 0 ]
    [[ "$output" == *"start|stop|status|shell|ports"* ]] || false
}

@test "workspace start: without option, latest tag (package.json at 0.0.0)" {
    export FAKE_CONTEXTS="docker-desktop"
    export FAKE_CURRENT_CONTEXT="docker-desktop"
    : >"$T/helm.log"
    run bash "$CLI" workspace start
    [ "$status" -eq 0 ]
    grep -q -- "--set image.tag=latest" "$T/helm.log" || false
    # latest is always pulled again (#515)
    grep -q -- "--set image.pullPolicy=Always" "$T/helm.log" || false
}

@test "workspace start: --image repo:tag passes repository and tag" {
    export FAKE_CONTEXTS="docker-desktop"
    : >"$T/helm.log"
    run bash "$CLI" workspace start --image registry.local/ws:trial
    [ "$status" -eq 0 ]
    grep -q -- "--set image.repository=registry.local/ws" "$T/helm.log" || false
    grep -q -- "--set image.tag=trial" "$T/helm.log" || false
    # a fixed tag keeps the chart pull policy (#515)
    ! grep -q -- "image.pullPolicy=Always" "$T/helm.log" || false
}

@test "workspace start: image not found, message and uninstall" {
    export FAKE_CONTEXTS="docker-desktop"
    export FAKE_POD="Pending ImagePullBackOff"
    : >"$T/helm.log"
    run bash "$CLI" workspace start
    [ "$status" -eq 1 ]
    [[ "$output" == *"not found"* ]] || false
    [[ "$output" == *"--image"* ]] || false
    grep -q -- "uninstall devzone-workspace" "$T/helm.log" || false
}

@test "workspace start: image without build for node architecture" {
    export FAKE_CONTEXTS="docker-desktop"
    export FAKE_POD="Pending ImagePullBackOff"
    export FAKE_EVENTS="failed to resolve reference : no match for platform in manifest list"
    export FAKE_ARCH="arm64"
    : >"$T/helm.log"
    run bash "$CLI" workspace start
    [ "$status" -eq 1 ]
    [[ "$output" == *"no build for arm64"* ]] || false
    [[ "$output" != *"not found"* ]] || false
    [[ "$output" == *"amd64 and arm64"* ]] || false
    grep -q -- "uninstall devzone-workspace" "$T/helm.log" || false
}

@test "workspace start: old pod Running then new revision in ImagePullBackOff" {
    export FAKE_CONTEXTS="docker-desktop"
    export FAKE_REVISION="rev-new"
    export FAKE_POD_REVISIONS="rev-old rev-new"
    # Two polling rounds at least: 1 s is too short on a loaded CI runner (#522)
    export DEVZONE_WORKSPACE_WAIT=10
    export FAKE_POD_STATES="Running ImagePullBackOff"
    : >"$T/helm.log"
    run bash "$CLI" workspace start
    [ "$status" -eq 1 ]
    [[ "$output" == *"not found"* ]] || false
    grep -q -- "uninstall devzone-workspace" "$T/helm.log" || false
}

@test "workspace start: old pod ErrImagePull then new revision Running" {
    export FAKE_CONTEXTS="docker-desktop"
    export FAKE_REVISION="rev-new"
    export FAKE_POD_REVISIONS="rev-old rev-new"
    # Two polling rounds at least: 1 s is too short on a loaded CI runner (#522)
    export DEVZONE_WORKSPACE_WAIT=10
    export FAKE_POD_STATES="ErrImagePull Running"
    : >"$T/helm.log"
    run bash "$CLI" workspace start
    [ "$status" -eq 0 ]
    [[ "$output" == *"✔ workspace started"* ]] || false
    ! grep -q -- "uninstall devzone-workspace" "$T/helm.log" || false
}

@test "workspace start: --image without value, usage and no helm" {
    export FAKE_CONTEXTS="docker-desktop"
    : >"$T/helm.log"
    run bash "$CLI" workspace start --image
    [ "$status" -eq 1 ]
    ! grep -q upgrade "$T/helm.log" || false
}

@test "chart: helm lint and helm template" {
    command -v helm >/dev/null 2>&1 || skip "helm missing"
    run helm lint "$ROOT/charts/devzone-workspace"
    [ "$status" -eq 0 ]
    run helm template devzone-workspace "$ROOT/charts/devzone-workspace" --namespace devzone-workspace
    [ "$status" -eq 0 ]
}
