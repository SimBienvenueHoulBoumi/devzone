#!/usr/bin/env bats
# Workstation mode for make up|shell|stop|rebuild and advice target (#472): fake
# npx, docker, kubectl and helm logging their arguments.
# No real cluster, Docker, npx or kubectl.

setup() {
    load commun
    T="$BATS_TEST_TMPDIR"
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    POSTE="$RACINE/manage/scripts/poste.sh"
    FAKE_LOG="$T/tools.log"
    export FAKE_LOG
    mkdir -p "$T/bin" "$T/folder"
    cat >"$T/bin/npx" <<'NPX'
#!/usr/bin/env bash
echo "npx $*" >>"$FAKE_LOG"
NPX
    cat >"$T/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
echo "docker $*" >>"$FAKE_LOG"
DOCKER
    chmod +x "$T/bin/npx" "$T/bin/docker"
    export PATH="$T/bin:$PATH"
    : >"$FAKE_LOG"
    unset FAKE_KUBE_CLUSTER_INFO
}

# Fake manage/workspace.sh in folder: logs its arguments.
fake_workspace() {
    mkdir -p "$T/folder/manage"
    cat >"$T/folder/manage/workspace.sh" <<'WS'
#!/usr/bin/env bash
echo "workspace $*" >>"$FAKE_LOG"
WS
}

# Fake kubectl and helm: kubectl logs then responds (FAKE_KUBE_CLUSTER_INFO=fail
# -> cluster-info fails), get-contexts lists devzone.
fake_kube() {
    cat >"$T/bin/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
echo "kubectl $*" >>"$FAKE_LOG"
case "$*" in
    *"get-contexts"*) echo devzone ;;
    *"cluster-info"*) [ "${FAKE_KUBE_CLUSTER_INFO:-ok}" = ok ] ;;
esac
KUBECTL
    cat >"$T/bin/helm" <<'HELM'
#!/usr/bin/env bash
echo "helm $*" >>"$FAKE_LOG"
HELM
    chmod +x "$T/bin/kubectl" "$T/bin/helm"
    PATH="$T/bin:/usr/bin:/bin"
    export PATH
}

# Advice target after update (#472): kubernetes mode -> next start message;
# Docker with reachable Kubernetes -> migrate suggested; otherwise nothing.
# Always exit 0.

@test "advice and conseil: kubernetes workspace -> next start message, no kubectl" {
    printf 'workspace=kubernetes\n' >"$T/folder/.devzone.modules"
    fake_kube
    : >"$FAKE_LOG"
    run bash "$POSTE" advice "$T/folder"
    [ "$status" -eq 0 ]
    [[ "$output" == *"next devzone workspace start"* ]] || false
    [ ! -s "$FAKE_LOG" ]
    run bash "$POSTE" conseil "$T/folder"
    [ "$status" -eq 0 ]
    [[ "$output" == *"next devzone workspace start"* ]] || false
}

@test "advice: docker, kubectl and helm, cluster-info ok -> migrate suggested with --context devzone" {
    rm -f "$T/folder/.devzone.modules"
    fake_kube
    : >"$FAKE_LOG"
    run bash "$POSTE" advice "$T/folder"
    [ "$status" -eq 0 ]
    [[ "$output" == *"devzone workspace migrate"* ]] || false
    [[ "$output" == *"devzone workspace revert"* ]] || false
    [[ "$(cat "$FAKE_LOG")" == *"cluster-info --request-timeout=5s --context devzone"* ]] || false
}

@test "advice: docker, cluster-info fails -> nothing" {
    rm -f "$T/folder/.devzone.modules"
    FAKE_KUBE_CLUSTER_INFO=fail
    export FAKE_KUBE_CLUSTER_INFO
    fake_kube
    : >"$FAKE_LOG"
    run bash "$POSTE" advice "$T/folder"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "advice: docker without helm in PATH -> nothing" {
    rm -f "$T/folder/.devzone.modules"
    fake_kube
    rm "$T/bin/helm"
    : >"$FAKE_LOG"
    run bash "$POSTE" advice "$T/folder"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -s "$FAKE_LOG" ]
}

@test "docker (missing line, workspace=docker, unknown value): exit 3, nothing shown or logged" {
    for content in "" "workspace=docker" "workspace=minikube"; do
        if [ -n "$content" ]; then
            printf '%s\n' "$content" >"$T/folder/.devzone.modules"
        else
            rm -f "$T/folder/.devzone.modules"
        fi
        for target in up shell stop rebuild; do
            : >"$FAKE_LOG"
            run bash "$POSTE" "$target" "$T/folder"
            [ "$status" -eq 3 ]
            [ -z "$output" ]
            [ ! -s "$FAKE_LOG" ]
        done
    done
}

@test "kubernetes workspace with manage/workspace.sh: up, shell and stop drive the script" {
    printf 'workspace=kubernetes\n' >"$T/folder/.devzone.modules"
    fake_workspace

    : >"$FAKE_LOG"
    run bash "$POSTE" up "$T/folder"
    [ "$status" -eq 0 ]
    [ "$(cat "$FAKE_LOG")" = "workspace start" ]

    : >"$FAKE_LOG"
    run bash "$POSTE" shell "$T/folder"
    [ "$status" -eq 0 ]
    [ "$(sed -n '1p' "$FAKE_LOG")" = "workspace start" ]
    [ "$(sed -n '2p' "$FAKE_LOG")" = "workspace shell" ]
    [ "$(wc -l <"$FAKE_LOG" | tr -d ' ')" = 2 ]

    : >"$FAKE_LOG"
    run bash "$POSTE" stop "$T/folder"
    [ "$status" -eq 0 ]
    [ "$(cat "$FAKE_LOG")" = "workspace stop" ]
}

@test "kubernetes workspace: rebuild refused and points to devzone workspace revert" {
    printf 'workspace=kubernetes\n' >"$T/folder/.devzone.modules"
    run bash "$POSTE" rebuild "$T/folder"
    [ "$status" -eq 1 ]
    [[ "$output" == *"devzone workspace revert"* ]] || false
    [ ! -s "$FAKE_LOG" ]
}

@test "kubernetes workspace without manage/workspace.sh: npx devzone@version of folder" {
    printf 'workspace=kubernetes\n' >"$T/folder/.devzone.modules"
    printf 'version 0.34.4\nabc  Makefile\n' >"$T/folder/.devzone.version"

    : >"$FAKE_LOG"
    run bash "$POSTE" up "$T/folder"
    [ "$status" -eq 0 ]
    [ "$(cat "$FAKE_LOG")" = "npx -y devzone@0.34.4 workspace start" ]

    rm -f "$T/folder/.devzone.version"
    : >"$FAKE_LOG"
    run bash "$POSTE" up "$T/folder"
    [ "$status" -eq 0 ]
    [ "$(cat "$FAKE_LOG")" = "npx -y devzone@latest workspace start" ]
}

@test "make -n up and make -n shell: recipe calls poste.sh" {
    run make -n -C "$RACINE" up
    [ "$status" -eq 0 ]
    [[ "$output" == *"poste.sh up"* ]] || false
    run make -n -C "$RACINE" shell
    [ "$status" -eq 0 ]
    [[ "$output" == *"poste.sh shell"* ]] || false
}

@test "poste.sh: runs under bash 3.2 if available" {
    bash32=""
    if command -v test-bash32 >/dev/null 2>&1; then
        bash32="test-bash32"
    elif [ -x /bin/bash ] && /bin/bash --version 2>/dev/null | grep -q 'version 3\.2\.'; then
        bash32="/bin/bash"
    fi
    [ -n "$bash32" ] || skip "bash 3.2 missing"

    printf 'workspace=kubernetes\n' >"$T/folder/.devzone.modules"
    fake_workspace
    : >"$FAKE_LOG"
    run "$bash32" "$POSTE" up "$T/folder"
    [ "$status" -eq 0 ]
    [ "$(cat "$FAKE_LOG")" = "workspace start" ]
}
