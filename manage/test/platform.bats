#!/usr/bin/env bats
# GitHub platform (default) or GitLab (#240): devzone platform command,
# glab installed from the official release (checksum verified), login and
# state. Fake glab in ~/.local/bin of the test HOME (outside PATH, like the real
# binary), curl and sha256sum in PATH: no real download.

setup() {
    load commun
    kind_vide
    kube_isole
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin"
    export DEVZONE_ROOT="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_STATE="$BATS_TEST_TMPDIR/modules"
    mkdir -p "$DEVZONE_ROOT/workspace"
    INSTANCE="http://example.gitlab:8443"
    export GLAB_CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
    export GLAB_LOG="$BATS_TEST_TMPDIR/glab.log"
    export GLAB_HOSTS="$BATS_TEST_TMPDIR/glab-hosts"
    # Expected SHA-256 sum: read from the devzone script (pinned versions),
    # based on the pod architecture; a wrong sum makes it fail
    ARM64="$(sed -nE 's/^GLAB_SOMME_ARM64=([0-9a-f]+)$/\1/p' "$DEVZONE")"
    AMD64="$(sed -nE 's/^GLAB_SOMME_AMD64=([0-9a-f]+)$/\1/p' "$DEVZONE")"
    [ "$(wc -c <<<"$ARM64")" -eq 65 ] && [ "$(wc -c <<<"$AMD64")" -eq 65 ] || false
    case "$(uname -m)" in
        arm64 | aarch64) export GLAB_SOMME_LOCALE="$ARM64" ;;
        *) export GLAB_SOMME_LOCALE="$AMD64" ;;
    esac

    # Fake glab: logs its arguments, keeps the hosts connected; the token it
    # received is proven by the journal ($BATS_TEST_TMPDIR, never the screen).
    # Outside PATH (like the real binary in ~/.local/bin): the login
    # doit l'appeler par son chemin
    mkdir -p "$HOME/.local/bin"
    cat >"$HOME/.local/bin/glab" <<'GLAB'
#!/usr/bin/env bash
echo "glab $*" >>"$GLAB_LOG"
prev=""
for a in "$@"; do
    if [ "$prev" = "--hostname" ]; then hote="$a"; fi
    prev="$a"
done
case "$*" in
    *"--version"*) echo "glab 1.126.0" ;;
    *"auth login"*)
        [ -n "${FAUX_GLAB_KO:-}" ] && exit 1
        mkdir -p "$HOME/.config/glab-cli"
        printf 'host: %s\n' "$hote" >"$HOME/.config/glab-cli/config.yml"
        printf '%s\n' "$hote" >>"$GLAB_HOSTS"
        ;;
    *"auth status --hostname"*)
        [ -n "${FAUX_GLAB_KO:-}" ] && exit 1
        [ -f "$GLAB_HOSTS" ] && grep -qxF "$hote" "$GLAB_HOSTS" && exit 0
        exit 1
        ;;
esac
exit 0
GLAB
    cat >"$BATS_TEST_TMPDIR/bin/curl" <<'CURL'
#!/usr/bin/env bash
echo "curl $*" >>"$GLAB_CURL_LOG"
[ -n "${FAUX_CURL_KO:-}" ] && exit 7
prev=""
for a in "$@"; do
    if [ "$prev" = "-o" ] && [ -n "$a" ]; then
        mkdir -p "$BATS_TEST_TMPDIR/archive"
        printf '#!/usr/bin/env bash\necho glab factice\n' \
            >"$BATS_TEST_TMPDIR/archive/bin_glab"
        mkdir -p "$BATS_TEST_TMPDIR/archive/bin"
        cp "$BATS_TEST_TMPDIR/archive/bin_glab" "$BATS_TEST_TMPDIR/archive/bin/glab"
        tar -czf "$a" -C "$BATS_TEST_TMPDIR/archive" bin
    fi
    prev="$a"
done
exit 0
CURL
    # Fake sha256sum: returns the expected sum (a different sum -> failure)
    cat >"$BATS_TEST_TMPDIR/bin/sha256sum" <<'SHA'
#!/usr/bin/env bash
echo "${GLAB_SOMME_FAUX:-$GLAB_SOMME_LOCALE}  $*"
SHA
    # Fake gh: GH_ETAT = absent (default), without (connected without workflow), with
    cat >"$BATS_TEST_TMPDIR/bin/gh" <<'GH'
#!/usr/bin/env bash
case "${GH_ETAT:-absent}" in
    absent) echo "You are not logged into any GitHub hosts." >&2; exit 1 ;;
    without) echo "  - Token scopes: 'gist', 'read:org', 'repo'" ;;
    with) echo "  - Token scopes: 'gist', 'read:org', 'repo', 'workflow'" ;;
esac
GH
    chmod +x "$BATS_TEST_TMPDIR/bin/"*
    chmod +x "$HOME/.local/bin/glab"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# Snapshot of the modules state: the platform/gitlab_url keys exist
# only while the gitlab platform is chosen
empreinte_etat() {
    cat "$DEVZONE_STATE"
}

@test "default: github platform, current gh checks" {
    GH_ETAT=with run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"platform       github"* ]] || false
    [[ "$output" == *"GitHub          connected"* ]] || false
    [[ "$output" != *"gitlab :"* ]] || false
}

@test "platform: shows the platform, github by default" {
    run bash "$DEVZONE" platform
    [ "$status" -eq 0 ]
    [[ "$output" == *"devzone : github platform (default)"* ]] || false
}

@test "platform: shows gitlab and its URL once chosen" {
    run bash "$DEVZONE" platform gitlab --url "$INSTANCE"
    [ "$status" -eq 0 ]
    run bash "$DEVZONE" platform
    [[ "$output" == *"devzone : gitlab platform: $INSTANCE, glab connected"* ]] || false
}

@test "gitlab platform --url: glab installed from the official release, checksum verified" {
    rm -f "$HOME/.local/bin/glab"
    run bash "$DEVZONE" platform gitlab --url "$INSTANCE"
    [ "$status" -eq 0 ]
    grep -q "gitlab.com/gitlab-org/cli/-/releases/v1.126.0/downloads/glab_1.126.0_linux" "$GLAB_CURL_LOG" || false
    [ "$(grep -c "glab_1.126.0_linux_" "$GLAB_CURL_LOG")" -eq 1 ]
    [ -x "$HOME/.local/bin/glab" ]
}

@test "gitlab platform: other instance, interactive (without token), correct state" {
    run bash "$DEVZONE" platform gitlab --url "$INSTANCE"
    [ "$status" -eq 0 ]
    grep -q "auth login --hostname example.gitlab:8443" "$GLAB_LOG" || false
    ! grep -q -- "--token" "$GLAB_LOG" || false
    ! grep -q -- "--git-protocol" "$GLAB_LOG" || false
    GH_ETAT=with run bash "$DEVZONE"
    [[ "$output" == *"platform       gitlab: $INSTANCE, glab connected"* ]] || false
    [[ "$output" == *"GitHub          not needed here"*"gitlab platform chosen"* ]] || false
    [[ "$output" == *"repowarden      stays on GitHub"* ]] || false
    [[ "$output" != *"GitHub          connected"* ]] || false
}

@test "default URL with the gitlab module active, login via the root token (never printed)" {
    printf 'gitlab=on\n' >"$DEVZONE_STATE"
    mkdir -p "$DEVZONE_ROOT/workspace/.gitlab"
    printf 'jeton-root-secret' >"$DEVZONE_ROOT/workspace/.gitlab/root-token"
    run bash "$DEVZONE" platform gitlab
    [ "$status" -eq 0 ]
    [[ "$output" == *"gitlab platform: http://gitlab.localhost:8929, glab connected"* ]] || false
    [[ "$output" != *"jeton-root-secret"* ]] || false
    grep -q "auth login --hostname gitlab.localhost:8929" "$GLAB_LOG" || false
    grep -q -- "--api-protocol http" "$GLAB_LOG" || false
    grep -q -- "--git-protocol http" "$GLAB_LOG" || false
    grep -q -- "--token jeton-root-secret" "$GLAB_LOG" || false
}

@test "without URL and without an active gitlab module -> refusal, nothing installed" {
    rm -f "$HOME/.local/bin/glab"
    run bash "$DEVZONE" platform gitlab
    [ "$status" -eq 1 ]
    [[ "$output" == *"missing URL"* ]] || false
    [ ! -e "$HOME/.local/bin/glab" ]
    ! grep -q '^gitlab_url=' "$DEVZONE_STATE" || false
    ! grep -q '^platform=' "$DEVZONE_STATE" || false
}

@test "--url without a value -> refusal" {
    run bash "$DEVZONE" platform gitlab --url
    [ "$status" -eq 1 ]
    [[ "$output" == *"--url expects a URL"* ]] || false
}

@test "unknown platform -> refusal, state intact" {
    rm -f "$HOME/.local/bin/glab"
    run bash "$DEVZONE" platform machines
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown platform: machines"* ]] || false
    [ ! -e "$HOME/.local/bin/glab" ]
}

@test "plateforme gitlab, module actif, root token absent → invitation, plateforme non retenue" {
    printf 'gitlab=on\n' >"$DEVZONE_STATE"
    run bash "$DEVZONE" platform gitlab
    [ "$status" -ne 0 ]
    [[ "$output" == *"root token"*"devzone enable gitlab"* ]] || false
    [ -x "$HOME/.local/bin/glab" ]
    ! grep -q '^platform=' "$DEVZONE_STATE" || false
    ! grep -q '^gitlab_url=' "$DEVZONE_STATE" || false
}

@test "different SHA-256 sum -> failure, no glab, platform not chosen" {
    bash "$DEVZONE" >/dev/null
    rm -f "$HOME/.local/bin/glab"
    GLAB_SOMME_FAUX=0000000000000000000000000000000000000000000000000000000000000000 \
        run bash "$DEVZONE" platform gitlab --url "$INSTANCE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"SHA-256 sum"* ]] || false
    [ ! -e "$HOME/.local/bin/glab" ]
    ! grep -q '^platform=' "$DEVZONE_STATE" || false
    [ -f "$DEVZONE_STATE" ]
}

@test "failed download -> message, no glab, platform not chosen" {
    rm -f "$HOME/.local/bin/glab"
    FAUX_CURL_KO=1 run bash "$DEVZONE" platform gitlab --url "$INSTANCE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"glab download failed"* ]] || false
    [ ! -e "$HOME/.local/bin/glab" ]
    ! grep -q '^platform=' "$DEVZONE_STATE" || false
}

@test "login refused by glab -> failure, platform not chosen, nothing to fix" {
    FAUX_GLAB_KO=1 run bash "$DEVZONE" platform gitlab --url "$INSTANCE"
    [ "$status" -ne 0 ]
    [[ "$output" != *"glab connected"* ]] || false
    [[ "$output" == *"glab auth login --hostname example.gitlab:8443"* ]] || false
    ! grep -q '^platform=' "$DEVZONE_STATE" || false
    [ -x "$HOME/.local/bin/glab" ]
}

@test "gitlab module: login impossible -> platform kept, state glab not connected" {
    printf 'gitlab=on\nplatform=gitlab\ngitlab_url=http://gitlab.localhost:8929\n' >"$DEVZONE_STATE"
    mkdir -p "$DEVZONE_ROOT/workspace/.gitlab"
    printf 'jeton-root-secret' >"$DEVZONE_ROOT/workspace/.gitlab/root-token"
    FAUX_GLAB_KO=1 run bash "$DEVZONE" platform gitlab
    [ "$status" -ne 0 ]
    [[ "$output" != *"glab connected"* ]] || false
    grep -qx 'platform=gitlab' "$DEVZONE_STATE" || false
    run bash "$DEVZONE" platform
    [ "$status" -eq 0 ]
    [[ "$output" == *"devzone : gitlab platform: http://gitlab.localhost:8929, glab not connected: glab auth login --hostname gitlab.localhost:8929"* ]] || false
}

@test "back to github: glab and its configuration removed, state unchanged" {
    bash "$DEVZONE" >/dev/null
    avant="$(empreinte_etat)"
    run bash "$DEVZONE" platform gitlab --url "$INSTANCE"
    [ "$status" -eq 0 ]
    [ -x "$HOME/.local/bin/glab" ]
    [ -d "$HOME/.config/glab-cli" ]
    run bash "$DEVZONE" platform github
    [ "$status" -eq 0 ]
    [ ! -e "$HOME/.local/bin/glab" ]
    [ ! -e "$HOME/.config/glab-cli" ]
    [ "$(empreinte_etat)" = "$avant" ]
    GH_ETAT=with run bash "$DEVZONE"
    [[ "$output" == *"platform       github"*"GitHub          connected"* ]] || false
    [[ "$output" != *"inutile ici"* ]] || false
}

@test "gitlab chosen again: glab not downloaded again, nothing changes" {
    rm -f "$HOME/.local/bin/glab"
    run bash "$DEVZONE" platform gitlab --url "$INSTANCE"
    [ "$status" -eq 0 ]
    [ "$(grep -c "curl " "$GLAB_CURL_LOG")" -eq 1 ]
    run bash "$DEVZONE" platform gitlab --url "$INSTANCE"
    [ "$status" -eq 0 ]
    [ "$(grep -c "curl " "$GLAB_CURL_LOG")" -eq 1 ]
}

@test "devzone --help cite la commande plateforme" {
    run bash "$DEVZONE" --help
    [[ "$output" == *"devzone platform github"* ]] || false
    [[ "$output" == *"devzone platform gitlab"* ]] || false
    [[ "$output" == *"[--url URL]"* ]] || false
}
