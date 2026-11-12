#!/usr/bin/env bats
# mode du poste pour make up|shell|stop|rebuild (#472) : faux npx, faux docker
# et faux manage/workspace.sh qui journalisent leurs arguments. Aucun cluster,
# aucun Docker et aucun npx reel.

setup() {
    load commun
    T="$BATS_TEST_TMPDIR"
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    POSTE="$RACINE/manage/scripts/poste.sh"
    FAKE_LOG="$T/outils.log"
    export FAKE_LOG
    mkdir -p "$T/bin" "$T/dossier"
    cat >"$T/bin/npx" <<'NPX'
#!/usr/bin/env bash
echo "npx $*" >>"$FAKE_LOG"
NPX
    cat >"$T/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
echo "docker $*" >>"$FAKE_LOG"
DOCKER
    chmod +x "$T/bin/npx" "$T/bin/docker"
    export PATH="$T/bin:$PATH"
    : >"$FAKE_LOG"
}

# Faux manage/workspace.sh du dossier : journalise ses arguments.
faux_workspace() {
    mkdir -p "$T/dossier/manage"
    cat >"$T/dossier/manage/workspace.sh" <<'WS'
#!/usr/bin/env bash
echo "workspace $*" >>"$FAKE_LOG"
WS
}

@test "docker (ligne absente, workspace=docker, valeur inconnue) : code 3, rien affiche ni journalise" {
    for contenu in "" "workspace=docker" "workspace=minikube"; do
        if [ -n "$contenu" ]; then
            printf '%s\n' "$contenu" >"$T/dossier/.devzone.modules"
        else
            rm -f "$T/dossier/.devzone.modules"
        fi
        for cible in up shell stop rebuild; do
            : >"$FAKE_LOG"
            run bash "$POSTE" "$cible" "$T/dossier"
            [ "$status" -eq 3 ]
            [ -z "$output" ]
            [ ! -s "$FAKE_LOG" ]
        done
    done
}

@test "workspace Kubernetes avec manage/workspace.sh : up, shell et stop pilotent le script" {
    printf 'workspace=kubernetes\n' >"$T/dossier/.devzone.modules"
    faux_workspace

    : >"$FAKE_LOG"
    run bash "$POSTE" up "$T/dossier"
    [ "$status" -eq 0 ]
    [ "$(cat "$FAKE_LOG")" = "workspace demarrer" ]

    : >"$FAKE_LOG"
    run bash "$POSTE" shell "$T/dossier"
    [ "$status" -eq 0 ]
    [ "$(sed -n '1p' "$FAKE_LOG")" = "workspace demarrer" ]
    [ "$(sed -n '2p' "$FAKE_LOG")" = "workspace shell" ]
    [ "$(wc -l <"$FAKE_LOG" | tr -d ' ')" = 2 ]

    : >"$FAKE_LOG"
    run bash "$POSTE" stop "$T/dossier"
    [ "$status" -eq 0 ]
    [ "$(cat "$FAKE_LOG")" = "workspace arreter" ]
}

@test "workspace Kubernetes : rebuild refuse et renvoie vers devzone workspace revenir" {
    printf 'workspace=kubernetes\n' >"$T/dossier/.devzone.modules"
    run bash "$POSTE" rebuild "$T/dossier"
    [ "$status" -eq 1 ]
    [[ "$output" == *"devzone workspace revenir"* ]] || false
    [ ! -s "$FAKE_LOG" ]
}

@test "workspace Kubernetes sans manage/workspace.sh : npx devzone@version du dossier" {
    printf 'workspace=kubernetes\n' >"$T/dossier/.devzone.modules"
    printf 'version 0.34.4\nabc  Makefile\n' >"$T/dossier/.devzone.version"

    : >"$FAKE_LOG"
    run bash "$POSTE" up "$T/dossier"
    [ "$status" -eq 0 ]
    [ "$(cat "$FAKE_LOG")" = "npx -y devzone@0.34.4 workspace demarrer" ]

    rm -f "$T/dossier/.devzone.version"
    : >"$FAKE_LOG"
    run bash "$POSTE" up "$T/dossier"
    [ "$status" -eq 0 ]
    [ "$(cat "$FAKE_LOG")" = "npx -y devzone@latest workspace demarrer" ]
}

@test "make -n up et make -n shell : la recette appelle poste.sh" {
    run make -n -C "$RACINE" up
    [ "$status" -eq 0 ]
    [[ "$output" == *"poste.sh up"* ]] || false
    run make -n -C "$RACINE" shell
    [ "$status" -eq 0 ]
    [[ "$output" == *"poste.sh shell"* ]] || false
}

@test "poste.sh : lance sous bash 3.2 si disponible" {
    bash32=""
    if command -v test-bash32 >/dev/null 2>&1; then
        bash32="test-bash32"
    elif [ -x /bin/bash ] && /bin/bash --version 2>/dev/null | grep -q 'version 3\.2\.'; then
        bash32="/bin/bash"
    fi
    [ -n "$bash32" ] || skip "bash 3.2 absent"

    printf 'workspace=kubernetes\n' >"$T/dossier/.devzone.modules"
    faux_workspace
    : >"$FAKE_LOG"
    run "$bash32" "$POSTE" up "$T/dossier"
    [ "$status" -eq 0 ]
    [ "$(cat "$FAKE_LOG")" = "workspace demarrer" ]
}
