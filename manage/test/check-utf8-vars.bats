#!/usr/bin/env bats
# CI check of $NAME followed by a non-ASCII byte (#591):
# manage/scripts/check-utf8-vars.sh on a temporary git repository under
# BATS_TEST_TMPDIR, never on the real tree (that is the CI's job).

setup() {
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$RACINE/manage/scripts/check-utf8-vars.sh"
    T="$BATS_TEST_TMPDIR"
    mkdir -p "$T/manage/scripts"
    cp "$SCRIPT" "$T/manage/scripts/check-utf8-vars.sh"
    git -C "$T" init -q
    cd "$T" || return 1
}

# Writes file $1 (printf format $2) and tracks it in the temporary repository
suivi() {
    mkdir -p "$(dirname "$T/$1")"
    printf "$2" >"$T/$1"
    git -C "$T" add -- "$1"
}

@test "clean script: ok, braced name before an ellipsis and bare name before ASCII admitted" {
    suivi clean.sh 'echo "$NOM" ${NOM}\xe2\x80\xa6 $NOM:x $NOM\tx\n'
    run bash "$T/manage/scripts/check-utf8-vars.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "utf8 vars check: 1 files ok" ]
}

@test "\$NAME before an accented letter: fails with path:line" {
    suivi bad.sh 'echo ok\necho "$NOM\xc3\xa9"\n'
    run bash "$T/manage/scripts/check-utf8-vars.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *'bad.sh:2: '* ]] || false
}

@test "\$NAME before an ellipsis in a .bash file: fails" {
    suivi lib/tool.bash 'echo "fin de $CTX\xe2\x80\xa6"\n'
    run bash "$T/manage/scripts/check-utf8-vars.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *'lib/tool.bash:1: '* ]] || false
}

@test "bash shebang without extension: checked" {
    suivi bin/outil '#!/usr/bin/env bash\necho "$POD\xe2\x80\xa6"\n'
    run bash "$T/manage/scripts/check-utf8-vars.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *'bin/outil:2: '* ]] || false
}

@test "devzone entry point: checked" {
    suivi .devcontainer/devzone 'echo "$figee\xe2\x80\xa6"\n'
    run bash "$T/manage/scripts/check-utf8-vars.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *'.devcontainer/devzone:1: '* ]] || false
}

@test "not a bash script, or not tracked: ignored" {
    suivi clean.sh 'echo "$NOM"\n'
    suivi notes.md 'Use $NOM\xe2\x80\xa6 here\n'
    suivi plain 'echo "$NOM\xe2\x80\xa6"\n'
    printf 'echo "$NOM\xe2\x80\xa6"\n' >"$T/untracked.sh"
    run bash "$T/manage/scripts/check-utf8-vars.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "utf8 vars check: 1 files ok" ]
}
