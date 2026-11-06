#!/usr/bin/env bats
# post-create.sh (#370) : la configuration kube de l'hôte est posée avant les
# modules, et son échec n'arrête pas la création du conteneur.

setup() {
    load commun
    relais_docker_isole
    kube_isole
    SCRIPT="$BATS_TEST_DIRNAME/../../.devcontainer/post-create.sh"
    DEVCONTAINER="$BATS_TEST_DIRNAME/../../.devcontainer/devcontainer.json"
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "kube-config.sh est lancé avant devzone appliquer" {
    kube="$(grep -nF 'bash /workspaces/devzone/.devcontainer/kube-config.sh' "$SCRIPT" | head -1 | cut -d: -f1)"
    appliquer="$(grep -nF 'devzone appliquer' "$SCRIPT" | head -1 | cut -d: -f1)"
    [ -n "$kube" ]
    [ -n "$appliquer" ]
    [ "$kube" -lt "$appliquer" ]
}

@test "échec de kube-config.sh : message sur la sortie d'erreur et création poursuivie" {
    ligne="$(grep -F 'bash /workspaces/devzone/.devcontainer/kube-config.sh' "$SCRIPT")"
    [[ "$ligne" == *' || '* ]] || false
    [[ "$ligne" == *'devzone : configuration kube incomplète, réessayer : devzone demarrer'* ]] || false
    [[ "$ligne" == *'>&2'* ]] || false
}

@test "volume devzone-agent : état de devzone agent monté dans devcontainer.json" {
    # Montage à côté des volumes -opencode-*, même préfixe DEVZONE_VOLUMES (#377)
    grep -qF 'devzone}-agent,target=/home/vscode/.local/state/oc-lancer,type=volume' "$DEVCONTAINER" || false
    opencode="$(grep -nF 'opencode-data,target=/home/vscode/.local/share/opencode' "$DEVCONTAINER" | head -1 | cut -d: -f1)"
    agent="$(grep -nF 'agent,target=/home/vscode/.local/state/oc-lancer' "$DEVCONTAINER" | head -1 | cut -d: -f1)"
    [ -n "$opencode" ] || false
    [ -n "$agent" ] || false
    { [ "$agent" -gt "$opencode" ] && [ "$agent" -le $((opencode + 6)) ]; } || false
}

@test "volume devzone-agent : post-create.sh en fait le chown" {
    grep -q '/home/vscode/.local/state/oc-lancer' "$SCRIPT" || false
}
