#!/usr/bin/env bats
# devzone agent : configuration effective (opencode.jsonc + configurer) pour gh (#367).

perm_pour() {
    local f="$1" cmd="$2" val="" key
    while IFS= read -r key; do
        if [[ $cmd == $key ]]; then
            val="$(jq -r --arg k "$key" '.permission.bash[$k]' "$f")"
        fi
    done < <(jq -r '.permission.bash | keys_unsorted[]' "$f")
    printf '%s' "$val"
}

setup() {
    load commun
    relais_docker_isole
    kube_isole
    unset OPENCODE_CONFIG_CONTENT
    export DEVZONE_RACINE="$BATS_TEST_TMPDIR/racine"
    mkdir -p "$DEVZONE_RACINE/workspace"
    export DEVZONE_AGENT_ETAT="$BATS_TEST_TMPDIR/etat"
    mkdir -p "$DEVZONE_AGENT_ETAT"
}

@test "agent : config effective permet la lecture gh" {
    ICI="$BATS_TEST_DIRNAME/../../.devcontainer"
    sed '/^[[:space:]]*\/\//d' "$ICI/opencode.jsonc" >"$BATS_TEST_TMPDIR/oc.json"
    bash -c '
        set -uo pipefail
        export DEVZONE_RACINE="'"$DEVZONE_RACINE"'"
        export DEVZONE_AGENT_ETAT="'"$DEVZONE_AGENT_ETAT"'"
        ICI="'"$ICI"'"
        . "$ICI/agent-erreurs.sh"
        . "$ICI/agent-droits.sh"
        . "$ICI/agent-session.sh"
        refuse() { echo "devzone agent : $*" >&2; exit 2; }
        unset OPENCODE_CONFIG_CONTENT
        configurer
        printf "%s\n" "$OPENCODE_CONFIG_CONTENT"
    ' >"$BATS_TEST_TMPDIR/cfg.json"
    jq -s '.[0] * .[1]' "$BATS_TEST_TMPDIR/oc.json" "$BATS_TEST_TMPDIR/cfg.json" >"$BATS_TEST_TMPDIR/eff.json"
    for c in "gh issue view 1 --comments" "gh pr checks 2" "gh run view 3"; do
        [ "$(perm_pour "$BATS_TEST_TMPDIR/eff.json" "$c")" = "allow" ] || { echo "devrait etre permis : $c"; false; }
    done
}

@test "agent : config effective refuse l'ecriture gh et les secrets" {
    ICI="$BATS_TEST_DIRNAME/../../.devcontainer"
    sed '/^[[:space:]]*\/\//d' "$ICI/opencode.jsonc" >"$BATS_TEST_TMPDIR/oc.json"
    bash -c '
        set -uo pipefail
        export DEVZONE_RACINE="'"$DEVZONE_RACINE"'"
        export DEVZONE_AGENT_ETAT="'"$DEVZONE_AGENT_ETAT"'"
        ICI="'"$ICI"'"
        . "$ICI/agent-erreurs.sh"
        . "$ICI/agent-droits.sh"
        . "$ICI/agent-session.sh"
        refuse() { echo "devzone agent : $*" >&2; exit 2; }
        unset OPENCODE_CONFIG_CONTENT
        configurer
        printf "%s\n" "$OPENCODE_CONFIG_CONTENT"
    ' >"$BATS_TEST_TMPDIR/cfg.json"
    jq -s '.[0] * .[1]' "$BATS_TEST_TMPDIR/oc.json" "$BATS_TEST_TMPDIR/cfg.json" >"$BATS_TEST_TMPDIR/eff.json"
    for c in "gh issue create" "gh issue comment" "gh pr merge" "gh api repos" "gh workflow run" "gh release create" "gh auth token"; do
        [ "$(perm_pour "$BATS_TEST_TMPDIR/eff.json" "$c")" = "deny" ] || { echo "devrait etre refuse : $c"; false; }
    done
}
