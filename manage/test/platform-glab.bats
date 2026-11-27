#!/usr/bin/env bats
# glab git helper (#278): devzone platform gitlab sets, for the instance host
# only, credential.<URL>.helper = !glab auth git-credential;
# devzone platform github removes it; the summary says "✔ git via glab".
# Fake glab (auth status, auth git-credential ok) and fake kind; HOME and
# GIT_CONFIG_GLOBAL under $BATS_TEST_TMPDIR: git config --global never writes
# to the real ~/.gitconfig.

setup() {
    load commun
    devzone_pod_pret
    kube_isole
    kind_vide
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    export HOME="$BATS_TEST_TMPDIR/home"
    export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
    export GIT_CONFIG_NOSYSTEM=1
    mkdir -p "$HOME" "$HOME/.local/bin"
    # garde-fou : jamais le vrai HOME
    [[ "$HOME" == "$BATS_TEST_TMPDIR"/* ]] || false
    export DEVZONE_ROOT="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_STATE="$BATS_TEST_TMPDIR/modules"
    mkdir -p "$DEVZONE_ROOT/workspace"
    export GLAB_LOG="$BATS_TEST_TMPDIR/glab.log"
    INSTANCE="http://example.gitlab:8443"
    AUTRE="https://git.autre.exemple"

    # Fake glab in ~/.local/bin (absolute path, like the real binary):
    # version, login and auth check succeed, fake git-credential
    cat >"$HOME/.local/bin/glab" <<'GLAB'
#!/usr/bin/env bash
echo "glab $*" >>"$GLAB_LOG"
case "$*" in
    *"--version"*) echo "glab 1.126.0" ;;
esac
exit 0
GLAB
    chmod +x "$HOME/.local/bin/glab"
}

# Value of the credential setting of the given host, empty if absent
reglage() {
    git config --global --get "credential.$1.helper" 2>/dev/null || true
}

# Number of credential.* settings present in the test HOME
nombre_reglages_credential() {
    git config --global --get-regexp '^credential\.' 2>/dev/null | wc -l
}

@test "gitlab platform sets the credential setting for the instance host only" {
    run bash "$DEVZONE" platform gitlab --url "$INSTANCE"
    [ "$status" -eq 0 ]
    [ "$(reglage "$INSTANCE")" = "!$HOME/.local/bin/glab auth git-credential" ]
    [ "$(nombre_reglages_credential)" -eq 1 ]
    [ -f "$GIT_CONFIG_GLOBAL" ]
}

@test "gitlab platform: another credential setting (other host) stays intact" {
    git config --global "credential.$AUTRE.helper" store
    git config --global "credential.$AUTRE.username" bob
    avant="$(git config --global --get-regexp '^credential\.' | sort)"
    run bash "$DEVZONE" platform gitlab --url "$INSTANCE"
    [ "$status" -eq 0 ]
    [ "$(reglage "$AUTRE")" = "store" ]
    [ "$(git config --global "credential.$AUTRE.username")" = "bob" ]
    [ "$(reglage "$INSTANCE")" = "!$HOME/.local/bin/glab auth git-credential" ]
    # the earlier settings are all still there, unchanged
    apres="$(git config --global --get-regexp '^credential\.' | sort)"
    [[ "$apres" == *"$avant"* ]] || false
    [ "$(nombre_reglages_credential)" -eq 3 ]
}

@test "gitlab platform repeated: a single setting, no duplicate" {
    run bash "$DEVZONE" platform gitlab --url "$INSTANCE"
    [ "$status" -eq 0 ]
    run bash "$DEVZONE" platform gitlab --url "$INSTANCE"
    [ "$status" -eq 0 ]
    [ "$(git config --global --get-all "credential.$INSTANCE.helper" | wc -l)" -eq 1 ]
}

@test "back to github: no setting left for the instance, the others intact" {
    git config --global "credential.$AUTRE.helper" store
    run bash "$DEVZONE" platform gitlab --url "$INSTANCE"
    [ "$status" -eq 0 ]
    [ "$(reglage "$INSTANCE")" != "" ]
    run bash "$DEVZONE" platform github
    [ "$status" -eq 0 ]
    [ -z "$(reglage "$INSTANCE")" ]
    [ "$(reglage "$AUTRE")" = "store" ]
    [ "$(nombre_reglages_credential)" -eq 1 ]
    [ ! -e "$HOME/.local/bin/glab" ]
}

@test "back to github without a setting: no error, nothing added" {
    run bash "$DEVZONE" platform gitlab --url "$INSTANCE"
    [ "$status" -eq 0 ]
    git config --global --unset-all "credential.$INSTANCE.helper"
    run bash "$DEVZONE" platform github
    [ "$status" -eq 0 ]
    [ "$(nombre_reglages_credential)" -eq 0 ]
}

@test "summary: \"✔ git via glab\" once the setting is in place" {
    run bash "$DEVZONE" platform gitlab --url "$INSTANCE"
    [ "$status" -eq 0 ]
    run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"✔ git via glab"* ]] || false
    [[ "$output" != *"to set: devzone platform gitlab"* ]] || false
}

@test "summary: \"to set\" if the setting disappeared, gitlab platform kept" {
    run bash "$DEVZONE" platform gitlab --url "$INSTANCE"
    [ "$status" -eq 0 ]
    git config --global --unset-all "credential.$INSTANCE.helper"
    run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"⚠ git via glab"*"to set: devzone platform gitlab"* ]] || false
    [[ "$output" != *"✔ git via glab"* ]] || false
}

@test "summary: no \"git via glab\" line on github" {
    run bash "$DEVZONE" platform gitlab --url "$INSTANCE"
    [ "$status" -eq 0 ]
    run bash "$DEVZONE" platform github
    [ "$status" -eq 0 ]
    run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    [[ "$output" != *"git via glab"* ]] || false
}

@test "credential setting impossible (global config not writable) -> failure, platform not chosen" {
    # git config fails if the global config file is not writable
    mkdir -p "$GIT_CONFIG_GLOBAL"
    run bash "$DEVZONE" platform gitlab --url "$INSTANCE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot set the git credential"* ]] || false
    ! grep -q '^platform=' "$DEVZONE_STATE" 2>/dev/null || false
}
