#!/usr/bin/env bats
# Kubernetes workspace without Docker: kubedock (Docker API) and rootless BuildKit,
# without privileged container (#410). Only helm lint and helm template: no
# cluster is touched, and real helm is used (no fake helm in PATH,
# unlike workspace.bats).

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CHART="$ROOT/charts/devzone-workspace"
    command -v helm >/dev/null 2>&1 || skip "helm missing"
}

# Full chart render, with given options.
render() {
    helm template t "$CHART" --namespace devzone-workspace "$@"
}

# Single template render (--show-only).
render_of() {
    local template="$1"
    shift
    helm template t "$CHART" --namespace devzone-workspace --show-only "$template" "$@"
}

# initContainers block (from keyword to containers), as rendered.
init_block() {
    awk '/^      initContainers:/{p=1} /^      containers:/{p=0} p' <<<"$1"
}

# containers block (from keyword to volumeClaimTemplates), as rendered.
containers_block() {
    awk '/^      containers:/{p=1} /^  volumeClaimTemplates:/{p=0} p' <<<"$1"
}

# initContainers container block, identified by its name.
sidecar_block() {
    awk -v name="$2" '
        /^        - name: /{ p = ($0 == name) }
        /^      containers:/{ p = 0 }
        p' <<<"$1"
}

@test "no-docker: helm lint of chart" {
    run helm lint "$CHART"
    [ "$status" -eq 0 ]
}

@test "security: no privileged container in render (default values)" {
    run render
    [ "$status" -eq 0 ]
    ! grep -q -- "privileged" <<<"$output" || false
}

@test "security: no privileged container with buildkit.unconfined=false" {
    run render --set buildkit.unconfined=false
    [ "$status" -eq 0 ]
    ! grep -q -- "privileged" <<<"$output" || false
}

@test "no-docker: no dind, no docker image, no docker PVC" {
    run render
    [ "$status" -eq 0 ]
    ! grep -q -- "dind" <<<"$output" || false
    ! grep -q -- "docker:27" <<<"$output" || false
    ! grep -q -- "/var/lib/docker" <<<"$output" || false
    ! grep -q -- "name: docker" <<<"$output" || false
}

@test "no-docker: StatefulSet has only workspace and state PVCs" {
    run render_of templates/statefulset.yaml
    [ "$status" -eq 0 ]
    local pvc
    pvc="$(awk '/^  volumeClaimTemplates:/{p=1} p && /^    - metadata:/{getline; print}' <<<"$output")"
    [ "$(wc -l <<<"$pvc" | tr -d ' ')" -eq 2 ]
    grep -q -- "name: workspace" <<<"$pvc" || false
    grep -q -- "name: etat" <<<"$pvc" || false
}

@test "kubedock: native sidecar, before workspace container, image 0.23.0" {
    run render_of templates/statefulset.yaml
    [ "$status" -eq 0 ]
    local kd
    kd="$(sidecar_block "$(init_block "$output")" "        - name: kubedock")"
    grep -q -- "image: joyrex2001/kubedock:0.23.0" <<<"$kd" || false
    grep -q -- "restartPolicy: Always" <<<"$kd" || false
    # A native sidecar is an initContainer: it does not appear in containers.
    ! grep -q -- "- name: kubedock" <<<"$(containers_block "$output")" || false
}

@test "kubedock: trial args (server --port-forward --reverse-proxy --timeout)" {
    run render_of templates/statefulset.yaml
    [ "$status" -eq 0 ]
    local kd
    kd="$(sidecar_block "$(init_block "$output")" "        - name: kubedock")"
    grep -q -- '- server' <<<"$kd" || false
    grep -q -- '- --port-forward' <<<"$kd" || false
    grep -q -- '- --reverse-proxy' <<<"$kd" || false
    grep -q -- '- --timeout' <<<"$kd" || false
    grep -q -- '- "5m"' <<<"$kd" || false
}

@test "kubedock: --timeout from kubedock.timeout (5m by default, first image pull)" {
    run render_of templates/statefulset.yaml
    [ "$status" -eq 0 ]
    local args
    args="$(awk '/^          args:/{p=1;next} p && /^          [a-z]/{exit} p' <<<"$(sidecar_block "$(init_block "$output")" "        - name: kubedock")" | sed 's/^ *- //' | paste -sd' ' -)"
    [ "$args" = 'server --port-forward --reverse-proxy --timeout "5m" --reapmax "30m" --prune-start' ]
    run render_of templates/statefulset.yaml --set kubedock.timeout=10m
    [ "$status" -eq 0 ]
    grep -q -- '- "10m"' <<<"$(sidecar_block "$(init_block "$output")" "        - name: kubedock")" || false
}

@test "kubedock: reapmax and prune-start configurable (#514)" {
    run render_of templates/statefulset.yaml
    [ "$status" -eq 0 ]
    local kd
    kd="$(sidecar_block "$(init_block "$output")" "        - name: kubedock")"
    grep -q -- '- --reapmax' <<<"$kd" || false
    grep -q -- '- "30m"' <<<"$kd" || false
    grep -q -- '- --prune-start' <<<"$kd" || false
    run render_of templates/statefulset.yaml --set kubedock.reapmax=0 --set kubedock.pruneStart=false
    [ "$status" -eq 0 ]
    kd="$(sidecar_block "$(init_block "$output")" "        - name: kubedock")"
    grep -q -- '- --reapmax' <<<"$kd" || false
    grep -q -- '- "0"' <<<"$kd" || false
    ! grep -q -- '- --prune-start' <<<"$kd" || false
}

@test "kubedock: NAMESPACE comes from pod metadata.namespace" {
    run render_of templates/statefulset.yaml
    [ "$status" -eq 0 ]
    local kd
    kd="$(sidecar_block "$(init_block "$output")" "        - name: kubedock")"
    grep -q -- "name: NAMESPACE" <<<"$kd" || false
    grep -q -- "fieldPath: metadata.namespace" <<<"$kd" || false
}

@test "kubedock: waits for port 2475 (startupProbe tcpSocket)" {
    run render_of templates/statefulset.yaml
    [ "$status" -eq 0 ]
    local kd
    kd="$(sidecar_block "$(init_block "$output")" "        - name: kubedock")"
    grep -q -- "tcpSocket:" <<<"$kd" || false
    grep -q -- "port: 2475" <<<"$kd" || false
}

@test "buildkit: rootless native sidecar, image pinned to rootless version" {
    run render_of templates/statefulset.yaml
    [ "$status" -eq 0 ]
    local bk
    bk="$(sidecar_block "$(init_block "$output")" "        - name: buildkitd")"
    grep -q -- "image: moby/buildkit:v0.34.2-rootless" <<<"$bk" || false
    grep -q -- "restartPolicy: Always" <<<"$bk" || false
    grep -q -- "runAsUser: 1000" <<<"$bk" || false
    grep -q -- "runAsGroup: 1000" <<<"$bk" || false
}

@test "buildkit: rootless args (no process sandbox, listens on 127.0.0.1:1234)" {
    run render_of templates/statefulset.yaml
    [ "$status" -eq 0 ]
    local bk
    bk="$(sidecar_block "$(init_block "$output")" "        - name: buildkitd")"
    grep -q -- "- --oci-worker-no-process-sandbox" <<<"$bk" || false
    grep -q -- "- --addr=tcp://127.0.0.1:1234" <<<"$bk" || false
    ! grep -q -- "0.0.0.0" <<<"$output" || false
}

@test "buildkit: seccomp and AppArmor Unconfined by default, removed if unconfined=false" {
    run render_of templates/statefulset.yaml
    [ "$status" -eq 0 ]
    local bk
    bk="$(sidecar_block "$(init_block "$output")" "        - name: buildkitd")"
    grep -q -- "seccompProfile:" <<<"$bk" || false
    grep -q -- "appArmorProfile:" <<<"$bk" || false
    [ "$(grep -c -- "type: Unconfined" <<<"$bk")" -eq 2 ]
    run render_of templates/statefulset.yaml --set buildkit.unconfined=false
    [ "$status" -eq 0 ]
    bk="$(sidecar_block "$(init_block "$output")" "        - name: buildkitd")"
    ! grep -q -- "Unconfined" <<<"$bk" || false
}

@test "buildkit: waits for buildctl debug workers (startupProbe)" {
    run render_of templates/statefulset.yaml
    [ "$status" -eq 0 ]
    local bk
    bk="$(sidecar_block "$(init_block "$output")" "        - name: buildkitd")"
    grep -q -- 'command: \["buildctl", "--addr", "tcp://127.0.0.1:1234", "debug", "workers"\]' <<<"$bk" || false
}

@test "variables: workspace talks to kubedock, BuildKit and disables Ryuk and checks" {
    run render_of templates/statefulset.yaml
    [ "$status" -eq 0 ]
    local main
    main="$(awk '/^        - name: workspace$/{p=1} /^          resources:/{p=0} p' <<<"$output")"
    grep -q -- "- name: DOCKER_HOST" <<<"$main" || false
    grep -q -- "value: tcp://127.0.0.1:2475" <<<"$main" || false
    grep -q -- "- name: TESTCONTAINERS_RYUK_DISABLED" <<<"$main" || false
    grep -q -- 'value: "true"' <<<"$main" || false
    grep -q -- "- name: TESTCONTAINERS_CHECKS_DISABLE" <<<"$main" || false
    grep -q -- "- name: BUILDKIT_HOST" <<<"$main" || false
    grep -q -- "value: tcp://127.0.0.1:1234" <<<"$main" || false
}

@test "workspace: command runs workspace-init.sh then never exits (#503)" {
    run render_of templates/statefulset.yaml
    [ "$status" -eq 0 ]
    local main
    main="$(awk '/^        - name: workspace$/{p=1} /^          resources:/{p=0} p' <<<"$output")"
    [[ "$main" == *"workspace-init.sh"* ]] || false
    [[ "$main" == *"sleep infinity"* ]] || false
}

@test "variables: workspace DEVZONE_ROOT and NPM_CONFIG_PREFIX (#503)" {
    run render_of templates/statefulset.yaml
    [ "$status" -eq 0 ]
    local main
    main="$(awk '/^        - name: workspace$/{p=1} /^          resources:/{p=0} p' <<<"$output")"
    grep -A1 -- "- name: DEVZONE_RACINE" <<<"$main" | grep -q -- "value: /workspaces/projets" || false
    grep -A1 -- "- name: NPM_CONFIG_PREFIX" <<<"$main" | grep -q -- "value: /home/vscode/.local/npm" || false
}

@test "variables: workspace PATH starts with global npm bin (#503)" {
    run render_of templates/statefulset.yaml
    [ "$status" -eq 0 ]
    local main line
    main="$(awk '/^        - name: workspace$/{p=1} /^          resources:/{p=0} p' <<<"$output")"
    line="$(grep -A1 -- "- name: PATH" <<<"$main" | tail -1)"
    [[ "$line" == *"value: /home/vscode/.local/npm/bin:"* ]] || false
}

@test "workspace: state mounts for .local/npm and .local/state/devzone (#503)" {
    run render_of templates/statefulset.yaml
    [ "$status" -eq 0 ]
    grep -q -- 'subPath: ".local/npm"' <<<"$output" || false
    grep -q -- 'mountPath: "/home/vscode/.local/npm"' <<<"$output" || false
    grep -q -- 'subPath: ".local/state/devzone"' <<<"$output" || false
    grep -q -- 'mountPath: "/home/vscode/.local/state/devzone"' <<<"$output" || false
}

@test "network: no declared port (no containerPort, no hostPort) and no exposed Docker API port" {
    run render
    [ "$status" -eq 0 ]
    ! grep -q -- "containerPort" <<<"$output" || false
    ! grep -q -- "hostPort" <<<"$output" || false
    run render_of templates/service.yaml
    [ "$status" -eq 0 ]
    ! grep -q -- "2475" <<<"$output" || false
    ! grep -q -- "1234" <<<"$output" || false
    run render_of templates/networkpolicy.yaml
    [ "$status" -eq 0 ]
    ! grep -q -- "2475" <<<"$output" || false
    ! grep -q -- "1234" <<<"$output" || false
}

@test "network: by default NetworkPolicy limits only ingress (no Egress)" {
    run render_of templates/networkpolicy.yaml
    [ "$status" -eq 0 ]
    grep -q -- "- Ingress" <<<"$output" || false
    ! grep -q -- "Egress" <<<"$output" || false
    ! grep -q -- "egress:" <<<"$output" || false
}

@test "network: restrictEgress=true adds Egress rule (namespace and DNS)" {
    run render_of templates/networkpolicy.yaml --set networkPolicy.restrictEgress=true
    [ "$status" -eq 0 ]
    grep -q -- "- Egress" <<<"$output" || false
    grep -q -- "egress:" <<<"$output" || false
    grep -q -- "kubernetes.io/metadata.name: kube-system" <<<"$output" || false
    grep -q -- "port: 53" <<<"$output" || false
}

@test "role: Role (not ClusterRole), limited to namespace, without secrets or deployments" {
    run render_of templates/role.yaml
    [ "$status" -eq 0 ]
    grep -q -- "kind: Role$" <<<"$output" || false
    ! grep -q -- "ClusterRole" <<<"$output" || false
    ! grep -q -- '"secrets"' <<<"$output" || false
    ! grep -q -- '"deployments"' <<<"$output" || false
}

@test "role: kubedock permissions (pods, pods/log, pods/exec, pods/portforward, services, configmaps)" {
    run render_of templates/role.yaml
    [ "$status" -eq 0 ]
    grep -q -- '"pods/log"' <<<"$output" || false
    grep -q -- '"pods/exec"' <<<"$output" || false
    grep -q -- '"pods/portforward"' <<<"$output" || false
    grep -q -- '"services"' <<<"$output" || false
    grep -q -- '"configmaps"' <<<"$output" || false
    # Never a wildcard on verbs or resources.
    ! grep -q -- '"\*"' <<<"$output" || false
}

@test "chart: helm lint and helm template" {
    run helm lint "$CHART"
    [ "$status" -eq 0 ]
    run helm template devzone-workspace "$CHART" --namespace devzone-workspace
    [ "$status" -eq 0 ]
}

@test "variables: DEVZONE_WORKSPACE=kubernetes identifies workspace container" {
    run render_of templates/statefulset.yaml
    [ "$status" -eq 0 ]
    local main
    main="$(awk '/^        - name: workspace$/{p=1} /^          resources:/{p=0} p' <<<"$output")"
    grep -q -- "- name: DEVZONE_WORKSPACE" <<<"$main" || false
    grep -A1 -- "- name: DEVZONE_WORKSPACE" <<<"$main" | grep -q -- "value: kubernetes" || false
}

@test "no-docker: no docker socket in render" {
    run render
    [ "$status" -eq 0 ]
    ! grep -q -- "docker.sock" <<<"$output" || false
}

@test "workspace: no kubeconfig (.kube) volume or mount" {
    run render
    [ "$status" -eq 0 ]
    ! grep -q -- "\.kube/" <<<"$output" || false
    ! grep -q -- "name: kubeconfig" <<<"$output" || false
}
