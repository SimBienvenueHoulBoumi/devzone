#!/usr/bin/env bats
# Commande devzone : état des modules, activation, désactivation, migration.
# HOME temporaire ; npm et kubectl simulés (aucune installation réelle).

install_faux_repowarden() {
    cat >"$BATS_TEST_TMPDIR/bin/repowarden" <<'REP'
#!/usr/bin/env bash
echo "repowarden $*" >>"$BATS_TEST_TMPDIR/repowarden.log"
case "$*" in
    *"agents init"*)
        mkdir -p "$HOME/.claude" "$HOME/.config/opencode/plugins" "$HOME/.claude/skills/repowarden" "$HOME/.config/opencode/skills/repowarden"
        printf '{\n  "hooks": {\n    "PreToolUse": [\n      {\n        "matcher": "Bash",\n        "hooks": [\n          {\n            "type": "command",\n            "command": "repowarden garde"\n          }\n        ]\n      }\n    ]\n  }\n}\n' >"$HOME/.claude/settings.json"
        printf '#!/usr/bin/env bash\necho garde\n' >"$HOME/.config/opencode/plugins/repowarden-garde.js"
        printf '# repowarden\n' >"$HOME/.claude/skills/repowarden/SKILL.md"
        printf '# repowarden\n' >"$HOME/.config/opencode/skills/repowarden/SKILL.md"
        ;;
    *"agents retirer"*)
        tmp="$(mktemp)"
        jq '
            if (.hooks.PreToolUse // null) != null then
                .hooks.PreToolUse = [
                    .hooks.PreToolUse[] |
                    .hooks = [ (.hooks // [])[] | select(((.command // "") | contains("repowarden garde")) | not) ] |
                    select((.hooks | length) > 0)
                ] |
                if (.hooks.PreToolUse | length) == 0 then del(.hooks.PreToolUse) else . end |
                if ((.hooks // {}) | keys | length) == 0 then del(.hooks) else . end
            else . end
        ' "$HOME/.claude/settings.json" >"$tmp"
        if [ "$(cat "$tmp")" = "{}" ]; then
            rm -f "$tmp" "$HOME/.claude/settings.json"
        else
            mv "$tmp" "$HOME/.claude/settings.json"
        fi
        rm -f "$HOME/.config/opencode/plugins/repowarden-garde.js" "$HOME/.config/opencode/plugins/repowarden-garde-v2.js"
        rm -f "$HOME/.claude/skills/repowarden/SKILL.md" "$HOME/.config/opencode/skills/repowarden/SKILL.md"
        ;;
esac
REP
    chmod +x "$BATS_TEST_TMPDIR/bin/repowarden"
}

# Empreinte des fichiers du HOME d'un module (fichiers + sommes, tres tries) :
# pour comparer l'état avant et après un cycle activer/désactiver (#242)
empreinte() {
    local dossier f
    for dossier in .claude .config/opencode .local/state; do
        if [ -e "$HOME/$dossier" ]; then
            find "$HOME/$dossier" -type f -print | sort | while IFS= read -r f; do
                sha256sum "$f"
            done
        fi
    done | sha256sum | awk '{print $1}'
}

# ~/.kube/cache/ est le cache de kubectl lui-même, pas une configuration
# posée par devzone : hors de l'empreinte
kube_empreinte() {
    find "$HOME/.kube" -path "$HOME/.kube/cache" -prune -o -type f -print 2>/dev/null | sort | while IFS= read -r f; do
        sha256sum "$f"
    done | sha256sum | awk '{print $1}'
}

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
    # renvoie les outils installés (NPM_INSTALLEES). Installation des
    # assistants IA : dure NPM_DUREE secondes, crée claude et opencode
    # factices ; NPM_ECHEC=1 → toujours en échec, les N premières échouent
    # (NPM_IA_ECHECS), avec un journal npm écrit comme le vrai (~/.npm/_logs),
    # ou réussissent sans opencode (NPM_IA_SANS_BINAIRE : binaire optionnel
    # abandonné par npm, #194)
    export NPM_LOG="$BATS_TEST_TMPDIR/npm.log"
    export NPM_INSTALLEES="$BATS_TEST_TMPDIR/installees"
    export NPM_BIN="$BATS_TEST_TMPDIR/bin"
    : >"$NPM_INSTALLEES"
    cat >"$BATS_TEST_TMPDIR/bin/npm" <<'NPM'
#!/usr/bin/env bash
echo "npm $*" >>"$NPM_LOG"
if [ "${1:-}" = install ] && [[ " $* " == *" opencode-ai@"* ]]; then
    sleep "${NPM_DUREE:-0}"
    n="$(grep -c "^npm install.* opencode-ai@" "$NPM_LOG")"
    if [ "${NPM_ECHEC:-0}" = 1 ] || [ "$n" -le "${NPM_IA_ECHECS:-0}" ]; then
        mkdir -p "$HOME/.npm/_logs"
        echo "error code EBADPLATFORM" >"$HOME/.npm/_logs/2026-10-24T11_46_18_245Z-debug-0.log"
        echo "npm error A complete log of this run can be found in: $HOME/.npm/_logs/2026-10-24T11_46_18_245Z-debug-0.log" >&2
        exit 1
    fi
    printf '#!/usr/bin/env bash\necho "2.1.0 (Claude Code)"\n' >"$NPM_BIN/claude"
    if [ "$n" -gt "${NPM_IA_SANS_BINAIRE:-0}" ]; then
        printf '#!/usr/bin/env bash\necho 1.0.0\n' >"$NPM_BIN/opencode"
    else
        printf '#!/usr/bin/env bash\necho "binaire absent" >&2\nexit 1\n' >"$NPM_BIN/opencode"
    fi
    chmod +x "$NPM_BIN/claude" "$NPM_BIN/opencode"
fi
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
    [[ "$output" == *"○ module ia"*"devzone activer ia"* ]] || false
    [[ "$output" == *"○ module kubernetes"*"devzone activer kubernetes"* ]] || false
}

@test "état : identité git absente → nécessaire, avec les deux voies" {
    run bash "$DEVZONE"
    [[ "$output" == *"✖ identité git"*"gh auth login -s workflow"* ]] || false
    [[ "$output" == *"git config --file ~/.config/git/config user.name"* ]] || false
}

@test "état : identité git présente" {
    git config --global user.name "Test" && git config --global user.email "t@example.invalid"
    run bash "$DEVZONE"
    [[ "$output" == *"✔ identité git    Test <t@example.invalid>"* ]] || false
}

@test "état : GitHub non connecté → facultatif" {
    run bash "$DEVZONE"
    [[ "$output" == *"○ GitHub          facultatif"* ]] || false
}

@test "état : GitHub connecté sans permission workflow → à corriger" {
    GH_ETAT=sans run bash "$DEVZONE"
    [[ "$output" == *"⚠ GitHub"*"gh auth refresh -h github.com -s workflow"* ]] || false
}

@test "état : GitHub connecté avec workflow" {
    GH_ETAT=avec run bash "$DEVZONE"
    [[ "$output" == *"✔ GitHub          connecté"* ]] || false
}

@test "état : outil en retard → ⚠ avec la commande devzone appliquer" {
    printf 'repowarden 4.9.2\n' >"$NPM_INSTALLEES"
    run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"⚠ outils          repowarden 4.9.2 installé, $REPOWARDEN_FIGE figé : devzone appliquer"* ]] || false
}

@test "état : versions figées installées → ✔ outils" {
    [ "$(wc -l <<<"$IA_FIGES")" -eq 2 ]
    printf 'repowarden %s\n%s\n' "$REPOWARDEN_FIGE" "$IA_FIGES" >"$NPM_INSTALLEES"
    run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"✔ outils          versions figées"* ]] || false
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
    [[ "$output" == *"✔ module ia"*"actif"* ]] || false
}

@test "activer ia : installe les versions figées, état gardé" {
    run bash "$DEVZONE" activer ia
    [ "$status" -eq 0 ]
    grep -qE "install -g .* @anthropic-ai/claude-code@[0-9.]+ opencode-ai@[0-9.]+$" "$BATS_TEST_TMPDIR/npm.log"
    run bash "$DEVZONE" actif ia
    [ "$status" -eq 0 ]
}

@test "activer ia : binaire optionnel abandonné par npm (opencode ne répond pas) → réinstallé" {
    NPM_IA_SANS_BINAIRE=1 run bash "$DEVZONE" activer ia
    [ "$status" -eq 0 ]
    [ "$(grep -c "^npm install -g .* opencode-ai@" "$BATS_TEST_TMPDIR/npm.log")" -eq 2 ]
    [[ "$output" == *"nouvel essai"* ]] || false
    run opencode --version
    [ "$status" -eq 0 ]
}

@test "activer ia : npm en échec une fois → retenté, réussite" {
    NPM_IA_ECHECS=1 run bash "$DEVZONE" activer ia
    [ "$status" -eq 0 ]
    [ "$(grep -c "^npm install -g .* opencode-ai@" "$BATS_TEST_TMPDIR/npm.log")" -eq 2 ]
    [[ "$output" == *"ia actif"* ]] || false
}

@test "activer ia : échec à chaque essai → 3 essais, code non nul, paquets et journal npm cités" {
    NPM_IA_ECHECS=9 run bash "$DEVZONE" activer ia
    [ "$status" -ne 0 ]
    [ "$(grep -c "^npm install -g .* opencode-ai@" "$BATS_TEST_TMPDIR/npm.log")" -eq 3 ]
    [[ "$output" == *"opencode-ai@"* ]] || false
    [[ "$output" == *".npm/_logs"* ]] || false
    [[ "$output" != *"ia actif"* ]] || false
}

@test "activer ia : installation lente → annoncée, progression pendant, résultat après" {
    NPM_DUREE=3 DEVZONE_PROGRESSION=1 run bash "$DEVZONE" activer ia
    [ "$status" -eq 0 ]
    [[ "$output" == *"installation de Claude Code et opencode (quelques minutes)"*"toujours en cours"*"Claude Code et opencode installés"* ]] || false
}

@test "activer ia : npm en échec → code non nul, paquets et journal npm cités, état en échec" {
    NPM_ECHEC=1 run bash "$DEVZONE" activer ia
    [ "$status" -ne 0 ]
    [[ "$output" == *"échec de l'installation"*"@anthropic-ai/claude-code@"*"opencode-ai@"* ]] || false
    [[ "$output" == *"$HOME/.npm/_logs/2026-10-24T11_46_18_245Z-debug-0.log"* ]] || false
    [[ "$output" != *"ia actif"* ]] || false
    run bash "$DEVZONE"
    [[ "$output" == *"✖ module ia"*"en échec"*"devzone appliquer"* ]] || false
    [[ "$output" != *"✔ module ia"* ]] || false
}

@test "appliquer : échec ia → code non nul ; puis réussite → état actif, plus en échec" {
    bash "$DEVZONE" activer ia
    NPM_ECHEC=1 run bash "$DEVZONE" appliquer
    [ "$status" -ne 0 ]
    run bash "$DEVZONE"
    [[ "$output" == *"✖ module ia"*"en échec"* ]] || false
    run bash "$DEVZONE" appliquer
    [ "$status" -eq 0 ]
    run bash "$DEVZONE"
    [[ "$output" == *"✔ module ia"*"actif"* ]] || false
    [[ "$output" != *"en échec"* ]] || false
}

@test "désactiver ia après un échec : plus marqué en échec" {
    NPM_ECHEC=1 run bash "$DEVZONE" activer ia
    run bash "$DEVZONE"
    [[ "$output" == *"✖ module ia"*"en échec"* ]] || false
    run bash "$DEVZONE" desactiver ia
    [ "$status" -eq 0 ]
    run bash "$DEVZONE"
    [[ "$output" == *"○ module ia"* ]] || false
    [[ "$output" != *"en échec"* ]] || false
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
    [[ "$output" == *"kubernetes désactivé"* ]] || false
}

@test "désactiver ia : cycle activer + désactiver → empreinte des fichiers identique" {
    install_faux_repowarden
    empreinte_avant="$(empreinte)"
    run bash "$DEVZONE" activer ia
    [ "$status" -eq 0 ]
    run bash "$DEVZONE" desactiver ia
    [ "$status" -eq 0 ]
    [ "$(empreinte)" = "$empreinte_avant" ]
}

@test "désactiver ia : hook repowarden retiré, réglages utilisateur et config personnalisée gardés" {
    install_faux_repowarden
    mkdir -p "$HOME/.claude" "$HOME/.config/opencode"
    cat >"$HOME/.claude/settings.json" <<'JSON'
{
  "model": "claude-personnel",
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "repowarden garde"
          }
        ]
      }
    ]
  }
}
JSON
    printf '{"model":"mon-modele"}' >"$HOME/.config/opencode/opencode.jsonc"
    run bash "$DEVZONE" desactiver ia
    [ "$status" -eq 0 ]
    [ -f "$HOME/.claude/settings.json" ]
    grep -q "claude-personnel" "$HOME/.claude/settings.json"
    ! grep -q "repowarden" "$HOME/.claude/settings.json" || false
    [ -f "$HOME/.config/opencode/opencode.jsonc" ]
    [ "$(cat "$HOME/.config/opencode/opencode.jsonc")" = '{"model":"mon-modele"}' ]
}

@test "désactiver kubernetes : metrics-server retiré seulement du contexte marqué, les autres laissés" {
    cat >"$BATS_TEST_TMPDIR/kube-contexts" <<'CTX'
kind-dev
kind-staging
CTX
    cat >"$BATS_TEST_TMPDIR/kube-marcus" <<'CTX'
kind-dev
CTX
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
args="$*"
case "$args" in
    *"get-contexts"*)
        cat "$KUBE_CONTEXTS_FILE"
        ;;
    *"get deployment metrics-server"*)
        contexte=""
        prev=""
        for a in "$@"; do
            if [ "$prev" = "--context" ]; then contexte="$a"; fi
            prev="$a"
        done
        # metrics-server présent sur tous les contextes ; marqué devzone
        # seulement sur ceux de KUBE_MARKED_FILE
        if [[ "$args" == *"-l devzone=installe"* ]]; then
            grep -qxF "$contexte" "$KUBE_MARKED_FILE" && exit 0
            exit 1
        fi
        exit 0
        ;;
    *"delete -f"*)
        contexte=""
        prev=""
        for a in "$@"; do
            if [ "$prev" = "--context" ]; then contexte="$a"; fi
            prev="$a"
        done
        echo "delete -f $contexte" >>"${KUBE_DELETE_LOG}"
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
KUBE
    chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
    export KUBE_CONTEXTS_FILE="$BATS_TEST_TMPDIR/kube-contexts"
    export KUBE_MARKED_FILE="$BATS_TEST_TMPDIR/kube-marcus"
    export KUBE_DELETE_LOG="$BATS_TEST_TMPDIR/kube-delete.log"
    : >"$KUBE_DELETE_LOG"
    run bash "$DEVZONE" desactiver kubernetes
    [ "$status" -eq 0 ]
    [ "$(cat "$KUBE_DELETE_LOG")" = "delete -f kind-dev" ]
    [[ "$output" == *"metrics-server présent sans repère devzone, laissé : kind-staging"* ]] || false
}

@test "désactiver kubernetes : cycle activer + désactiver → ~/.kube identique" {
    mkdir -p "$HOME/.kube"
    touch "$HOME/.kube/config"
    # Ni cluster kind ni cluster de l'hôte : seul ce que devzone pose compte
    printf '#!/usr/bin/env bash\nexit 0\n' >"$BATS_TEST_TMPDIR/bin/kind"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$BATS_TEST_TMPDIR/bin/kubectl"
    chmod +x "$BATS_TEST_TMPDIR/bin/kind" "$BATS_TEST_TMPDIR/bin/kubectl"
    kube_empreinte_avant="$(kube_empreinte)"
    run bash "$DEVZONE" activer kubernetes
    [ "$status" -eq 0 ]
    run bash "$DEVZONE" desactiver kubernetes
    [ "$status" -eq 0 ]
    [ "$(kube_empreinte)" = "$kube_empreinte_avant" ]
}

@test "module inconnu : message et erreur, état intact" {
    run bash "$DEVZONE" activer nexistepas
    [ "$status" -eq 1 ]
    [[ "$output" == *"module inconnu : nexistepas"* ]] || false
    run bash "$DEVZONE" activer
    [ "$status" -eq 1 ]
    run bash "$DEVZONE" actif nexistepas
    [ "$status" -eq 2 ]
}

@test "commande inconnue : erreur" {
    run bash "$DEVZONE" truc
    [ "$status" -eq 1 ]
}

@test "état neuf : tout désactivé, même avec une connexion partagée" {
    mkdir -p "$HOME/.claude" && echo '{}' >"$HOME/.claude/.credentials.json"
    run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"○ module ia"*"devzone activer ia"* ]] || false
    [[ "$output" == *"○ module kubernetes"* ]] || false
    [[ "$output" != *"✔ module ia"* ]] || false
}

@test "actif : code 0 ou 1, sans rien écrire (test de scripts de démarrage)" {
    run bash "$DEVZONE" actif ia
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    bash "$DEVZONE" activer ia >/dev/null
    run bash "$DEVZONE" actif ia
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run bash "$DEVZONE" actif kubernetes
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "connexion Claude partagée : signalée à la création de l'état, une seule fois" {
    mkdir -p "$HOME/.claude" && echo '{}' >"$HOME/.claude/.credentials.json"
    run bash "$DEVZONE" actif ia
    [ "$status" -ne 0 ]
    [[ "$output" == *"connexion Claude Code/opencode partagée trouvée : devzone activer ia pour l'utiliser ici"* ]] || false
    run bash "$DEVZONE" actif ia
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "connexion opencode partagée : signalée à la création de l'état, une seule fois" {
    mkdir -p "$HOME/.local/share/opencode" && echo '{}' >"$HOME/.local/share/opencode/auth.json"
    run bash "$DEVZONE" actif ia
    [ "$status" -ne 0 ]
    [[ "$output" == *"connexion Claude Code/opencode partagée trouvée"* ]] || false
    run bash "$DEVZONE" actif ia
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "connexion partagée : jamais signalée quand l'état est repris (migration)" {
    mkdir -p "$HOME/.config/devzone" "$HOME/.claude"
    printf 'ia=on\nkubernetes=on\n' >"$HOME/.config/devzone/modules"
    echo '{}' >"$HOME/.claude/.credentials.json"
    run bash "$DEVZONE" actif ia
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "migration : ancien état global repris une fois, source supprimée" {
    mkdir -p "$HOME/.config/devzone"
    printf 'ia=on\nkubernetes=on\n' >"$HOME/.config/devzone/modules"
    run bash "$DEVZONE" actif ia
    [ "$status" -eq 0 ]
    [ -f "$DEVZONE_RACINE/.devzone.modules" ]
    [ ! -e "$HOME/.config/devzone/modules" ]
    grep -qx 'ia=on' "$DEVZONE_RACINE/.devzone.modules"
}

@test "migration : second devzone (source déjà déplacée) → valeurs par défaut" {
    mkdir -p "$HOME/.config/devzone"
    printf 'ia=on\nkubernetes=on\n' >"$HOME/.config/devzone/modules"
    bash "$DEVZONE" actif ia
    export DEVZONE_RACINE="$BATS_TEST_TMPDIR/racine2"
    mkdir -p "$DEVZONE_RACINE/workspace"
    run bash "$DEVZONE" actif ia
    [ "$status" -ne 0 ]
    [ -f "$DEVZONE_RACINE/.devzone.modules" ]
    grep -qx 'ia=off' "$DEVZONE_RACINE/.devzone.modules"
    grep -qx 'kubernetes=off' "$DEVZONE_RACINE/.devzone.modules"
}

@test "appliquer : installe ia seulement s'il est actif" {
    run bash "$DEVZONE" appliquer
    [ "$status" -eq 0 ]
    ! grep -q "install -g" "$BATS_TEST_TMPDIR/npm.log" || false
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
    [[ "$output" == *"repowarden 4.9.2 → $REPOWARDEN_FIGE"* ]] || false
}

@test "activer ia : garde-fou repowarden branché pour Claude Code et opencode" {
    run bash "$DEVZONE" activer ia
    [ "$status" -eq 0 ]
    [[ "$output" == *"garde-fou repowarden actif"* ]] || false
    grep -qx "repowarden agents init --global" "$BATS_TEST_TMPDIR/repowarden.log"
}

@test "garde-fou : rebranché à chaque appliquer avec ia actif, jamais avec ia désactivé" {
    bash "$DEVZONE" activer ia
    rm -f "$BATS_TEST_TMPDIR/repowarden.log"
    bash "$DEVZONE" appliquer
    grep -qx "repowarden agents init --global" "$BATS_TEST_TMPDIR/repowarden.log"
    rm -f "$BATS_TEST_TMPDIR/repowarden.log"
    bash "$DEVZONE" desactiver ia
    grep -qx "repowarden agents retirer --global" "$BATS_TEST_TMPDIR/repowarden.log"
    rm -f "$BATS_TEST_TMPDIR/repowarden.log"
    bash "$DEVZONE" appliquer
    [ ! -e "$BATS_TEST_TMPDIR/repowarden.log" ]
}

@test "garde-fou : repowarden absent -> ia activé quand même, commande à lancer" {
    rm "$BATS_TEST_TMPDIR/bin/repowarden"
    PATH="$BATS_TEST_TMPDIR/bin:/usr/bin:/bin" run bash "$DEVZONE" activer ia
    [ "$status" -eq 0 ]
    [[ "$output" == *"garde-fou repowarden non branché"*"repowarden agents init --global"* ]] || false
    grep -q "install -g" "$BATS_TEST_TMPDIR/npm.log"
}

@test "activer ia : configuration opencode absente -> écrite depuis le modèle" {
    run bash "$DEVZONE" activer ia
    [ "$status" -eq 0 ]
    [ -f "$HOME/.config/opencode/opencode.jsonc" ]
    grep -q '^// devzone : configuration opencode par défaut' "$HOME/.config/opencode/opencode.jsonc"
    grep -q '"model": "opencode/big-pickle"' "$HOME/.config/opencode/opencode.jsonc"
    grep -q '"compaction": {' "$HOME/.config/opencode/opencode.jsonc"
    [[ "$output" == *"opencode : configuration par défaut écrite"* ]] || false
}

@test "activer ia : configuration opencode avec le repère et différente -> mise à jour" {
    mkdir -p "$HOME/.config/opencode"
    printf '// devzone : configuration opencode par défaut (ancienne)\n{"model":"ancien"}\n' >"$HOME/.config/opencode/opencode.jsonc"
    run bash "$DEVZONE" activer ia
    [ "$status" -eq 0 ]
    grep -q '"model": "opencode/big-pickle"' "$HOME/.config/opencode/opencode.jsonc"
    [[ "$output" == *"opencode : configuration par défaut mise à jour"* ]] || false
}

@test "activer ia : configuration opencode avec seulement \$schema -> remplacée" {
    mkdir -p "$HOME/.config/opencode"
    printf '{\n  "$schema": "https://opencode.ai/config.json"\n}\n' >"$HOME/.config/opencode/opencode.jsonc"
    run bash "$DEVZONE" activer ia
    [ "$status" -eq 0 ]
    grep -q '^// devzone : configuration opencode par défaut' "$HOME/.config/opencode/opencode.jsonc"
    grep -q '"model": "opencode/big-pickle"' "$HOME/.config/opencode/opencode.jsonc"
    [[ "$output" == *"opencode : configuration par défaut mise à jour"* ]] || false
}

@test "activer ia : configuration opencode sans le repère -> gardée" {
    mkdir -p "$HOME/.config/opencode"
    printf '{"model":"mon-modele"}\n' >"$HOME/.config/opencode/opencode.jsonc"
    run bash "$DEVZONE" activer ia
    [ "$status" -eq 0 ]
    [ "$(cat "$HOME/.config/opencode/opencode.jsonc")" = '{"model":"mon-modele"}' ]
    [[ "$output" == *"opencode : configuration personnalisée, gardée"* ]] || false
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

@test "devzone --help cite test-bash32" {
    run bash "$DEVZONE" --help
    [[ "$output" == *"test-bash32"* ]] || false
}

@test ".gitignore : état et échec invisibles par git status" {
    dossier="$BATS_TEST_TMPDIR/git"
    mkdir -p "$dossier" && cd "$dossier" || return 1
    git init -q
    cp "$BATS_TEST_DIRNAME/../../.gitignore" ./.gitignore
    printf "ia=on\nkubernetes=on\n" >.devzone.modules
    printf "gitlab\n" >.devzone.modules-echec-gitlab
    run git status --porcelain
    [ "$status" -eq 0 ]
    [ -z "$(grep "\.devzone\.modules" <<<"$output")" ]
}
