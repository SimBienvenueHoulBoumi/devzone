#!/usr/bin/env bats
# Applications et services du workspace sur localhost du poste (#401). Faux kubectl
# (ss, port-forward) et faux lsof sous $BATS_TEST_TMPDIR/bin : aucun cluster ni port
# du poste touche. Le veilleur ne tourne que sous DEVZONE_PORTS_WORKSPACE_REEL=oui.

setup() {
    load commun
    relais_docker_isole
    kube_isole
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CLI="$RACINE/manage/devzone"
    SCRIPT="$RACINE/manage/scripts/ports-workspace.sh"
    T="$BATS_TEST_TMPDIR"
    mkdir -p "$T/bin" "$T/poste"
    : >"$T/ss"
    : >"$T/pris"
    cat >"$T/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
# Faux kubectl : ss lit $T/ss, port-forward reste en vie (sleep) et se journalise.
T="$BATS_TEST_TMPDIR"
echo "kubectl $*" >>"$T/kubectl.log"
case "$*" in
    "config get-contexts -o name") echo docker-desktop ;;
    *" exec "*" ss "*) cat "$T/ss" ;;
    *" get svc pgadmin "*) [ -f "$T/pgadmin" ] && cat "$T/pgadmin" ;;
    *"get pod devzone-workspace-0 "*) echo "${FAUX_POD:-Running}" ;;
    *" port-forward "*) exec sleep 120 ;;
esac
exit 0
KUBE
    cat >"$T/bin/lsof" <<'LSOF'
#!/usr/bin/env bash
echo "lsof $*" >>"$BATS_TEST_TMPDIR/lsof.log"
for a in "$@"; do
    case "$a" in -iTCP:*) ;; *) continue ;; esac
    grep -qx -- "${a#-iTCP:}" "$BATS_TEST_TMPDIR/pris" 2>/dev/null && exit 0
done
exit 1
LSOF
    chmod +x "$T/bin/kubectl" "$T/bin/lsof"
    export PATH="$T/bin:$PATH"
    export DEVZONE_PORTS_WORKSPACE_REEL=oui
    export DEVZONE_PORTS_WORKSPACE_PAS=0.2
    export DEVZONE_WORKSPACE_ATTENTE=1 DEVZONE_WORKSPACE_PAS=0.1
    : >"$T/kubectl.log"
}

teardown() {
    ( cd "$T/poste" && DEVZONE_PORTS_WORKSPACE_REEL=oui bash "$CLI" workspace ports arreter >/dev/null 2>&1 ) || true
}

# Ecoute simulee dans le pod : une ligne ss -ltnH par port donne.
ecoute() {
    : >"$T/ss"
    local p
    for p in "$@"; do echo "LISTEN 0 511 0.0.0.0:$p 0.0.0.0:*" >>"$T/ss"; done
}

# Un tour du veilleur, depuis le dossier du poste de test.
tour() {
    cd "$T/poste" && run bash "$SCRIPT" tour
}

# Le processus $1 vit-il ? Un zombie (mort, pas encore récolté par PID 1 du conteneur) est mort.
vivant() {
    kill -0 "$1" 2>/dev/null || return 1
    [ "$(ps -o stat= -p "$1" 2>/dev/null | cut -c1)" != Z ]
}

# Attend 5 s au plus que le fichier pid du veilleur existe.
attendre_pid_veilleur() {
    local i
    for i in $(seq 50); do
        [ -s "$T/poste/.devzone.ports-workspace/pid" ] && return 0
        sleep 0.1
    done
    return 1
}

# Attend 5 s au plus que le processus $1 ne vive plus et que le fichier pid ait disparu.
attendre_arret() {
    local i
    for i in $(seq 50); do
        if ! vivant "$1" && [ ! -e "$T/poste/.devzone.ports-workspace/pid" ]; then return 0; fi
        sleep 0.1
    done
    return 1
}

@test "ports : nouveau port du pod relaye sur 127.0.0.1 seulement" {
    ecoute 5173
    tour
    [ "$status" -eq 0 ]
    [[ "$output" == *"port 5173 relayé"* ]] || false
    sleep 0.3
    grep -q -- "port-forward --address 127.0.0.1 pod/devzone-workspace-0 5173:5173" "$T/kubectl.log" || false
}

@test "ports : ports inferieurs a 1024 et ports internes ignores" {
    ecoute 80 1023 2475 1234 3000
    tour
    sleep 0.3
    [ "$(grep -c port-forward "$T/kubectl.log")" -eq 1 ]
    grep -q "3000:3000" "$T/kubectl.log" || false
}

@test "ports : port deja relaye, pas de second port-forward" {
    ecoute 5173
    tour
    tour
    sleep 0.3
    [ "$(grep -c port-forward "$T/kubectl.log")" -eq 1 ]
}

@test "ports : port disparu, port-forward arrete" {
    ecoute 5173
    tour
    pid="$(cat "$T/poste/.devzone.ports-workspace/relais/5173")"
    kill -0 "$pid"
    ecoute
    tour
    sleep 0.3
    ! kill -0 "$pid" 2>/dev/null || false
    [ ! -e "$T/poste/.devzone.ports-workspace/relais/5173" ]
}

@test "ports : port pris sur le poste, signale une seule fois, pas relaye" {
    echo 5173 >"$T/pris"
    ecoute 5173
    tour
    [[ "$output" == *"⚠ port 5173 déjà pris sur le poste, non relayé"* ]] || false
    tour
    [[ "$output" != *"déjà pris"* ]] || false
    ! grep -q port-forward "$T/kubectl.log" || false
}

@test "ports : services de devzone relayes quand postgres est actif" {
    echo "postgres=on" >"$T/poste/.devzone.modules"
    echo 5433 >"$T/pgadmin"
    tour
    sleep 0.3
    grep -q -- "--namespace devzone-postgres port-forward --address 127.0.0.1 svc/postgres 5432:5432" "$T/kubectl.log" || false
    grep -q -- "port-forward --address 127.0.0.1 svc/pgadmin 5433:5433" "$T/kubectl.log" || false
}

@test "ports : sans module postgres, aucun service relaye" {
    tour
    ! grep -q port-forward "$T/kubectl.log" || false
}

@test "ports : service mysql relaye sur 3306 quand mysql est actif" {
    echo "mysql=on" >"$T/poste/.devzone.modules"
    tour
    sleep 0.3
    grep -q -- "--namespace devzone-mysql port-forward --address 127.0.0.1 svc/mysql 3306:3306" "$T/kubectl.log" || false
}

@test "ports : sans module mysql, aucun port 3306 relaye" {
    echo "postgres=on" >"$T/poste/.devzone.modules"
    tour
    sleep 0.3
    ! grep -q "svc/mysql" "$T/kubectl.log" || false
}

@test "ports demarrer : un seul veilleur, arreter le retire avec ses port-forward" {
    ecoute 5173
    cd "$T/poste"
    run bash "$CLI" workspace ports demarrer
    [ "$status" -eq 0 ]
    attendre_pid_veilleur || false
    veilleur="$(cat .devzone.ports-workspace/pid)"
    kill -0 "$veilleur" || false
    run bash "$CLI" workspace ports demarrer
    [[ "$output" == *"déjà lancé (pid $veilleur)"* ]] || false
    sleep 1
    pid="$(cat .devzone.ports-workspace/relais/5173)"
    run bash "$CLI" workspace ports etat
    [[ "$output" == *"actif"*"127.0.0.1:5173 relayé"* ]] || false
    run bash "$CLI" workspace ports arreter
    [ "$status" -eq 0 ]
    attendre_arret "$veilleur" || false
    ! vivant "$pid" || false
    run bash "$CLI" workspace ports etat
    [[ "$output" == *"arrêté"* ]] || false
}

@test "ports demarrer : refuse sous bats sans DEVZONE_PORTS_WORKSPACE_REEL" {
    unset DEVZONE_PORTS_WORKSPACE_REEL
    cd "$T/poste"
    run bash "$CLI" workspace ports demarrer
    [[ "$output" == *"refusé sous bats"* ]] || false
    [ ! -e .devzone.ports-workspace/pid ]
    [ -z "$(ps -eo args | grep "[p]orts-workspace.sh boucle" || true)" ]
}

@test "workspace demarrer et arreter : veilleur lance puis arrete" {
    export PATH="$T/bin:$PATH"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$T/bin/helm"
    chmod +x "$T/bin/helm"
    ecoute 3000
    cd "$T/poste"
    run bash "$CLI" workspace demarrer
    [ "$status" -eq 0 ]
    attendre_pid_veilleur || false
    veilleur="$(cat .devzone.ports-workspace/pid)"
    kill -0 "$veilleur" || false
    run bash "$CLI" workspace arreter
    [ "$status" -eq 0 ]
    attendre_arret "$veilleur" || false
}
