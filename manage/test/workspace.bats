#!/usr/bin/env bats
# Workstation commands for the Kubernetes workspace (#398). Fake helm and kubectl
# in $BATS_TEST_TMPDIR/bin: no cluster is touched.

setup() {
    load commun
    relais_docker_isole
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
esac
exit 0
KUBE
    cat >"$T/bin/helm" <<'HELM'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
echo "helm $*" >>"$T/helm.log"
exit 0
HELM
    chmod +x "$T/bin/kubectl" "$T/bin/helm"
    export PATH="$T/bin:$PATH"
    export DEVZONE_WORKSPACE_ATTENTE=1 DEVZONE_WORKSPACE_PAS=0.1
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

@test "workspace start and demarrer are equivalent" {
    export FAKE_CONTEXTS="devzone docker-desktop"
    : >"$T/helm.log"
    run bash "$CLI" workspace start
    [ "$status" -eq 0 ]
    cp "$T/helm.log" "$T/start.log"
    : >"$T/helm.log"
    run bash "$CLI" workspace demarrer
    [ "$status" -eq 0 ]
    [ "$(cat "$T/helm.log")" = "$(cat "$T/start.log")" ]
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

@test "workspace copy-to: kubectl cp from workstation to /workspaces/projets in pod" {
    export FAKE_CONTEXTS="devzone docker-desktop"
    mkdir -p "$T/my-project"
    : >"$T/kubectl.log"
    run bash "$CLI" workspace copy-to "$T/my-project"
    [ "$status" -eq 0 ]
    grep -q -- "cp $T/my-project devzone-workspace-0:/workspaces/projets/my-project" "$T/kubectl.log" || false
    grep -q -- "--context devzone" "$T/kubectl.log" || false
    grep -q -- "--namespace devzone-workspace" "$T/kubectl.log" || false
    grep -q -- "-c workspace" "$T/kubectl.log" || false
}

@test "workspace copy-to: without folder, usage and no kubectl" {
    export FAKE_CONTEXTS="devzone docker-desktop"
    : >"$T/kubectl.log"
    run bash "$CLI" workspace copy-to
    [ "$status" -eq 1 ]
    [[ "$output" == *"devzone workspace copy-to <folder>"* ]] || false
    [ ! -s "$T/kubectl.log" ]
}

@test "workspace copy-to: missing folder, no kubectl" {
    export FAKE_CONTEXTS="devzone docker-desktop"
    : >"$T/kubectl.log"
    run bash "$CLI" workspace copy-to "$T/missing"
    [ "$status" -eq 1 ]
    [[ "$output" == *"folder not found"* ]] || false
    [ ! -s "$T/kubectl.log" ]
}

@test "workspace copy-from: kubectl cp from /workspaces/projets to workstation" {
    export FAKE_CONTEXTS="devzone docker-desktop"
    : >"$T/kubectl.log"
    run bash "$CLI" workspace copy-from "$T/recovery/my-project"
    [ "$status" -eq 0 ]
    grep -q -- "cp devzone-workspace-0:/workspaces/projets/my-project $T/recovery/my-project" "$T/kubectl.log" || false
    grep -q -- "--context devzone" "$T/kubectl.log" || false
    grep -q -- "--namespace devzone-workspace" "$T/kubectl.log" || false
    grep -q -- "-c workspace" "$T/kubectl.log" || false
}

@test "workspace copy-from .: project gets current folder name" {
    export FAKE_CONTEXTS="devzone docker-desktop"
    mkdir -p "$T/cwd-project"
    cd "$T/cwd-project"
    : >"$T/kubectl.log"
    run bash "$CLI" workspace copy-from .
    [ "$status" -eq 0 ]
    grep -q -- "cp devzone-workspace-0:/workspaces/projets/cwd-project $T/cwd-project" "$T/kubectl.log" || false
    ! grep -q -- "projets/\.$" "$T/kubectl.log" || false
}

@test "workspace copy-from: without folder, usage and no kubectl" {
    export FAKE_CONTEXTS="devzone docker-desktop"
    : >"$T/kubectl.log"
    run bash "$CLI" workspace copy-from
    [ "$status" -eq 1 ]
    [[ "$output" == *"devzone workspace copy-from <folder>"* ]] || false
    [ ! -s "$T/kubectl.log" ]
}

@test "workspace vscode: steps (context, namespace, pod, folder)" {
    run bash "$CLI" workspace vscode
    [ "$status" -eq 0 ]
    [[ "$output" == *"kubectl context: devzone"* ]] || false
    [[ "$output" == *"pod devzone-workspace-0"* ]] || false
    [[ "$output" == *"Attach to Running Kubernetes Container"* ]] || false
    [[ "$output" == *"/workspaces/projets"* ]] || false
    [[ "$output" == *"devzone workspace status"* ]] || false
    # No devzone variable shown to the user (#341)
    ! grep -q "DEVZONE_" <<<"$output" || false
}

@test "workspace help: lists all subcommands" {
    run bash "$CLI" workspace
    [ "$status" -eq 0 ]
    [[ "$output" == *"start|stop|status|shell|vscode|copy-to|copy-from"* ]] || false
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
    export DEVZONE_WORKSPACE_ATTENTE=10
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
    export DEVZONE_WORKSPACE_ATTENTE=10
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
