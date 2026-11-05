#!/usr/bin/env bats
# Relais du socket Docker (#293) : le socat de la feature sans -t est remplacé
# par le même avec -t 86400, puis un docker exec long est contrôlé. Faux ps,
# kill, rm, setsid et docker dans le PATH, chemins sous $BATS_TEST_TMPDIR :
# aucun vrai socat, sudo ni kill.

setup() {
    load commun
    RELAIS="$BATS_TEST_DIRNAME/../../.devcontainer/docker-relais.sh"
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    T="$BATS_TEST_TMPDIR"
    relais_docker_isole
    export DEVZONE_RELAIS_ATTENTE=2
    unset DEVZONE_RELAIS_REAL DEVZONE_RELAIS_DOCKER DEVZONE_RELAIS_UTILISATEUR
    mkdir -p "$T/bin"
    : >"$T/ps.txt"
    : >"$T/outils.log"
    : >"$DEVZONE_RELAIS_SOCKET"

    # ps -eo pid=,args= : la liste du test
    cat >"$T/bin/ps" <<'OUTIL'
#!/usr/bin/env bash
cat "$BATS_TEST_TMPDIR/ps.txt"
OUTIL
    # kill : journalisé ; kill -0 → processus déjà terminé
    cat >"$T/bin/kill" <<'OUTIL'
#!/usr/bin/env bash
echo "kill $*" >>"$BATS_TEST_TMPDIR/outils.log"
[ "${1:-}" = -0 ] && exit 1
exit 0
OUTIL

    # rm : journalisé, puis exécuté
    cat >"$T/bin/rm" <<'OUTIL'
#!/usr/bin/env bash
echo "rm $*" >>"$BATS_TEST_TMPDIR/outils.log"
[ "${1:-}" = "-f" ] && shift
/usr/bin/rm -f "$@"
OUTIL

    # setsid -f socat … : journalisé ; le nouveau socat apparaît dans ps
    cat >"$T/bin/setsid" <<'OUTIL'
#!/usr/bin/env bash
echo "setsid $*" >>"$BATS_TEST_TMPDIR/outils.log"
[ "${1:-}" = -f ] && shift
echo "4242 $*" >"$BATS_TEST_TMPDIR/ps.txt"
OUTIL
    # docker : version selon FAUX_VERSION, exec affiche FAUX_EXEC
    cat >"$T/bin/docker" <<'OUTIL'
#!/usr/bin/env bash
echo "docker $*" >>"$BATS_TEST_TMPDIR/outils.log"
case "${1:-}" in
    version) exit "${FAUX_VERSION:-0}" ;;
    exec) printf '%s\n' "${FAUX_EXEC-ok}" ;;
esac
OUTIL
    chmod +x "$T/bin/"*
    export PATH="$T/bin:$PATH"
}

relais_feature() {
    printf '39 socat UNIX-LISTEN:%s,fork,mode=660,user=vscode,backlog=128 UNIX-CONNECT:%s\n' \
        "$DEVZONE_RELAIS_SOCKET" "$DEVZONE_RELAIS_SOURCE" >"$T/ps.txt"
}

@test "garde : vrai socket refusé sous bats même avec DEVZONE_RELAIS_REEL=oui (code 2, rien touché)" {
    export DEVZONE_RELAIS_SOCKET=/var/run/docker.sock
    export DEVZONE_RELAIS_REEL=oui
    relais_feature
    run bash "$RELAIS"
    [ "$status" -eq 2 ]
    [[ "$output" == *"docker-relais : refus sous bats (tests)"* ]] || false
    [ ! -s "$T/outils.log" ]
    [ ! -e "$DEVZONE_RELAIS_MARQUE" ]
}

@test "relais de la feature sans -t : remplacé par socat -t 86400, mêmes options" {
    relais_feature
    run bash "$RELAIS"
    [ "$status" -eq 0 ]
    grep -qx "kill 39" "$T/outils.log"
    grep -qx "rm -f $DEVZONE_RELAIS_SOCKET" "$T/outils.log"
    grep -qx "setsid -f socat -t 86400 -lf $DEVZONE_RELAIS_LOG UNIX-LISTEN:$DEVZONE_RELAIS_SOCKET,fork,mode=660,user=vscode,backlog=128 UNIX-CONNECT:$DEVZONE_RELAIS_SOURCE" "$T/outils.log"
    [ ! -e "$DEVZONE_RELAIS_SOCKET" ]
    [ "$(cat "$DEVZONE_RELAIS_PID")" = 4242 ]
    [[ "$output" == *"socat -t 86400"* ]] || false
}

@test "relais déjà avec -t : laissé tel quel, contrôle fait" {
    printf '39 socat -t 86400 UNIX-LISTEN:%s,fork,mode=660,user=vscode,backlog=128 UNIX-CONNECT:%s\n' \
        "$DEVZONE_RELAIS_SOCKET" "$DEVZONE_RELAIS_SOURCE" >"$T/ps.txt"
    run bash "$RELAIS"
    [ "$status" -eq 0 ]
    ! grep -q "kill\|setsid" "$T/outils.log" || false
    grep -q "docker exec" "$T/outils.log"
}

@test "socat sur un autre socket, ou sudo parent : ignorés" {
    printf '7 socat UNIX-LISTEN:/autre.sock,fork UNIX-CONNECT:/x\n8 sudo socat UNIX-LISTEN:%s,fork UNIX-CONNECT:/x\n' \
        "$DEVZONE_RELAIS_SOCKET" >"$T/ps.txt"
    run bash "$RELAIS"
    [ "$status" -eq 0 ]
    ! grep -q "kill\|setsid" "$T/outils.log" || false
}

@test "sans relais socat (Linux, socket par groupe) : seul le contrôle" {
    run bash "$RELAIS"
    [ "$status" -eq 0 ]
    ! grep -q "kill\|setsid" "$T/outils.log" || false
    grep -q "docker exec .* sh -c sleep 1; echo ok" "$T/outils.log"
}

@test "docker exec long coupé : code 1, marque écrite" {
    export FAUX_EXEC=""
    run bash "$RELAIS"
    [ "$status" -eq 1 ]
    [[ "$output" == *"docker exec long coupé"* ]] || false
    grep -q "docker exec long coupé" "$DEVZONE_RELAIS_MARQUE"
}

@test "socket qui ne répond pas : code 1, marque écrite" {
    export FAUX_VERSION=1
    run bash "$RELAIS"
    [ "$status" -eq 1 ]
    grep -q "ne répond pas" "$DEVZONE_RELAIS_MARQUE"
}

@test "contrôle réussi : marque d'un échec précédent effacée" {
    echo "ancien échec" >"$DEVZONE_RELAIS_MARQUE"
    run bash "$RELAIS"
    [ "$status" -eq 0 ]
    [ ! -e "$DEVZONE_RELAIS_MARQUE" ]
}

@test "en root : pas de sudo" {
    export DEVZONE_RELAIS_SUDO=""
    relais_feature
    run bash "$RELAIS"
    [ "$status" -eq 0 ]
    ! grep -q "^sudo" "$T/outils.log" || false
    grep -qx "kill 39" "$T/outils.log"
}

@test "devzone : récapitulatif ⚠ relais Docker si la marque existe" {
    export HOME="$T/home" DEVZONE_RACINE="$T/racine" DEVZONE_ETAT="$T/etat"
    mkdir -p "$HOME" "$DEVZONE_RACINE/workspace"
    : >"$DEVZONE_ETAT"
    run bash "$DEVZONE"
    [[ "$output" != *"relais Docker"* ]] || false
    echo "docker exec long coupé (sortie : vide)" >"$DEVZONE_RELAIS_MARQUE"
    run bash "$DEVZONE"
    [[ "$output" == *"⚠ relais Docker     docker exec long coupé"*"docker-relais.sh"* ]] || false
}
