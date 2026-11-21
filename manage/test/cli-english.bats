#!/usr/bin/env bats
# cli-english.bats: the help of the CLI is in English (#774). The help of the
# workstation (devzone --help, devzone workspace help) and of the pod
# (.devcontainer/devzone --help) holds no accented letter and no common French
# word. Re-introducing one makes these tests fail.
#
# The help of « devzone agent » is NOT checked here yet: its words (--modele,
# etat, liberer, --tous) are renamed by another batch of #774 (the agent);
# add « devzone agent » to this file once that batch is merged.

setup() {
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    unset DEVZONE_WORKSPACE
}

# Common French words that must not appear (whole words, any case)
FRENCH_WORDS='dossier|fichier|fichiers|demarrer|lance|lancer|cree|retire|pour|avec|sans|une|des|les|dans|est|sont|aucun|aucune|chaque|conteneur|poste|ou|et|du|le|la'

# french_found <text>: prints the offending lines and returns 0 when the text
# holds an accented letter (UTF-8 lead bytes C3 and C5 for Latin letters) or a
# French word; returns 1 for a clean text.
french_found() {
    local found=1
    if printf '%s\n' "$1" | LC_ALL=C grep -nE $'\xc3[\x80-\xbf]|\xc5[\x92\x93]'; then found=0; fi
    if printf '%s\n' "$1" | LC_ALL=C grep -niwE "$FRENCH_WORDS"; then found=0; fi
    return "$found"
}

@test "cli-english: the detector finds accents and French words" {
    french_found "crée un devzone"
    french_found "démarrer"
    french_found "Retire le dossier"
    french_found "start devzone pour le dossier"
    french_found "œuvre"
    run french_found "creates a devzone in <folder> and starts it"
    [ "$status" -eq 1 ]
}

@test "cli-english: devzone --help of the workstation is in English" {
    run env DEVZONE_NO_GO=1 bash "$RACINE/manage/devzone" --help
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    ! french_found "$output" || false
}

@test "cli-english: devzone workspace help of the workstation is in English" {
    run env DEVZONE_NO_GO=1 bash "$RACINE/manage/devzone" workspace help
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    ! french_found "$output" || false
}

@test "cli-english: devzone --help of the pod is in English" {
    run bash "$RACINE/.devcontainer/devzone" --help
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    ! french_found "$output" || false
}

@test "cli-english: the refusal of an old name is in English" {
    run env DEVZONE_NO_GO=1 bash "$RACINE/manage/devzone" activer
    [ "$status" -eq 1 ]
    [ "$output" = "✖ « activer » was renamed: devzone enable" ]
}
