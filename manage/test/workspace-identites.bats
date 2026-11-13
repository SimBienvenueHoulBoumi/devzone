#!/usr/bin/env bats
# Workspace Kubernetes identities and logins kept in state volume (#402).
# Only helm lint and helm template: no cluster is touched.

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CHART="$ROOT/charts/devzone-workspace"
    command -v helm >/dev/null 2>&1 || skip "helm missing"
}

# Full chart render, with given options.
render() {
    helm template t "$CHART" --namespace devzone-workspace "$@"
}

# StatefulSet render only.
render_ss() {
    helm template t "$CHART" --namespace devzone-workspace --show-only templates/statefulset.yaml "$@"
}

# etat-init initContainer block, as rendered.
state_init_block() {
    awk '/^        - name: etat-init$/{p=1;print;next} /^        # kubedock/{p=0} p' <<<"$1"
}

# workspace container block (from its name to volumeClaimTemplates: its mounts
# come after its resources).
workspace_block() {
    awk '/^        - name: workspace$/{p=1} /^  volumeClaimTemplates:/{p=0} p' <<<"$1"
}

# 9 default paths of persistence.state.paths (without dashes).
default_paths() {
    printf '%s\n' .config/gh .config/git .claude .config/opencode \
        .local/share/opencode .local/state/oc-lancer .m2 .gradle .local/share/pnpm
}

@test "state: helm lint of chart" {
    run helm lint "$CHART"
    [ "$status" -eq 0 ]
}

@test "etat-init: initContainer present, before kubedock, in workspace image" {
    run render_ss
    [ "$status" -eq 0 ]
    local init
    init="$(state_init_block "$output")"
    grep -q -- '- name: etat-init' <<<"$init" || false
    grep -q -- 'image: "ghcr.io/simbienvenuehoulboumi/devzone-workspace:' <<<"$init" || false
    # It runs before sidecars: its line comes before kubedock.
    local l_init l_kd
    l_init="$(grep -n -- '- name: etat-init' <<<"$output" | cut -d: -f1)"
    l_kd="$(grep -n -- '- name: kubedock' <<<"$output" | cut -d: -f1)"
    [ "$l_init" -lt "$l_kd" ]
}

@test "etat-init: runs as vscode (UID 1000), without privilege or escalation" {
    run render_ss
    [ "$status" -eq 0 ]
    local init
    init="$(state_init_block "$output")"
    grep -q -- 'runAsUser: 1000' <<<"$init" || false
    grep -q -- 'runAsGroup: 1000' <<<"$init" || false
    grep -q -- 'allowPrivilegeEscalation: false' <<<"$init" || false
    grep -q -- 'drop: \["ALL"\]' <<<"$init" || false
    ! grep -q -- 'privileged' <<<"$init" || false
}

@test "etat-init: creates the 9 state volume folders under /home/vscode/.devzone-etat" {
    run render_ss
    [ "$status" -eq 0 ]
    local cmd
    cmd="$(grep -- 'command: \["sh", "-c"' <<<"$output")"
    local c
    while read -r c; do
        grep -q -- "/home/vscode/.devzone-etat/$c " <<<"$cmd" || grep -q -- "/home/vscode/.devzone-etat/$c\"" <<<"$cmd" || false
    done < <(default_paths)
    grep -q -- 'command: \["sh", "-c", "mkdir -p ' <<<"$cmd" || false
}

@test "etat-init: mounts state volume on /home/vscode/.devzone-etat" {
    run render_ss
    [ "$status" -eq 0 ]
    local init
    init="$(state_init_block "$output")"
    grep -q -- '- name: etat' <<<"$init" || false
    grep -q -- 'mountPath: /home/vscode/.devzone-etat' <<<"$init" || false
}

@test "mounts: workspace mounts each state volume path at its usual location" {
    run render_ss
    [ "$status" -eq 0 ]
    local main
    main="$(workspace_block "$output")"
    local c
    while read -r c; do
        grep -q -- "subPath: \"$c\"" <<<"$main" || false
        grep -q -- "mountPath: \"/home/vscode/$c\"" <<<"$main" || false
    done < <(default_paths)
    # Whole volume remains visible under .devzone-etat.
    grep -q -- 'mountPath: /home/vscode/.devzone-etat' <<<"$main" || false
    # State volume is no longer mounted under /etat.
    ! grep -q -- 'mountPath: /etat' <<<"$output" || false
}

@test "mounts: path added in persistence.state.paths is mounted and created" {
    run render_ss --set 'persistence.state.paths[9]=.config/devzone'
    [ "$status" -eq 0 ]
    grep -q -- '/home/vscode/.devzone-etat/.config/devzone' <<<"$output" || false
    grep -q -- 'subPath: ".config/devzone"' <<<"$output" || false
    grep -q -- 'mountPath: "/home/vscode/.config/devzone"' <<<"$output" || false
}

@test "mounts: no symbolic link (a link created in initContainer does not survive)" {
    run render
    [ "$status" -eq 0 ]
    ! grep -q -- 'ln -s' <<<"$output" || false
    ! grep -q -- 'ln -sfn' <<<"$output" || false
}

@test "pod: fsGroup 1000 so state volume is writable by vscode" {
    run render_ss
    [ "$status" -eq 0 ]
    grep -q -- 'securityContext:' <<<"$output" || false
    grep -q -- 'fsGroup: 1000' <<<"$output" || false
}

@test "pod: runAsUser 1000, runAsGroup 1000, runAsNonRoot true (never root)" {
    run render_ss
    [ "$status" -eq 0 ]
    local pod
    pod="$(awk '/^      securityContext:$/{p=1} /^      # Sidecars/{p=0} p' <<<"$output")"
    grep -q -- 'runAsUser: 1000' <<<"$pod" || false
    grep -q -- 'runAsGroup: 1000' <<<"$pod" || false
    grep -q -- 'runAsNonRoot: true' <<<"$pod" || false
    grep -q -- 'fsGroup: 1000' <<<"$pod" || false
    ! grep -q -- 'runAsUser: 0' <<<"$output" || false
}

@test "workspace: HOME=/home/vscode in workspace container" {
    run render_ss
    [ "$status" -eq 0 ]
    local main
    main="$(workspace_block "$output")"
    grep -q -- '- name: HOME' <<<"$main" || false
    grep -q -- 'value: /home/vscode$' <<<"$main" || false
    # No /root HOME anywhere in render.
    ! grep -q -- '/root' <<<"$output" || false
}

@test "privilege: no privileged container, in whole render" {
    run render
    [ "$status" -eq 0 ]
    ! grep -q -- 'privileged' <<<"$output" || false
    ! grep -q -- 'privileged: true' <<<"$output" || false
}

@test "pvc: state kept at uninstall (keep annotation and Retain retention)" {
    run render_ss
    [ "$status" -eq 0 ]
    local state
    state="$(awk '/^    - metadata:/{p=0} /^        name: etat$/{p=1} p' <<<"$output")"
    grep -q -- 'helm.sh/resource-policy: keep' <<<"$state" || false
    grep -q -- 'persistentVolumeClaimRetentionPolicy:' <<<"$output" || false
    grep -q -- 'whenDeleted: Retain' <<<"$output" || false
    grep -q -- 'whenScaled: Retain' <<<"$output" || false
}

@test "pvc: etat remains a volumeClaimTemplate, default size 10Gi" {
    run render_ss
    [ "$status" -eq 0 ]
    grep -q -- '^        name: etat$' <<<"$output" || false
    grep -q -- 'storage: 10Gi' <<<"$output" || false
}

@test "secrets: render contains no login or password" {
    run render
    [ "$status" -eq 0 ]
    ! grep -qi -- 'password' <<<"$output" || false
    ! grep -qi -- 'GH_TOKEN' <<<"$output" || false
    ! grep -qi -- 'secretName' <<<"$output" || false
    ! grep -q -- 'privileged' <<<"$output" || false
}
