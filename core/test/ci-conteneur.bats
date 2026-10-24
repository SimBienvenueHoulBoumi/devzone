#!/usr/bin/env bats
# Tests du conteneur exigés pour merger : décision par chemin (lancer ou non
# fonctionnel, cli, windows) et vérification de synthèse tests-conteneur
# (core/test/ci-conteneur.sh, workflow fonctionnel.yml, .repowarden.conf).

setup() {
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$RACINE/core/test/ci-conteneur.sh"
    WORKFLOW="$RACINE/.github/workflows/fonctionnel.yml"
}

@test "a-tester : documentation seule → false" {
    run bash "$SCRIPT" a-tester <<<$'README.md\ndocs/reference.md\n.github/workflows/release.yml'
    [ "$status" -eq 0 ]
    [ "$output" = false ]
}

@test "a-tester : aucun fichier → false" {
    run bash "$SCRIPT" a-tester </dev/null
    [ "$status" -eq 0 ]
    [ "$output" = false ]
}

@test "a-tester : conteneur, tests, CLI, .gitattributes, package.json, workflow → true" {
    for f in .devcontainer/devzone core/scripts/lancer.sh core/test/cli.bats core/devzone Makefile .gitattributes package.json .github/workflows/fonctionnel.yml; do
        run bash "$SCRIPT" a-tester <<<$'README.md\n'"$f"
        [ "$status" -eq 0 ]
        [ "$output" = true ] || { echo "non détecté : $f"; false; }
    done
}

@test "a-tester : nom proche d'un chemin suivi (docs/Makefile.md, package.json.bak) → false" {
    run bash "$SCRIPT" a-tester <<<$'docs/Makefile.md\npackage.json.bak\nautre/core/x'
    [ "$status" -eq 0 ]
    [ "$output" = false ]
}

@test "synthese : rien à tester (jobs sautés) → réussite" {
    run bash "$SCRIPT" synthese false success skipped skipped skipped
    [ "$status" -eq 0 ]
    [[ "$output" == *"rien à tester"* ]] || false
}

@test "synthese : fonctionnel, cli et windows réussis → réussite" {
    run bash "$SCRIPT" synthese true success success success success
    [ "$status" -eq 0 ]
}

@test "synthese : un job en échec → échec, avec son nom" {
    run bash "$SCRIPT" synthese true success success failure success
    [ "$status" -ne 0 ]
    [[ "$output" == *"cli"*"failure"* ]] || false
}

@test "synthese : un job annulé ou en cours d'abandon → échec" {
    run bash "$SCRIPT" synthese true success cancelled success success
    [ "$status" -ne 0 ]
    [[ "$output" == *"fonctionnel"*"cancelled"* ]] || false
}

@test "synthese : job sauté alors qu'il fallait tester → échec" {
    run bash "$SCRIPT" synthese true success success success skipped
    [ "$status" -ne 0 ]
    [[ "$output" == *"windows"*"skipped"* ]] || false
}

@test "synthese : détection des changements en échec → échec" {
    run bash "$SCRIPT" synthese "" failure skipped skipped skipped
    [ "$status" -ne 0 ]
    [[ "$output" == *"changements"*"failure"* ]] || false
}

@test "synthese : arguments manquants → usage, échec" {
    run bash "$SCRIPT" synthese true success
    [ "$status" -ne 0 ]
    [[ "$output" == *usage* ]] || false
}

@test "fonctionnel.yml : aucun filtre paths, lancé sur chaque PR" {
    run grep -nE '^[[:space:]]*paths:' "$WORKFLOW"
    [ "$status" -ne 0 ]
    grep -qE '^  pull_request:' "$WORKFLOW"
}

@test "fonctionnel.yml : synthèse tests-conteneur toujours lancée, après fonctionnel, cli et windows" {
    # Bloc du job tests-conteneur : de sa ligne à la fin du fichier ou au job suivant
    bloc="$(awk '/^  tests-conteneur:/ { dans = 1; print; next } dans && /^  [a-z-]+:/ { exit } dans { print }' "$WORKFLOW")"
    [ -n "$bloc" ]
    [[ "$bloc" == *"if: always()"* ]] || false
    [[ "$bloc" == *"needs: [changements, fonctionnel, cli, windows]"* ]] || false
    [[ "$bloc" == *"bash core/test/ci-conteneur.sh synthese"* ]] || false
    for job in fonctionnel cli windows; do
        awk -v j="  $job:" '$0 == j { dans = 1; next } dans && /^  [a-z-]+:/ { exit } dans { print }' "$WORKFLOW" |
            grep -q "if: needs.changements.outputs.tester == 'true'" || { echo "job $job lancé sans la décision par chemin"; false; }
    done
}

@test ".repowarden.conf : tests-conteneur exigé pour merger" {
    exigees="$(git config -f "$RACINE/.repowarden.conf" repowarden.requiredChecks)"
    [[ ",$exigees," == *",repowarden,"* ]] || false
    [[ ",$exigees," == *",tests-conteneur,"* ]] || false
}
