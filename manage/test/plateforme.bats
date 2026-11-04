#!/usr/bin/env bats
# Plateforme GitHub (défaut) ou GitLab (#240) : commande devzone plateforme,
# glab installé depuis la release officielle (somme vérifiée), connexion et
# état. Faux glab dans ~/.local/bin du HOME de test (hors PATH, comme le vrai
# binaire), curl et sha256sum dans le PATH : aucun téléchargement réel.

setup() {
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin"
    export DEVZONE_RACINE="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_ETAT="$BATS_TEST_TMPDIR/modules"
    mkdir -p "$DEVZONE_RACINE/workspace"
    INSTANCE="http://example.gitlab:8443"
    export GLAB_CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
    export GLAB_LOG="$BATS_TEST_TMPDIR/glab.log"
    export GLAB_HOSTS="$BATS_TEST_TMPDIR/glab-hosts"
    # Somme SHA-256 attendue : lue dans le script devzone (versions figées),
    # selon l'architecture du conteneur ; une somme fausse la fait échouer
    ARM64="$(sed -nE 's/^GLAB_SOMME_ARM64=([0-9a-f]+)$/\1/p' "$DEVZONE")"
    AMD64="$(sed -nE 's/^GLAB_SOMME_AMD64=([0-9a-f]+)$/\1/p' "$DEVZONE")"
    [ "$(wc -c <<<"$ARM64")" -eq 65 ] && [ "$(wc -c <<<"$AMD64")" -eq 65 ] || false
    case "$(uname -m)" in
        arm64 | aarch64) export GLAB_SOMME_LOCALE="$ARM64" ;;
        *) export GLAB_SOMME_LOCALE="$AMD64" ;;
    esac

    # glab simulé : journalise ses arguments, garde les hôtes connectés ; le
    # jeton reçu est prouvé par le journal ($BATS_TEST_TMPDIR, jamais l'écran).
    # Hors du PATH (comme le vrai binaire dans ~/.local/bin) : la connexion
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
    # sha256sum simulé : renvoie la somme attendue (somme différente → échec)
    cat >"$BATS_TEST_TMPDIR/bin/sha256sum" <<'SHA'
#!/usr/bin/env bash
echo "${GLAB_SOMME_FAUX:-$GLAB_SOMME_LOCALE}  $*"
SHA
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
    chmod +x "$HOME/.local/bin/glab"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# Empreinte de l'état modules : les clés plateforme/gitlab_url n'existent
# que pendant que la plateforme gitlab est choisie
empreinte_etat() {
    cat "$DEVZONE_ETAT"
}

@test "défaut : plateforme github, contrôles gh actuels" {
    GH_ETAT=avec run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"plateforme     github"* ]] || false
    [[ "$output" == *"GitHub          connecté"* ]] || false
    [[ "$output" != *"gitlab :"* ]] || false
}

@test "plateforme : affiche la plateforme, github par défaut" {
    run bash "$DEVZONE" plateforme
    [ "$status" -eq 0 ]
    [[ "$output" == *"devzone : plateforme github (défaut)"* ]] || false
}

@test "plateforme : affiche gitlab et son URL une fois choisi" {
    run bash "$DEVZONE" plateforme gitlab --url "$INSTANCE"
    [ "$status" -eq 0 ]
    run bash "$DEVZONE" plateforme
    [[ "$output" == *"devzone : plateforme gitlab : $INSTANCE, glab connecté"* ]] || false
}

@test "plateforme gitlab --url : glab installé de la release officielle, somme vérifiée" {
    rm -f "$HOME/.local/bin/glab"
    run bash "$DEVZONE" plateforme gitlab --url "$INSTANCE"
    [ "$status" -eq 0 ]
    grep -q "gitlab.com/gitlab-org/cli/-/releases/v1.126.0/downloads/glab_1.126.0_linux" "$GLAB_CURL_LOG" || false
    [ "$(grep -c "glab_1.126.0_linux_" "$GLAB_CURL_LOG")" -eq 1 ]
    [ -x "$HOME/.local/bin/glab" ]
}

@test "plateforme gitlab : autre instance, interactive (sans jeton), état correct" {
    run bash "$DEVZONE" plateforme gitlab --url "$INSTANCE"
    [ "$status" -eq 0 ]
    grep -q "auth login --hostname example.gitlab:8443" "$GLAB_LOG" || false
    ! grep -q -- "--token" "$GLAB_LOG" || false
    ! grep -q -- "--git-protocol" "$GLAB_LOG" || false
    GH_ETAT=avec run bash "$DEVZONE"
    [[ "$output" == *"plateforme     gitlab : $INSTANCE, glab connecté"* ]] || false
    [[ "$output" == *"GitHub          inutile ici"*"plateforme gitlab choisie"* ]] || false
    [[ "$output" == *"repowarden      reste sur GitHub"* ]] || false
    [[ "$output" != *"GitHub          connecté"* ]] || false
}

@test "URL par défaut avec le module gitlab actif, connexion par le jeton root (jamais affiché)" {
    printf 'gitlab=on\n' >"$DEVZONE_ETAT"
    mkdir -p "$DEVZONE_RACINE/workspace/.gitlab"
    printf 'jeton-root-secret' >"$DEVZONE_RACINE/workspace/.gitlab/root-token"
    run bash "$DEVZONE" plateforme gitlab
    [ "$status" -eq 0 ]
    [[ "$output" == *"plateforme gitlab : http://gitlab.localhost:8929, glab connecté"* ]] || false
    [[ "$output" != *"jeton-root-secret"* ]] || false
    grep -q "auth login --hostname gitlab.localhost:8929" "$GLAB_LOG" || false
    grep -q -- "--api-protocol http" "$GLAB_LOG" || false
    grep -q -- "--git-protocol http" "$GLAB_LOG" || false
    grep -q -- "--token jeton-root-secret" "$GLAB_LOG" || false
}

@test "sans URL et sans module gitlab actif → refus, rien installé" {
    rm -f "$HOME/.local/bin/glab"
    run bash "$DEVZONE" plateforme gitlab
    [ "$status" -eq 1 ]
    [[ "$output" == *"URL manquante"* ]] || false
    [ ! -e "$HOME/.local/bin/glab" ]
    ! grep -q '^gitlab_url=' "$DEVZONE_ETAT" || false
    ! grep -q '^plateforme=' "$DEVZONE_ETAT" || false
}

@test "--url sans valeur → refus" {
    run bash "$DEVZONE" plateforme gitlab --url
    [ "$status" -eq 1 ]
    [[ "$output" == *"--url attend une URL"* ]] || false
}

@test "plateforme inconnue → refus, état intact" {
    rm -f "$HOME/.local/bin/glab"
    run bash "$DEVZONE" plateforme machines
    [ "$status" -eq 1 ]
    [[ "$output" == *"plateforme inconnue : machines"* ]] || false
    [ ! -e "$HOME/.local/bin/glab" ]
}

@test "plateforme gitlab, module actif, jeton root absent → invitation, plateforme non retenue" {
    printf 'gitlab=on\n' >"$DEVZONE_ETAT"
    run bash "$DEVZONE" plateforme gitlab
    [ "$status" -ne 0 ]
    [[ "$output" == *"jeton root"*"devzone activer gitlab"* ]] || false
    [ -x "$HOME/.local/bin/glab" ]
    ! grep -q '^plateforme=' "$DEVZONE_ETAT" || false
    ! grep -q '^gitlab_url=' "$DEVZONE_ETAT" || false
}

@test "somme SHA-256 différente → échec, glab absent, plateforme non retenue" {
    bash "$DEVZONE" >/dev/null
    rm -f "$HOME/.local/bin/glab"
    GLAB_SOMME_FAUX=0000000000000000000000000000000000000000000000000000000000000000 \
        run bash "$DEVZONE" plateforme gitlab --url "$INSTANCE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"somme SHA-256"* ]] || false
    [ ! -e "$HOME/.local/bin/glab" ]
    ! grep -q '^plateforme=' "$DEVZONE_ETAT" || false
    [ -f "$DEVZONE_ETAT" ]
}

@test "téléchargement en échec → message, glab absent, plateforme non retenue" {
    rm -f "$HOME/.local/bin/glab"
    FAUX_CURL_KO=1 run bash "$DEVZONE" plateforme gitlab --url "$INSTANCE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"téléchargement de glab impossible"* ]] || false
    [ ! -e "$HOME/.local/bin/glab" ]
    ! grep -q '^plateforme=' "$DEVZONE_ETAT" || false
}

@test "connexion refusée par glab → échec, plateforme non retenue, rien à corriger" {
    FAUX_GLAB_KO=1 run bash "$DEVZONE" plateforme gitlab --url "$INSTANCE"
    [ "$status" -ne 0 ]
    [[ "$output" != *"glab connecté"* ]] || false
    [[ "$output" == *"glab auth login --hostname example.gitlab:8443"* ]] || false
    ! grep -q '^plateforme=' "$DEVZONE_ETAT" || false
    [ -x "$HOME/.local/bin/glab" ]
}

@test "module gitlab : connexion impossible → plateforme gardée, état glab non connecté" {
    printf 'gitlab=on\nplateforme=gitlab\ngitlab_url=http://gitlab.localhost:8929\n' >"$DEVZONE_ETAT"
    mkdir -p "$DEVZONE_RACINE/workspace/.gitlab"
    printf 'jeton-root-secret' >"$DEVZONE_RACINE/workspace/.gitlab/root-token"
    FAUX_GLAB_KO=1 run bash "$DEVZONE" plateforme gitlab
    [ "$status" -ne 0 ]
    [[ "$output" != *"glab connecté"* ]] || false
    grep -qx 'plateforme=gitlab' "$DEVZONE_ETAT" || false
    run bash "$DEVZONE" plateforme
    [ "$status" -eq 0 ]
    [[ "$output" == *"devzone : plateforme gitlab : http://gitlab.localhost:8929, glab non connecté : glab auth login --hostname gitlab.localhost:8929"* ]] || false
}

@test "retour github : glab et sa configuration retirés, état identique à avant" {
    bash "$DEVZONE" >/dev/null
    avant="$(empreinte_etat)"
    run bash "$DEVZONE" plateforme gitlab --url "$INSTANCE"
    [ "$status" -eq 0 ]
    [ -x "$HOME/.local/bin/glab" ]
    [ -d "$HOME/.config/glab-cli" ]
    run bash "$DEVZONE" plateforme github
    [ "$status" -eq 0 ]
    [ ! -e "$HOME/.local/bin/glab" ]
    [ ! -e "$HOME/.config/glab-cli" ]
    [ "$(empreinte_etat)" = "$avant" ]
    GH_ETAT=avec run bash "$DEVZONE"
    [[ "$output" == *"plateforme     github"*"GitHub          connecté"* ]] || false
    [[ "$output" != *"inutile ici"* ]] || false
}

@test "choix gitlab répété : glab pas re-téléchargé, rien ne change" {
    rm -f "$HOME/.local/bin/glab"
    run bash "$DEVZONE" plateforme gitlab --url "$INSTANCE"
    [ "$status" -eq 0 ]
    [ "$(grep -c "curl " "$GLAB_CURL_LOG")" -eq 1 ]
    run bash "$DEVZONE" plateforme gitlab --url "$INSTANCE"
    [ "$status" -eq 0 ]
    [ "$(grep -c "curl " "$GLAB_CURL_LOG")" -eq 1 ]
}

@test "devzone --help cite la commande plateforme" {
    run bash "$DEVZONE" --help
    [[ "$output" == *"devzone plateforme github"* ]] || false
    [[ "$output" == *"devzone plateforme gitlab"* ]] || false
    [[ "$output" == *"[--url URL]"* ]] || false
}
