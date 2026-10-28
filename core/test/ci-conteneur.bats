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
    run bash "$SCRIPT" synthese false success skipped skipped skipped skipped success
    [ "$status" -eq 0 ]
    [[ "$output" == *"rien à tester"* ]] || false
}

@test "synthese : rien à tester, mais tests bats en échec → échec, avec son nom" {
    run bash "$SCRIPT" synthese false success skipped skipped skipped skipped failure
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ bats : failure"* ]] || false
}

@test "synthese : tests bats en échec, tout le reste réussi → échec" {
    run bash "$SCRIPT" synthese true success success success success success failure
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ bats : failure"* ]] || false
}

@test "synthese : tests bats annulés ou sautés → échec" {
    for resultat in cancelled skipped; do
        run bash "$SCRIPT" synthese false success skipped skipped skipped skipped "$resultat"
        [ "$status" -ne 0 ]
        [[ "$output" == *"✖ bats : $resultat"* ]] || false
    done
}

@test "synthese : fonctionnel, cli, windows, ia-arm64 et bats réussis → réussite" {
    run bash "$SCRIPT" synthese true success success success success success success
    [ "$status" -eq 0 ]
    [[ "$output" == *"✔ ia-arm64 : success"* ]] || false
    [[ "$output" == *"✔ bats : success"* ]] || false
}

@test "synthese : un job en échec → échec, avec son nom" {
    run bash "$SCRIPT" synthese true success success failure success success success
    [ "$status" -ne 0 ]
    [[ "$output" == *"cli"*"failure"* ]] || false
}

@test "synthese : assistants IA non installables sur arm64 (ia-arm64 en échec) → échec, avec son nom" {
    run bash "$SCRIPT" synthese true success success success success failure success
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ ia-arm64 : failure"* ]] || false
}

@test "synthese : un job annulé ou en cours d'abandon → échec" {
    run bash "$SCRIPT" synthese true success cancelled success success success success
    [ "$status" -ne 0 ]
    [[ "$output" == *"fonctionnel"*"cancelled"* ]] || false
}

@test "synthese : job sauté alors qu'il fallait tester → échec" {
    run bash "$SCRIPT" synthese true success success success skipped success success
    [ "$status" -ne 0 ]
    [[ "$output" == *"windows"*"skipped"* ]] || false
}

@test "synthese : détection des changements en échec → échec" {
    run bash "$SCRIPT" synthese "" failure skipped skipped skipped skipped success
    [ "$status" -ne 0 ]
    [[ "$output" == *"changements"*"failure"* ]] || false
}

@test "synthese : arguments manquants → usage, échec" {
    run bash "$SCRIPT" synthese true success
    [ "$status" -ne 0 ]
    [[ "$output" == *usage* ]] || false
    run bash "$SCRIPT" synthese true success success success success success
    [ "$status" -ne 0 ]
    [[ "$output" == *usage* ]] || false
}

@test "fonctionnel.yml : job ia-arm64 sur ubuntu-24.04-arm, décision par chemin, claude et opencode vérifiés" {
    bloc="$(awk '/^  ia-arm64:/ { dans = 1; print; next } dans && /^  [a-z0-9-]+:/ { exit } dans { print }' "$WORKFLOW")"
    [ -n "$bloc" ]
    [[ "$bloc" == *"runs-on: ubuntu-24.04-arm"* ]] || false
    [[ "$bloc" == *"if: needs.changements.outputs.tester == 'true'"* ]] || false
    [[ "$bloc" == *"devzone activer ia"* ]] || false
    [[ "$bloc" == *"claude --version"* ]] || false
    [[ "$bloc" == *"opencode --version"* ]] || false
}

@test "fonctionnel.yml : aucun filtre paths, lancé sur chaque PR" {
    run grep -nE '^[[:space:]]*paths:' "$WORKFLOW"
    [ "$status" -ne 0 ]
    grep -qE '^  pull_request:' "$WORKFLOW"
}

@test "fonctionnel.yml : job bats sur ubuntu et macOS (bash 3.2), sur chaque PR sans décision par chemin" {
    bloc="$(awk '/^  bats:/ { dans = 1; print; next } dans && /^  [a-z0-9-]+:/ { exit } dans { print }' "$WORKFLOW")"
    [ -n "$bloc" ]
    [[ "$bloc" == *"os: [ubuntu-latest, macos-latest]"* ]] || false
    [[ "$bloc" == *'runs-on: ${{ matrix.os }}'* ]] || false
    [[ "$bloc" != *"needs.changements"* ]] || { echo "bats doit tourner sur chaque PR"; false; }
    [[ "$bloc" == *"bats@"* ]] || false
    # ubuntu : toute la suite ; macOS : /bin/bash (3.2) en tête du PATH, vérifié
    [[ "$bloc" == *"bats core/test/"* ]] || false
    [[ "$bloc" == *"ln -s /bin/bash"* ]] || false
    [[ "$bloc" == *'BASH_VERSINFO[0]}" = 3'* ]] || false
    for f in cli.bats versions.bats ci-conteneur.bats; do
        [[ "$bloc" == *"core/test/$f"* ]] || { echo "non lancé sous macOS : $f"; false; }
    done
}

@test "fonctionnel.yml : lancé aussi sur chaque push de develop et main (bats seul)" {
    grep -qE '^  push:' "$WORKFLOW"
    grep -qE '^    branches: \[develop, main\]' "$WORKFLOW"
    grep -qE 'push\) tester=false' "$WORKFLOW"
}

@test "fonctionnel.yml : synthèse tests-conteneur toujours lancée, après fonctionnel, cli, windows, ia-arm64 et bats" {
    # Bloc du job tests-conteneur : de sa ligne à la fin du fichier ou au job suivant
    bloc="$(awk '/^  tests-conteneur:/ { dans = 1; print; next } dans && /^  [a-z0-9-]+:/ { exit } dans { print }' "$WORKFLOW")"
    [ -n "$bloc" ]
    [[ "$bloc" == *"if: always()"* ]] || false
    [[ "$bloc" == *"needs: [changements, fonctionnel, cli, windows, ia-arm64, bats]"* ]] || false
    [[ "$bloc" == *"bash core/test/ci-conteneur.sh synthese"* ]] || false
    [[ "$bloc" == *'"$WINDOWS" "$IA_ARM64" "$BATS"'* ]] || false
    [[ "$bloc" == *'BATS: ${{ needs.bats.result }}'* ]] || false
    for job in fonctionnel cli windows ia-arm64; do
        awk -v j="  $job:" '$0 == j { dans = 1; next } dans && /^  [a-z0-9-]+:/ { exit } dans { print }' "$WORKFLOW" |
            grep -q "if: needs.changements.outputs.tester == 'true'" || { echo "job $job lancé sans la décision par chemin"; false; }
    done
}

# Sous bash 3.2 (macOS), un [[ … ]] en échec au milieu d'un test ne le fait
# pas échouer (errexit ignoré avant bash 4.1), et « ! commande » jamais, quel
# que soit bash : chaque condition de ce genre finit par || false
@test "tests bats : aucune condition [[ … ]] ni ! commande sans || false (bash 3.2)" {
    run grep -nE '^[[:space:]]*\[\[.*\]\][[:space:]]*$' "$RACINE"/core/test/*.bats
    [ "$status" -ne 0 ] || { echo "$output"; false; }
    run grep -nE '^[[:space:]]*! ' "$RACINE"/core/test/*.bats
    [ -z "$(grep -v '|| false[[:space:]]*$' <<<"$output")" ] || { echo "$output"; false; }
}

# bash 3.2 lit l'apostrophe d'un commentaire placé dans un $( … ) multiligne
# comme une chaîne ouverte : le fichier .bats entier ne se charge plus (#210)
@test "tests bats : aucune apostrophe dans un commentaire à l'intérieur d'un \$( … ) multiligne" {
    run awk '/\$\($/ { dans = 1; next } dans && /^[[:space:]]*\)/ { dans = 0 } dans && /^[[:space:]]*#.*'\''/ { print FILENAME ":" FNR }' "$RACINE"/core/test/*.bats
    [ -z "$output" ] || { echo "apostrophe dans un commentaire de \$( … ) : $output"; false; }
}

@test ".repowarden.conf : tests-conteneur exigé pour merger" {
    exigees="$(git config -f "$RACINE/.repowarden.conf" repowarden.requiredChecks)"
    [[ ",$exigees," == *",repowarden,"* ]] || false
    [[ ",$exigees," == *",tests-conteneur,"* ]] || false
}
