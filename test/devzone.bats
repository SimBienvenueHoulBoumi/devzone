#!/usr/bin/env bats
# Commande devzone : état des modules, activation, désactivation, migration.
# HOME temporaire ; npm et kubectl simulés (aucune installation réelle).

setup() {
    DEVZONE="$BATS_TEST_DIRNAME/../.devcontainer/devzone"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin"
    # npm simulé : journalise ses arguments
    printf '#!/usr/bin/env bash\necho "npm $*" >>"%s/npm.log"\n' "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/bin/npm"
    # kube-config.sh n'est pas lancé : kubernetes testé par l'état seul
    printf '#!/usr/bin/env bash\nexit 1\n' >"$BATS_TEST_TMPDIR/bin/kubectl"
    chmod +x "$BATS_TEST_TMPDIR/bin/"*
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "par défaut : tous les modules désactivés" {
    run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ia          off"* ]]
    [[ "$output" == *"kubernetes  off"* ]]
}

@test "activer ia : installe les versions figées, état gardé" {
    run bash "$DEVZONE" activer ia
    [ "$status" -eq 0 ]
    grep -q "install -g .*@anthropic-ai/claude-code@[0-9]" "$BATS_TEST_TMPDIR/npm.log"
    grep -q "opencode-ai@[0-9]" "$BATS_TEST_TMPDIR/npm.log"
    run bash "$DEVZONE" actif ia
    [ "$status" -eq 0 ]
}

@test "désactiver ia : désinstalle, état gardé" {
    bash "$DEVZONE" activer ia
    run bash "$DEVZONE" desactiver ia
    [ "$status" -eq 0 ]
    grep -q "npm uninstall -g" "$BATS_TEST_TMPDIR/npm.log"
    run bash "$DEVZONE" actif ia
    [ "$status" -ne 0 ]
}

@test "désactiver kubernetes : retire hote.config, sans rien lancer" {
    mkdir -p "$HOME/.kube" && touch "$HOME/.kube/hote.config"
    run bash "$DEVZONE" desactiver kubernetes
    [ "$status" -eq 0 ]
    [ ! -e "$HOME/.kube/hote.config" ]
    [[ "$output" == *"metrics-server reste installé"* ]]
}

@test "module inconnu : message et erreur, état intact" {
    run bash "$DEVZONE" activer nexistepas
    [ "$status" -eq 1 ]
    [[ "$output" == *"module inconnu : nexistepas"* ]]
    run bash "$DEVZONE" activer
    [ "$status" -eq 1 ]
    run bash "$DEVZONE" actif nexistepas
    [ "$status" -eq 2 ]
}

@test "commande inconnue : erreur" {
    run bash "$DEVZONE" truc
    [ "$status" -eq 1 ]
}

@test "migration : connexion Claude existante → ia activé et signalé" {
    mkdir -p "$HOME/.claude" && echo '{}' >"$HOME/.claude/.credentials.json"
    run bash "$DEVZONE" actif ia
    [ "$status" -eq 0 ]
    [[ "$output" == *"module ia activé"* ]]
}

@test "migration : connexion opencode existante → ia activé" {
    mkdir -p "$HOME/.local/share/opencode" && echo '{}' >"$HOME/.local/share/opencode/auth.json"
    run bash "$DEVZONE" actif ia
    [ "$status" -eq 0 ]
}

@test "migration seulement au premier démarrage : un choix fait est respecté" {
    bash "$DEVZONE" desactiver ia
    mkdir -p "$HOME/.claude" && echo '{}' >"$HOME/.claude/.credentials.json"
    run bash "$DEVZONE" actif ia
    [ "$status" -ne 0 ]
}

@test "appliquer : installe ia s'il est actif, liste les modules désactivés" {
    run bash "$DEVZONE" appliquer
    [ "$status" -eq 0 ]
    [ ! -e "$BATS_TEST_TMPDIR/npm.log" ]
    [[ "$output" == *"modules désactivés : ia kubernetes"* ]]
    bash "$DEVZONE" activer ia
    rm -f "$BATS_TEST_TMPDIR/npm.log"
    run bash "$DEVZONE" appliquer
    grep -q "install -g" "$BATS_TEST_TMPDIR/npm.log"
    [[ "$output" == *"modules désactivés : kubernetes"* ]]
}
