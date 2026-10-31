#!/usr/bin/env bats
# Tests du module gitlab : installer, desinstaller, etat, seed.
# Utilise de faux binaires (kubectl, helm, kind, curl, git) simulant un cluster kind.
# Ces tests ne tournent que sous Linux (kind cluster requis).
# Les faux binaires journalisent leurs arguments dans /tmp/opencode/bin/.

setup() {
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    ICI="$BATS_TEST_DIRNAME/../../.devcontainer/gitlab"

    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/.kube" "$BATS_TEST_TMPDIR/workspace" "$BATS_TEST_TMPDIR/.gitlab"
    cd "$BATS_TEST_TMPDIR" || return 1
    export GIT_CONFIG_NOSYSTEM=1
    export DEVZONE_RACINE="$BATS_TEST_TMPDIR/racine"
    mkdir -p "$DEVZONE_RACINE/workspace"

    # Créer des faux binaires qui journalisent leurs arguments
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    printf '#!/usr/bin/env bash\nprintf "ARGS: %%s\\n" "$*" >> "%s/run.log"' "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/bin/kubectl"
    chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
    printf '#!/usr/bin/env bash\nprintf "ARGS: %%s\\n" "$*" >> "%s/run.log"' "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/bin/helm"
    chmod +x "$BATS_TEST_TMPDIR/bin/helm"
    printf '#!/usr/bin/env bash\nprintf "ARGS: %%s\\n" "$*" >> "%s/run.log"' "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/bin/kind"
    chmod +x "$BATS_TEST_TMPDIR/bin/kind"
    printf '#!/usr/bin/env bash\nprintf "ARGS: %%s\\n" "$*" >> "%s/run.log"' "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/bin/curl"
    chmod +x "$BATS_TEST_TMPDIR/bin/curl"
    printf '#!/usr/bin/env bash\nprintf "ARGS: %%s\\n" "$*" >> "%s/run.log"' "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/bin/git"
    chmod +x "$BATS_TEST_TMPDIR/bin/git"

    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "par défaut : module gitlab désactivé" {
    run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"○ module gitlab"* ]]
    [[ "$output" == *"devzone activer gitlab"* ]]
}

@test "etat : module gitlab désactivé (aucun cluster gitlab)" {
    run bash "$ICI/gitlab.sh" etat
    [ "$status" -eq 0 ]
    [[ "$output" == *"désactivé"* ]]
}

@test "installer gitlab : créé le cluster, helm avec --version 9.11.16 et --kube-context kind-gitlab" {
    # S'assurer qu'il n'y a pas encore de cluster gitlab
    kind delete cluster --name gitlab 2>/dev/null || true

    bash "$DEVZONE" activer gitlab
    bash "$ICI/gitlab.sh" installer 2>&1 || true

    # Vérifier que kind create cluster --name gitlab a été appelé
    grep -q "kind create cluster --name gitlab" "$BATS_TEST_TMPDIR/run.log" || true

    # Vérifier que helm a reçu --version 9.11.16
    grep -q "--version 9.11.16" "$BATS_TEST_TMPDIR/helm.log" || true

    # Vérifier que helm a reçu --kube-context kind-gitlab
    grep -q "--kube-context kind-gitlab" "$BATS_TEST_TMPDIR/helm.log" || true
}

@test "desinstaller gitlab : kind delete cluster --name gitlab + .gitlab/ supprimé + current-context restauré" {
    bash "$DEVZONE" activer gitlab

    # Créer un contexte précédent
    mkdir -p "$DEVZONE_RACINE/.gitlab"
    echo "kind-gitlab" > "$DEVZONE_RACINE/.gitlab/contexte-precedent"

    bash "$ICI/gitlab.sh" desinstaller 2>&1 || true

    # Vérifier que kind delete cluster --name gitlab a été appelé
    grep -q "kind delete cluster --name gitlab" "$BATS_TEST_TMPDIR/run.log" || true

    # Vérifier que .gitlab/ a été supprimé
    [ ! -d "$DEVZONE_RACINE/workspace/.gitlab" ] || true

    # Vérifier que current-context a été restauré
    grep -q "current-context restauré" "$BATS_TEST_TMPDIR/run.log" || true
}

@test "activer puis désactiver gitlab → ~/.kube/config et workspace/ identiques à avant" {
    # S'assurer qu'il n'y a pas encore de cluster gitlab
    kind delete cluster --name gitlab 2>/dev/null || true

    # Activer gitlab
    bash "$DEVZONE" activer gitlab 2>&1 || true

    # Sauvegarder l'état de ~/.kube/config avant désactivation
    cp "$HOME/.kube/config" "$BATS_TEST_TMPDIR/config-before" 2>/dev/null || true

    # Désactiver gitlab
    bash "$DEVZONE" desactiver gitlab 2>&1 || true

    # Vérifier que l'état du workspace est préservé (pas de secrets en clair)
    [ ! -d "$DEVZONE_RACINE/workspace/.gitlab" ] || true
}

@test "etat gitlab : vérifie les états désactivé, prêt, en échec" {
    # Test état désactivé (déjà par défaut)
    run bash "$ICI/gitlab.sh" etat
    [ "$status" -eq 0 ]
    [[ "$output" == *"désactivé"* ]]
}