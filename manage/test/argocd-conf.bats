#!/usr/bin/env bats
# .argocd.conf (#516): the reader and writer of conf.sh, on a file under
# $BATS_TEST_TMPDIR.

setup() {
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export ARGOCD_CONF="$BATS_TEST_TMPDIR/.argocd.conf"
    # shellcheck disable=SC1091
    . "$RACINE/.devcontainer/argocd/conf.sh"
    cat >"$ARGOCD_CONF" <<'CONF'
# header comment
[argocd]
    repo = https://github.com/me/devzone-argocd.git   # inline comment

[app demo]
    repo = https://github.com/argoproj/argocd-example-apps
    path = guestbook
    revision=main

[ app spaced ]
    repo = https://x/y.git
CONF
}

@test "conf_get: trimmed values, inline comments dropped, absent keys empty" {
    [ "$(conf_get argocd repo)" = "https://github.com/me/devzone-argocd.git" ]
    [ "$(conf_get "app demo" path)" = "guestbook" ]
    [ "$(conf_get "app demo" revision)" = "main" ]
    [ "$(conf_get "app spaced" repo)" = "https://x/y.git" ]
    [ -z "$(conf_get "app demo" namespace)" ]
    [ -z "$(conf_get missing repo)" ]
    rm -f "$ARGOCD_CONF"
    [ -z "$(conf_get argocd repo)" ]
}

@test "conf_sections: the names of the [app …] sections, in order" {
    [ "$(conf_sections app | tr '\n' ' ')" = "demo spaced " ]
    [ -z "$(conf_sections other)" ]
}

@test "conf_set: a section replaced in place of its keys, or added at the end; conf_remove drops it" {
    conf_set "app demo" repo=https://new/demo.git path=.
    [ "$(conf_get "app demo" repo)" = "https://new/demo.git" ]
    [ -z "$(conf_get "app demo" revision)" ]
    [ "$(grep -c '^\[app demo\]$' "$ARGOCD_CONF")" -eq 1 ]
    grep -q '^# header comment$' "$ARGOCD_CONF"
    [ "$(conf_get argocd repo)" = "https://github.com/me/devzone-argocd.git" ]
    conf_set "app third" repo=https://x/third.git
    [ "$(conf_sections app | tr '\n' ' ')" = "spaced demo third " ]
    conf_remove "app spaced"
    [ -z "$(conf_get "app spaced" repo)" ]
    [ "$(conf_sections app | tr '\n' ' ')" = "demo third " ]
    ! grep -q 'https://x/y.git' "$ARGOCD_CONF" || false
    # Never two blank lines in a row
    ! grep -Pzo '\n\n\n' "$ARGOCD_CONF" >/dev/null 2>&1 || false
}

@test "conf_set: creates the file with its header when absent" {
    rm -f "$ARGOCD_CONF"
    conf_set argocd repo=none
    grep -q '^# Argo CD of devzone' "$ARGOCD_CONF"
    [ "$(conf_get argocd repo)" = none ]
}
