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
    # gh simulé : GH_ETAT = absent (défaut), sans (connecté sans workflow), avec
    cat >"$BATS_TEST_TMPDIR/bin/gh" <<'GH'
#!/usr/bin/env bash
case "${GH_ETAT:-absent}" in
    absent) echo "You are not logged into any GitHub hosts." >&2; exit 1 ;;
    sans) echo "  - Token scopes: 'gist', 'read:org', 'repo'" ;;
    avec) echo "  - Token scopes: 'gist', 'read:org', 'repo', 'workflow'" ;;
esac
GH
    chmod +x "$BATS_TEST_TMPDIR/bin/"*
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "par défaut : tous les modules désactivés, avec la commande pour les activer" {
    run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"○ module ia"*"devzone activer ia"* ]]
    [[ "$output" == *"○ module kubernetes"*"devzone activer kubernetes"* ]]
}

@test "état : identité git absente → nécessaire, avec les deux voies" {
    run bash "$DEVZONE"
    [[ "$output" == *"✖ identité git"*"gh auth login -s workflow"* ]]
    [[ "$output" == *"git config --file ~/.config/git/config user.name"* ]]
}

@test "état : identité git présente" {
    git config --global user.name "Test" && git config --global user.email "t@example.invalid"
    run bash "$DEVZONE"
    [[ "$output" == *"✔ identité git    Test <t@example.invalid>"* ]]
}

@test "état : GitHub non connecté → facultatif" {
    run bash "$DEVZONE"
    [[ "$output" == *"○ GitHub          facultatif"* ]]
}

@test "état : GitHub connecté sans permission workflow → à corriger" {
    GH_ETAT=sans run bash "$DEVZONE"
    [[ "$output" == *"⚠ GitHub"*"gh auth refresh -h github.com -s workflow"* ]]
}

@test "état : GitHub connecté avec workflow" {
    GH_ETAT=avec run bash "$DEVZONE"
    [[ "$output" == *"✔ GitHub          connecté"* ]]
}

@test "état : module actif" {
    bash "$DEVZONE" activer ia
    run bash "$DEVZONE"
    [[ "$output" == *"✔ module ia"*"actif"* ]]
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

@test "appliquer : installe ia seulement s'il est actif" {
    run bash "$DEVZONE" appliquer
    [ "$status" -eq 0 ]
    [ ! -e "$BATS_TEST_TMPDIR/npm.log" ]
    bash "$DEVZONE" activer ia
    rm -f "$BATS_TEST_TMPDIR/npm.log"
    run bash "$DEVZONE" appliquer
    grep -q "install -g" "$BATS_TEST_TMPDIR/npm.log"
}
