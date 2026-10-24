#!/usr/bin/env bats
# Commande devzone : état des modules, activation, désactivation, migration.
# HOME temporaire ; npm et kubectl simulés (aucune installation réelle).

setup() {
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    # Versions figées lues dans les fichiers : une montée automatique (workflow
    # versions) ne casse pas ces tests
    REPOWARDEN_FIGE="$(sed -nE 's/.*npm install -g repowarden@([^[:space:]]+).*/\1/p' "$BATS_TEST_DIRNAME/../../.devcontainer/post-create.sh" | head -1)"
    IA_FIGES="$(sed -nE 's/^IA_[A-Z0-9_]+=([^[:space:]()"]+)@([^@[:space:]()"]+)$/\1 \2/p' "$DEVZONE")"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin"
    # Hors du clone : sa .git/config (identité locale d'un contributeur) et la
    # configuration système fausseraient l'état « identité git »
    cd "$BATS_TEST_TMPDIR" || return 1
    export GIT_CONFIG_NOSYSTEM=1
    # Racine de devzone simulée : les worktrees du vrai dépôt n'interfèrent pas
    export DEVZONE_RACINE="$BATS_TEST_TMPDIR/racine"
    mkdir -p "$DEVZONE_RACINE/workspace"
    # npm simulé : journalise ses arguments ; « npm ls -g --depth=0 --json »
    # renvoie les outils installés (NPM_INSTALLEES)
    export NPM_LOG="$BATS_TEST_TMPDIR/npm.log"
    export NPM_INSTALLEES="$BATS_TEST_TMPDIR/installees"
    : >"$NPM_INSTALLEES"
    cat >"$BATS_TEST_TMPDIR/bin/npm" <<'NPM'
#!/usr/bin/env bash
echo "npm $*" >>"$NPM_LOG"
if [ "${1:-}" = ls ] && [ "${2:-}" = -g ]; then
    printf '{"dependencies":{'
    sep=""
    while read -r p v; do
        [ -n "$p" ] || continue
        printf '%s"%s":{"version":"%s"}' "$sep" "$p" "$v"
        sep=","
    done <"$NPM_INSTALLEES"
    printf '}}\n'
fi
NPM
    # repowarden simulé : journalise ses arguments (garde-fou du module ia)
    printf '#!/usr/bin/env bash\necho "repowarden $*" >>"%s/repowarden.log"\n' "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/bin/repowarden"
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

@test "état : outil en retard → ⚠ avec la commande devzone appliquer" {
    printf 'repowarden 4.9.2\n' >"$NPM_INSTALLEES"
    run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"⚠ outils          repowarden 4.9.2 installé, $REPOWARDEN_FIGE figé : devzone appliquer"* ]]
}

@test "état : versions figées installées → ✔ outils" {
    [ "$(wc -l <<<"$IA_FIGES")" -eq 2 ]
    printf 'repowarden %s\n%s\n' "$REPOWARDEN_FIGE" "$IA_FIGES" >"$NPM_INSTALLEES"
    run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"✔ outils          versions figées"* ]]
}

@test "état : worktree au chemin absent (créé de l'autre côté) → ⚠, rien supprimé" {
    depot="$DEVZONE_RACINE/workspace/projet"
    mkdir -p "$depot"
    git -C "$depot" init -q
    git -C "$depot" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m base
    git -C "$depot" worktree add -q --detach "$BATS_TEST_TMPDIR/wt-hote"
    # Dépôt rangé un niveau plus bas (workspace/<groupe>/<dépôt>)
    imbrique="$DEVZONE_RACINE/workspace/groupe/autre"
    mkdir -p "$imbrique"
    git -C "$imbrique" init -q
    git -C "$imbrique" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m base
    git -C "$imbrique" worktree add -q --detach "$BATS_TEST_TMPDIR/wt-mac"
    rm -rf "$BATS_TEST_TMPDIR/wt-hote" "$BATS_TEST_TMPDIR/wt-mac"
    run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"⚠ worktree        $BATS_TEST_TMPDIR/wt-hote absent ici"*"jamais git worktree prune"* ]] || false
    [[ "$output" == *"⚠ worktree        $BATS_TEST_TMPDIR/wt-mac absent ici"* ]] || false
    [ -d "$depot/.git/worktrees/wt-hote" ]
    [ -d "$imbrique/.git/worktrees/wt-mac" ]
}

@test "état : worktree présent → aucun avertissement worktree" {
    depot="$DEVZONE_RACINE/workspace/groupe/projet"
    mkdir -p "$depot"
    git -C "$depot" init -q
    git -C "$depot" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m base
    git -C "$depot" worktree add -q --detach "$BATS_TEST_TMPDIR/wt-ici"
    run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    [[ "$output" != *"⚠ worktree"* ]] || false
}

@test "état : module actif" {
    bash "$DEVZONE" activer ia
    run bash "$DEVZONE"
    [[ "$output" == *"✔ module ia"*"actif"* ]]
}

@test "activer ia : installe les versions figées, état gardé" {
    run bash "$DEVZONE" activer ia
    [ "$status" -eq 0 ]
    grep -qE "install -g .* @anthropic-ai/claude-code@[0-9.]+ opencode-ai@[0-9.]+$" "$BATS_TEST_TMPDIR/npm.log"
    run bash "$DEVZONE" actif ia
    [ "$status" -eq 0 ]
}

@test "désactiver ia : désinstalle, état gardé" {
    bash "$DEVZONE" activer ia
    run bash "$DEVZONE" desactiver ia
    [ "$status" -eq 0 ]
    grep -qx "npm uninstall -g @anthropic-ai/claude-code opencode-ai" "$BATS_TEST_TMPDIR/npm.log"
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
    ! grep -q "install -g" "$BATS_TEST_TMPDIR/npm.log"
    bash "$DEVZONE" activer ia
    rm -f "$BATS_TEST_TMPDIR/npm.log"
    run bash "$DEVZONE" appliquer
    grep -q "install -g" "$BATS_TEST_TMPDIR/npm.log"
}

@test "appliquer : repowarden en retard → installé à la version figée" {
    printf 'repowarden 4.9.2\n' >"$NPM_INSTALLEES"
    run bash "$DEVZONE" appliquer
    [ "$status" -eq 0 ]
    grep -qx "npm install -g repowarden@$REPOWARDEN_FIGE" "$BATS_TEST_TMPDIR/npm.log"
    grep -qx "repowarden install --global --lang fr" "$BATS_TEST_TMPDIR/repowarden.log"
    [[ "$output" == *"repowarden 4.9.2 → $REPOWARDEN_FIGE"* ]]
}

@test "activer ia : garde-fou repowarden branché pour Claude Code et opencode" {
    run bash "$DEVZONE" activer ia
    [ "$status" -eq 0 ]
    [[ "$output" == *"garde-fou repowarden actif"* ]]
    grep -qx "repowarden agents init --global" "$BATS_TEST_TMPDIR/repowarden.log"
}

@test "garde-fou : rebranché à chaque appliquer avec ia actif, jamais avec ia désactivé" {
    bash "$DEVZONE" activer ia
    rm -f "$BATS_TEST_TMPDIR/repowarden.log"
    bash "$DEVZONE" appliquer
    grep -qx "repowarden agents init --global" "$BATS_TEST_TMPDIR/repowarden.log"
    rm -f "$BATS_TEST_TMPDIR/repowarden.log"
    bash "$DEVZONE" desactiver ia
    bash "$DEVZONE" appliquer
    [ ! -e "$BATS_TEST_TMPDIR/repowarden.log" ]
}

@test "garde-fou : repowarden absent -> ia activé quand même, commande à lancer" {
    rm "$BATS_TEST_TMPDIR/bin/repowarden"
    PATH="$BATS_TEST_TMPDIR/bin:/usr/bin:/bin" run bash "$DEVZONE" activer ia
    [ "$status" -eq 0 ]
    [[ "$output" == *"garde-fou repowarden non branché"*"repowarden agents init --global"* ]]
    grep -q "install -g" "$BATS_TEST_TMPDIR/npm.log"
}

@test "activer ia : configuration opencode absente -> écrite depuis le modèle" {
    run bash "$DEVZONE" activer ia
    [ "$status" -eq 0 ]
    [ -f "$HOME/.config/opencode/opencode.jsonc" ]
    grep -q '^// devzone : configuration opencode par défaut' "$HOME/.config/opencode/opencode.jsonc"
    grep -q '"model": "opencode/big-pickle"' "$HOME/.config/opencode/opencode.jsonc"
    grep -q '"compaction": {' "$HOME/.config/opencode/opencode.jsonc"
    [[ "$output" == *"opencode : configuration par défaut écrite"* ]]
}

@test "activer ia : configuration opencode avec le repère et différente -> mise à jour" {
    mkdir -p "$HOME/.config/opencode"
    printf '// devzone : configuration opencode par défaut (ancienne)\n{"model":"ancien"}\n' >"$HOME/.config/opencode/opencode.jsonc"
    run bash "$DEVZONE" activer ia
    [ "$status" -eq 0 ]
    grep -q '"model": "opencode/big-pickle"' "$HOME/.config/opencode/opencode.jsonc"
    [[ "$output" == *"opencode : configuration par défaut mise à jour"* ]]
}

@test "activer ia : configuration opencode avec seulement \$schema -> remplacée" {
    mkdir -p "$HOME/.config/opencode"
    printf '{\n  "$schema": "https://opencode.ai/config.json"\n}\n' >"$HOME/.config/opencode/opencode.jsonc"
    run bash "$DEVZONE" activer ia
    [ "$status" -eq 0 ]
    grep -q '^// devzone : configuration opencode par défaut' "$HOME/.config/opencode/opencode.jsonc"
    grep -q '"model": "opencode/big-pickle"' "$HOME/.config/opencode/opencode.jsonc"
    [[ "$output" == *"opencode : configuration par défaut mise à jour"* ]]
}

@test "activer ia : configuration opencode sans le repère -> gardée" {
    mkdir -p "$HOME/.config/opencode"
    printf '{"model":"mon-modele"}\n' >"$HOME/.config/opencode/opencode.jsonc"
    run bash "$DEVZONE" activer ia
    [ "$status" -eq 0 ]
    [ "$(cat "$HOME/.config/opencode/opencode.jsonc")" = '{"model":"mon-modele"}' ]
    [[ "$output" == *"opencode : configuration personnalisée, gardée"* ]]
}

@test "modèle opencode : défauts durcis (bash en accord, secrets et curl interdits)" {
    modele="$BATS_TEST_DIRNAME/../../.devcontainer/opencode.jsonc"
    grep -q '"edit": "allow"' "$modele"
    grep -q '"webfetch": "ask"' "$modele"
    grep -q '"\*": "ask"' "$modele"
    grep -q '"git \*": "allow"' "$modele"
    grep -q '"bats\*": "allow"' "$modele"
    grep -q '"gh auth token\*": "deny"' "$modele"
    grep -q '"gh auth status --show-token\*": "deny"' "$modele"
    grep -q '"\*hosts.yml\*": "deny"' "$modele"
    grep -q '"\*\.credentials\*": "deny"' "$modele"
    grep -q '"\*auth.json\*": "deny"' "$modele"
    grep -q '"\*/.ssh/\*": "deny"' "$modele"
    grep -q '"curl\*": "deny"' "$modele"
    grep -q '"wget\*": "deny"' "$modele"
}

@test "modèle opencode : les deny passent après les allow (dernier motif gagnant)" {
    modele="$BATS_TEST_DIRNAME/../../.devcontainer/opencode.jsonc"
    dernier_allow="$(grep -n '": "allow"' "$modele" | tail -1 | cut -d: -f1)"
    premier_deny="$(grep -n '": "deny"' "$modele" | head -1 | cut -d: -f1)"
    [ -n "$dernier_allow" ] && [ -n "$premier_deny" ]
    [ "$premier_deny" -gt "$dernier_allow" ]
}
