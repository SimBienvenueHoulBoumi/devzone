#!/usr/bin/env bats
# post-create.sh (#370): the host kube configuration is set before the
# modules, and its failure does not stop the container creation.

setup() {
    load commun
    kube_isole
    SCRIPT="$BATS_TEST_DIRNAME/../../.devcontainer/post-create.sh"
    DEVCONTAINER="$BATS_TEST_DIRNAME/../../.devcontainer/devcontainer.json"
    LOCK="$BATS_TEST_DIRNAME/../../.devcontainer/devcontainer-lock.json"
    DOCKERFILE="$BATS_TEST_DIRNAME/../../.devcontainer/Dockerfile"
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "kube-config.sh runs before devzone apply" {
    kube="$(grep -nF 'bash /workspaces/devzone/.devcontainer/kube-config.sh' "$SCRIPT" | head -1 | cut -d: -f1)"
    appliquer="$(grep -nF 'devzone apply' "$SCRIPT" | head -1 | cut -d: -f1)"
    [ -n "$kube" ]
    [ -n "$appliquer" ]
    [ "$kube" -lt "$appliquer" ]
}

@test "kube-config.sh failure: message on the error output and creation continued" {
    ligne="$(grep -F 'bash /workspaces/devzone/.devcontainer/kube-config.sh' "$SCRIPT")"
    [[ "$ligne" == *' || '* ]] || false
    [[ "$ligne" == *'devzone : kube configuration incomplete, retry: devzone start'* ]] || false
    [[ "$ligne" == *'>&2'* ]] || false
}

@test "devzone-agent volume: devzone agent state mounted in devcontainer.json" {
    # Mount next to the -opencode-* volumes, same DEVZONE_VOLUMES prefix (#377)
    grep -qF 'devzone}-agent,target=/home/vscode/.local/state/oc-lancer,type=volume' "$DEVCONTAINER" || false
    opencode="$(grep -nF 'opencode-data,target=/home/vscode/.local/share/opencode' "$DEVCONTAINER" | head -1 | cut -d: -f1)"
    agent="$(grep -nF 'agent,target=/home/vscode/.local/state/oc-lancer' "$DEVCONTAINER" | head -1 | cut -d: -f1)"
    [ -n "$opencode" ] || false
    [ -n "$agent" ] || false
    { [ "$agent" -gt "$opencode" ] && [ "$agent" -le $((opencode + 6)) ]; } || false
}

@test "devzone-agent volume: post-create.sh chowns it" {
    grep -q '/home/vscode/.local/state/oc-lancer' "$SCRIPT" || false
}

@test "devcontainer.json and devcontainer-lock.json: no python feature" {
    ! grep -Fq 'features/python' "$DEVCONTAINER" || false
    ! grep -Fq 'features/python' "$LOCK" || false
}

@test "Dockerfile: python3-venv and python-is-python3 installed by apt" {
    grep -Fq 'python3-venv' "$DOCKERFILE" || false
    grep -Fq 'python-is-python3' "$DOCKERFILE" || false
    grep -Eq 'apt-get .*install' "$DOCKERFILE" || false
}

# Parents of the subPath mounts of the state volume: without these folders owned by
# vscode, Kubernetes creates them as root and opencode --version fails with EACCES (#513)
@test "Dockerfile: ~/.local/state and ~/.local/share created for vscode (uid/gid 1000)" {
    grep -Eq 'install -d -o 1000 -g 1000 /home/vscode/.local /home/vscode/.local/bin /home/vscode/.local/state /home/vscode/.local/share /home/vscode/.config' "$DOCKERFILE" || false
}
