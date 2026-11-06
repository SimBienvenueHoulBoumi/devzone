#!/usr/bin/env bats
# Identifiants regroupés (#332) : sources factices sous $BATS_TEST_TMPDIR,
# régénération, format, droits, disparition des comptes et commande devzone.
# Aucun vrai fichier de secret n'est lu.

setup() {
    load commun
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    PASSWORD="$BATS_TEST_DIRNAME/../../.devcontainer/password.sh"
    relais_docker_isole
    kube_isole
    export HOME="$BATS_TEST_TMPDIR/home"
    export DEVZONE_RACINE="$BATS_TEST_TMPDIR/racine"
    # demarrage.sh lance le veilleur de ports auto : son dossier reste sous le test (#394)
    export DEVZONE_PORTS_AUTO_DIR="$BATS_TEST_TMPDIR/ports-auto"
    RACINE="$DEVZONE_RACINE"
    GL="$RACINE/workspace/.gitlab"
    PG="$RACINE/workspace/.postgres"
    mkdir -p "$HOME" "$GL" "$PG"
    printf '%s' 'mdp-test-root' >"$GL/root-password"
    printf '%s' 'mdp-test-dev' >"$GL/dev-password"
    printf '%s' 'mdp-test-admin' >"$PG/admin-password"
    printf 'DB_NAME=alpha\nDB_USER=alpha_user\nDB_PASSWORD=mdp-test-alpha\n' >"$PG/alpha.env"
    printf 'DB_NAME=zeta\nDB_USER=zeta_user\nDB_PASSWORD=mdp-test-zeta\n' >"$PG/zeta.env"
}

@test "password : contenu, en-tête, tabulations et tri par service puis utilisateur" {
    run bash "$PASSWORD" regenerer
    [ "$status" -eq 0 ]
    [ "$output" = "" ]

    attendu="$BATS_TEST_TMPDIR/attendu"
    {
        printf '%s\n' \
            '# devzone : identifiants des comptes créés par devzone. Secrets en clair :' \
            '# ne jamais commiter, copier ni coller dans un ticket. Régénéré par devzone.' \
            $'# service\tadresse\tutilisateur\tmot de passe' \
            $'gitlab\thttp://gitlab.localhost:8929\tdev\tmdp-test-dev' \
            $'gitlab\thttp://gitlab.localhost:8929\troot\tmdp-test-root' \
            $'postgres\t127.0.0.1:5432\tpostgres\tmdp-test-admin' \
            $'postgres:alpha\t127.0.0.1:5432/alpha\talpha_user\tmdp-test-alpha' \
            $'postgres:zeta\t127.0.0.1:5432/zeta\tzeta_user\tmdp-test-zeta'
    } >"$attendu"
    diff -u "$attendu" "$RACINE/.password"
    [ "$(awk -F'\t' '!/^#/ && NF != 4 { n++ } END { print n + 0 }' "$RACINE/.password")" -eq 0 ]
}

@test "password : droits 600" {
    bash "$PASSWORD" regenerer
    [ "$(stat -c %a "$RACINE/.password" 2>/dev/null || stat -f %Lp "$RACINE/.password")" = 600 ]
}

@test "password : ligne retirée quand un compte disparaît" {
    bash "$PASSWORD" regenerer
    rm -f "$GL/dev-password"
    run bash "$PASSWORD" regenerer
    [ "$status" -eq 0 ]
    ! grep -q $'^gitlab\t.*\tdev\t' "$RACINE/.password" || false
    grep -q $'^gitlab\thttp://gitlab.localhost:8929\troot\tmdp-test-root$' "$RACINE/.password"
}

@test "password : fichier supprimé quand il n'y a plus aucun compte" {
    bash "$PASSWORD" regenerer
    [ -f "$RACINE/.password" ]
    rm -rf "$GL" "$PG"
    run bash "$PASSWORD" regenerer
    [ "$status" -eq 0 ]
    [ ! -e "$RACINE/.password" ]
}

@test "password chemin : affiche le chemin, même sans fichier" {
    run bash "$PASSWORD" chemin
    [ "$status" -eq 0 ]
    [ "$output" = "$RACINE/.password" ]
    [ ! -e "$RACINE/.password" ]
}

@test "devzone mots-de-passe : régénère et n'affiche que le chemin" {
    run bash "$DEVZONE" mots-de-passe
    [ "$status" -eq 0 ]
    [ "$output" = "$RACINE/.password" ]
    [[ "$output" != *mdp-test-* ]] || false
    [ -f "$RACINE/.password" ]
}

@test ".gitignore : .password ignoré par git" {
    run git -C "$BATS_TEST_DIRNAME/../.." check-ignore --no-index .password
    [ "$status" -eq 0 ]
    [ "$output" = ".password" ]
}

@test "demarrage : appelle password.sh regenerer avant le récapitulatif" {
    local demarrage="$BATS_TEST_DIRNAME/../../.devcontainer/demarrage.sh"
    local ligne_password ligne_recapitulatif
    ligne_password="$(grep -n 'bash "$ICI/password.sh" regenerer' "$demarrage" | cut -d: -f1)"
    ligne_recapitulatif="$(grep -n '^bash "$ICI/devzone"$' "$demarrage" | cut -d: -f1)"
    [ -n "$ligne_password" ]
    [ -n "$ligne_recapitulatif" ]
    [ "$ligne_password" -lt "$ligne_recapitulatif" ]
}
