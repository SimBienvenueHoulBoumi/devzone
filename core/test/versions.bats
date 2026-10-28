#!/usr/bin/env bats
# Script versions.sh : comparaison des versions figées du conteneur avec npm
# (simulé) et application ciblée d'une montée.

setup() {
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin" \
        "$BATS_TEST_TMPDIR/dz/core/scripts" "$BATS_TEST_TMPDIR/dz/.devcontainer"
    cp "$RACINE/core/scripts/versions.sh" "$BATS_TEST_TMPDIR/dz/core/scripts/"
    VERSIONS="$BATS_TEST_TMPDIR/dz/core/scripts/versions.sh"
    POST_CREATE="$BATS_TEST_TMPDIR/dz/.devcontainer/post-create.sh"
    DEVZONE="$BATS_TEST_TMPDIR/dz/.devcontainer/devzone"
    cat >"$POST_CREATE" <<'EOFPOST'
#!/usr/bin/env bash
# repowarden, version figée
npm install -g repowarden@4.12.0
repowarden install --global --lang fr
EOFPOST
    cat >"$DEVZONE" <<'EOFDZ'
#!/usr/bin/env bash
# Claude Code
IA_CLAUDE=@anthropic-ai/claude-code@2.1.286
# opencode
IA_OPENCODE=opencode-ai@1.18.34
IA_PAQUETS=("$IA_CLAUDE" "$IA_OPENCODE")
IA_NOMS=("${IA_CLAUDE%@*}" "${IA_OPENCODE%@*}")
EOFDZ
    chmod +x "$DEVZONE"
    export NPM_VERSIONS="$BATS_TEST_TMPDIR/versions"
    export NPM_INSTALLEES="$BATS_TEST_TMPDIR/installees"
    : >"$NPM_INSTALLEES"
    cat >"$BATS_TEST_TMPDIR/bin/npm" <<'EOFNPM'
#!/usr/bin/env bash
if [ "${1:-}" = view ] && [ "${3:-}" = version ]; then
    awk -v p="$2" '$1 == p { print $2; trouve = 1 } END { exit trouve ? 0 : 1 }' "$NPM_VERSIONS"
elif [ "${1:-}" = ls ] && [ "${2:-}" = -g ]; then
    printf '{"dependencies":{'
    sep=""
    while read -r p v; do
        [ -n "$p" ] || continue
        printf '%s"%s":{"version":"%s"}' "$sep" "$p" "$v"
        sep=","
    done <"$NPM_INSTALLEES"
    printf '}}\n'
else
    exit 2
fi
EOFNPM
    chmod +x "$BATS_TEST_TMPDIR/bin/npm"
    export GH_TICKETS="$BATS_TEST_TMPDIR/tickets.json"
    cat >"$BATS_TEST_TMPDIR/bin/gh" <<'EOFGH'
#!/usr/bin/env bash
if [ "${1:-}" = issue ] && [ "${2:-}" = list ]; then
    expression='.[]'
    while [ "$#" -gt 0 ]; do
        if [ "$1" = --jq ]; then
            expression="$2"
            shift
        fi
        shift
    done
    jq -r "$expression" "$GH_TICKETS"
else
    exit 2
fi
EOFGH
    chmod +x "$BATS_TEST_TMPDIR/bin/gh"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

npm_versions() {
    : >"$NPM_VERSIONS"
    while [ "$#" -gt 0 ]; do
        printf '%s %s\n' "$1" "$2" >>"$NPM_VERSIONS"
        shift 2
    done
}

npm_installees() {
    : >"$NPM_INSTALLEES"
    while [ "$#" -gt 0 ]; do
        printf '%s %s\n' "$1" "$2" >>"$NPM_INSTALLEES"
        shift 2
    done
}

tickets_ouverts() {
    local separateur=""
    printf '[' >"$GH_TICKETS"
    while [ "$#" -gt 0 ]; do
        printf '%s{"number":%s,"title":"%s","author":{"login":"%s"}}' "$separateur" "$1" "$2" "$3" >>"$GH_TICKETS"
        separateur=","
        shift 3
    done
    printf ']\n' >>"$GH_TICKETS"
}

@test "tout à jour : aucune ligne" {
    npm_versions repowarden 4.12.0 @anthropic-ai/claude-code 2.1.286 opencode-ai 1.18.34
    run bash "$VERSIONS"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "--installees tout à jour : aucune ligne" {
    npm_installees repowarden 4.12.0 @anthropic-ai/claude-code 2.1.286 opencode-ai 1.18.34
    run bash "$VERSIONS" --installees
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "--installees repowarden en retard : une ligne paquet figée installée" {
    npm_installees repowarden 4.9.2 @anthropic-ai/claude-code 2.1.286 opencode-ai 1.18.34
    run bash "$VERSIONS" --installees
    [ "$status" -eq 0 ]
    [ "$output" = "repowarden 4.12.0 4.9.2" ]
}

@test "--installees outil IA non installé : pas listé" {
    npm_installees repowarden 4.12.0
    run bash "$VERSIONS" --installees
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "un paquet en retard : une ligne paquet ancienne nouvelle" {
    npm_versions repowarden 4.13.0 @anthropic-ai/claude-code 2.1.286 opencode-ai 1.18.34
    run bash "$VERSIONS"
    [ "$status" -eq 0 ]
    [ "$output" = "repowarden 4.12.0 4.13.0" ]
}

@test "paquet IA scopé en retard : reconnu sur sa ligne IA_CLAUDE" {
    npm_versions repowarden 4.12.0 @anthropic-ai/claude-code 2.2.0 opencode-ai 1.18.34
    run bash "$VERSIONS"
    [ "$status" -eq 0 ]
    [ "$output" = "@anthropic-ai/claude-code 2.1.286 2.2.0" ]
}

@test "paquet IA sans scope en retard : reconnu sur sa ligne IA_OPENCODE" {
    npm_versions repowarden 4.12.0 @anthropic-ai/claude-code 2.1.286 opencode-ai 1.19.0
    run bash "$VERSIONS"
    [ "$status" -eq 0 ]
    [ "$output" = "opencode-ai 1.18.34 1.19.0" ]
}

@test "version npm plus ancienne que la version figée : pas de retour en arrière" {
    npm_versions repowarden 4.11.0 @anthropic-ai/claude-code 2.1.286 opencode-ai 1.18.34
    run bash "$VERSIONS"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "--appliquer repowarden : seule la version de post-create.sh change" {
    avant="$(cat "$DEVZONE")"
    run bash "$VERSIONS" --appliquer repowarden 4.13.0
    [ "$status" -eq 0 ]
    grep -qx 'npm install -g repowarden@4.13.0' "$POST_CREATE"
    [ "$(cat "$DEVZONE")" = "$avant" ]
}

@test "--appliquer un paquet IA : seule sa version change, l'autre reste" {
    run bash "$VERSIONS" --appliquer @anthropic-ai/claude-code 2.2.0
    [ "$status" -eq 0 ]
    grep -qx 'IA_CLAUDE=@anthropic-ai/claude-code@2.2.0' "$DEVZONE"
    grep -qx 'IA_OPENCODE=opencode-ai@1.18.34' "$DEVZONE"
    grep -qxF 'IA_PAQUETS=("$IA_CLAUDE" "$IA_OPENCODE")' "$DEVZONE"
    grep -qx 'npm install -g repowarden@4.12.0' "$POST_CREATE"
}

@test "--appliquer opencode-ai : la version scopée reste intacte" {
    run bash "$VERSIONS" --appliquer opencode-ai 1.19.0
    [ "$status" -eq 0 ]
    grep -qx 'IA_CLAUDE=@anthropic-ai/claude-code@2.1.286' "$DEVZONE"
    grep -qx 'IA_OPENCODE=opencode-ai@1.19.0' "$DEVZONE"
}

@test "vrai fichier devzone : les deux assistants IA sont lus par versions.sh" {
    npm_versions repowarden 999.0.0 @anthropic-ai/claude-code 999.0.0 opencode-ai 999.0.0
    run bash "$RACINE/core/scripts/versions.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"@anthropic-ai/claude-code "*" 999.0.0"* ]] || false
    [[ "$output" == *"opencode-ai "*" 999.0.0"* ]] || false
}

@test "deux montées simultanées (Claude Code, opencode) : fusionnées l'une après l'autre sans conflit" {
    # Le vrai fichier devzone, pour vérifier sa disposition
    cp "$RACINE/.devcontainer/devzone" "$DEVZONE"
    export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid \
        GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
    cd "$BATS_TEST_TMPDIR/dz"
    git init -q
    base="$(git branch --show-current)"
    git add .devcontainer core
    git commit -qm base
    git checkout -qb claude
    bash "$VERSIONS" --appliquer @anthropic-ai/claude-code 999.0.0
    git commit -qam claude
    git checkout -q "$base"
    git checkout -qb opencode
    bash "$VERSIONS" --appliquer opencode-ai 999.1.0
    git commit -qam opencode
    git checkout -q "$base"
    git merge -q --no-ff -m "fusion claude" claude
    run git merge --no-ff -m "fusion opencode" opencode
    [ "$status" -eq 0 ]
    grep -qx 'IA_CLAUDE=@anthropic-ai/claude-code@999.0.0' "$DEVZONE"
    grep -qx 'IA_OPENCODE=opencode-ai@999.1.0' "$DEVZONE"
}

@test "--appliquer garde le droit d'exécution de devzone" {
    [ -x "$DEVZONE" ]
    run bash "$VERSIONS" --appliquer opencode-ai 1.19.0
    [ "$status" -eq 0 ]
    [ -x "$DEVZONE" ]
}

@test "--appliquer : paquet inconnu refusé, fichiers intacts" {
    avant_post="$(cat "$POST_CREATE")"
    avant_devzone="$(cat "$DEVZONE")"
    run bash "$VERSIONS" --appliquer nexistepas 1.0.0
    [ "$status" -ne 0 ]
    [[ "$output" == *"paquet inconnu"* ]] || false
    [ "$(cat "$POST_CREATE")" = "$avant_post" ]
    [ "$(cat "$DEVZONE")" = "$avant_devzone" ]
}

@test "--appliquer sans version : usage rappelé" {
    run bash "$VERSIONS" --appliquer repowarden
    [ "$status" -ne 0 ]
    [[ "$output" == *"--appliquer"* ]] || false
}

@test "--ticket-existant : ticket de l'App trouvé (numéro et titre)" {
    tickets_ouverts 42 "repowarden 9.9.9 dans le conteneur" "app/repowarden-devzone"
    run bash "$VERSIONS" --ticket-existant repowarden "app/repowarden-devzone"
    [ "$status" -eq 0 ]
    [ "$output" = $'42	repowarden 9.9.9 dans le conteneur' ]
}

@test "--ticket-existant : même titre ouvert par un autre auteur ignoré" {
    tickets_ouverts 43 "repowarden 9.9.9 dans le conteneur" "intrus"
    run bash "$VERSIONS" --ticket-existant repowarden "app/repowarden-devzone"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "--ticket-existant : forme [bot] de l'auteur ignorée" {
    tickets_ouverts 45 "repowarden 9.9.9 dans le conteneur" "repowarden-devzone[bot]"
    run bash "$VERSIONS" --ticket-existant repowarden "app/repowarden-devzone"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "--ticket-existant : titre d'un autre paquet ignoré" {
    tickets_ouverts 44 "opencode-ai 9.9.9 dans le conteneur" "app/repowarden-devzone"
    run bash "$VERSIONS" --ticket-existant repowarden "app/repowarden-devzone"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "workflow versions : conception proposée, jamais retenue (le mainteneur la reprend)" {
    workflow="$RACINE/.github/workflows/versions.yml"
    grep -q '^ *## Conception proposée$' "$workflow"
    ! grep -q '^ *## Conception retenue' "$workflow" || false
}
