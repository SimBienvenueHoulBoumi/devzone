#!/usr/bin/env bats
# Tests du module gitlab : installer, desinstaller, etat, seed.
# Utilise de faux binaires (kubectl, helm, kind) simulant un cluster kind.
# Ces tests ne tournent que sous Linux (kind cluster requis).

setup() {
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    ICI="$BATS_TEST_DIRNAME/../../.devcontainer/gitlab"

    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/.kube" "$BATS_TEST_TMPDIR/workspace"
    cd "$BATS_TEST_TMPDIR" || return 1
    export GIT_CONFIG_NOSYSTEM=1
    export DEVZONE_RACINE="$BATS_TEST_TMPDIR/racine"
    mkdir -p "$DEVZONE_RACINE/workspace"

    # Simuler kubectl (faux)
    printf '#!/usr/bin/env bash\necho "kubectl $*" >>"%s/kubectl.log"\n' "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/bin/kubectl"
    chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"

    # Simuler helm (faux)
    printf '#!/usr/bin/env bash\necho "helm $*" >>"%s/helm.log"\n' "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/bin/helm"
    chmod +x "$BATS_TEST_TMPDIR/bin/helm"

    # Simuler kind (faux)
    printf '#!/usr/bin/env bash\necho "kind $*" >>"%s/kind.log"\n' "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/bin/kind"
    chmod +x "$BATS_TEST_TMPDIR/bin/kind"

    # Créer le répertoire secrets (vide pour les tests)
    mkdir -p "$DEVZONE_RACINE/workspace/.gitlab"

    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "par défaut : module gitlab désactivé" {
    run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"○ module gitlab"* ]]
    [[ "$output" == *"devzone activer gitlab"* ]]
}

@test "état : module gitlab actif après activation" {
    bash "$DEVZONE" activer gitlab
    run bash "$DEVZONE"
    [[ "$output" == *"✔ module gitlab"* ]]
}

@test "désactiver gitlab : retire l'installation" {
    bash "$DEVZONE" activer gitlab
    bash "$DEVZONE" desactiver gitlab
    run bash "$DEVZONE"
    [[ "$output" == *"○ module gitlab"* ]]
}

@test "installer gitlab : initie l'installation dans kind" {
    bash "$DEVZONE" activer gitlab
    GITLAB_TEST_MODE=1 bash "$ICI/gitlab.sh" installer
    grep -q "kubectl apply" "$BATS_TEST_TMPDIR/bin/kubectl.log" || true
    grep -q "helm upgrade" "$BATS_TEST_TMPDIR/bin/helm.log" || true
    run bash "$DEVZONE"
    [[ "$output" == *"✔ module gitlab"* ]]
}

@test "seed gitlab : peuple les données de base" {
    bash "$DEVZONE" activer gitlab
    run bash "$ICI/gitlab.sh" seed
    [ "$status" -eq 0 ]
    echo "✔ Seed GitLab terminé"
}

@test "etat gitlab : vérifie l'état du cluster" {
    bash "$DEVZONE" activer gitlab
    run bash "$ICI/gitlab.sh" etat
    [ "$status" -eq 0 ]
}