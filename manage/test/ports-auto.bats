#!/usr/bin/env bats
# Veilleur de ports automatiques (#394) : un tour de boucle testable seul, sans
# boucle infinie ; faux ss, docker et socat dans le PATH, aucun conteneur lancé.

setup() {
    load commun
    relais_docker_isole
    kube_isole
    PORTS_AUTO="$BATS_TEST_DIRNAME/../../.devcontainer/ports-auto.sh"
    PORTS="$BATS_TEST_DIRNAME/../../.devcontainer/ports.sh"
    export DEVZONE_RACINE="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_ETAT="$BATS_TEST_TMPDIR/etat"
    export DEVZONE_INSTANCE=devzone
    export DEVZONE_PORTS_AUTO_DIR="$BATS_TEST_TMPDIR/ports-auto"
    export DEVZONE_PORTS_AUTO_DELAI=1
    mkdir -p "$BATS_TEST_TMPDIR/bin" "$DEVZONE_RACINE/workspace"
    : >"$DEVZONE_ETAT"
    : >"$BATS_TEST_TMPDIR/docker.log"
    : >"$BATS_TEST_TMPDIR/socat.log"
    : >"$BATS_TEST_TMPDIR/ss.listen"

    cat >"$BATS_TEST_TMPDIR/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
echo "docker $*" >>"$T/docker.log"
case "${1:-}" in
    inspect)
        case "$*" in
            *NetworkSettings.Networks*)
                echo "devzone_default 172.18.0.5"
                ;;
            *) exit 1 ;;
        esac
        ;;
    run)
        nom=""; prec=""
        for a in "$@"; do
            [ "$prec" = --name ] && nom="$a"
            prec="$a"
        done
        if [ "${FAUX_ECHEC_PORT:-}" = "${nom##*-}" ]; then
            echo "docker: Error response from daemon: Bind for 127.0.0.1:${nom##*-} failed: port is already allocated." >&2
            exit 1
        fi
        case "${FAUX_RUN_ECHEC:-}" in
            allocation) echo "docker: Error response from daemon: Bind for 127.0.0.1:8080 failed: port is already allocated." >&2; exit 1 ;;
            adresse) echo "docker: Error response from daemon: address already in use" >&2; exit 1 ;;
            autre) echo "docker: daemon error" >&2; exit 1 ;;
        esac
        mkdir -p "$T/relais"
        : >"$T/relais/$nom"
        echo "id-$nom"
        ;;
    ps)
        motif=""; prec=""; show_all=0
        for a in "$@"; do
            [ "$a" = "-a" ] && show_all=1
            [ "$prec" = --filter ] && motif="$a"
            prec="$a"
        done
        for f in "$T"/relais/*; do
            [ -e "$f" ] || continue
            nom="$(basename "$f")"
            m="${motif#name=}"
            m="${m#^}"
            m="${m%$}"
            if [ "$nom" = "$m" ] || [ "${nom#"$m"}" != "$nom" ]; then
                if [ "$show_all" = 1 ] || [ ! -s "$f" ]; then
                    echo "$nom"
                fi
            fi
        done
        ;;
    rm)
        nom="${3:-${2:-}}"
        rm -f "$T/relais/$nom"
        ;;
esac
exit 0
DOCKER

    cat >"$BATS_TEST_TMPDIR/bin/socat" <<'SOCAT'
#!/usr/bin/env bash
echo "socat $*" >>"$BATS_TEST_TMPDIR/socat.log"
exit 0
SOCAT

    cat >"$BATS_TEST_TMPDIR/bin/ss" <<'SS'
#!/usr/bin/env bash
cat "$BATS_TEST_TMPDIR/ss.listen"
SS

    cat >"$BATS_TEST_TMPDIR/bin/curl" <<'CURL'
#!/usr/bin/env bash
echo "curl $*" >>"$BATS_TEST_TMPDIR/curl.log"
for p in ${FAUX_REPOND:-}; do
    case "$*" in *":$p"*) exit 0 ;; esac
done
exit 7
CURL

    chmod +x "$BATS_TEST_TMPDIR/bin/"*
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "auto : port écouté sur 0.0.0.0 → relais poste, pas de pont" {
    printf 'LISTEN 0 511 0.0.0.0:8080 0.0.0.0:*\n' >"$BATS_TEST_TMPDIR/ss.listen"
    run bash "$PORTS_AUTO" tour
    [ "$status" -eq 0 ]
    grep -q 'docker run -d --restart unless-stopped --name devzone-devzone-auto-8080' "$BATS_TEST_TMPDIR/docker.log"
    grep -q -- '-p 127.0.0.1:8080:8080' "$BATS_TEST_TMPDIR/docker.log"
    grep -q 'tcp-connect:172.18.0.5:8080' "$BATS_TEST_TMPDIR/docker.log"
    [ ! -s "$BATS_TEST_TMPDIR/socat.log" ]
}

@test "auto : port écouté sur 127.0.0.1 → pont sur l'IP du conteneur, puis relais" {
    printf 'LISTEN 0 511 127.0.0.1:8080 127.0.0.1:*\n' >"$BATS_TEST_TMPDIR/ss.listen"
    run bash "$PORTS_AUTO" tour
    [ "$status" -eq 0 ]
    grep -q 'socat TCP-LISTEN:8080,bind=172.18.0.5,fork,reuseaddr' "$BATS_TEST_TMPDIR/socat.log"
    grep -q 'TCP:127.0.0.1:8080' "$BATS_TEST_TMPDIR/socat.log"
    grep -q 'docker run -d --restart unless-stopped --name devzone-devzone-auto-8080' "$BATS_TEST_TMPDIR/docker.log"
}

@test "auto : port disparu → pont et relais retirés après le délai" {
    printf 'LISTEN 0 511 127.0.0.1:8080 127.0.0.1:*\n' >"$BATS_TEST_TMPDIR/ss.listen"
    run bash "$PORTS_AUTO" tour
    [ "$status" -eq 0 ]
    grep -q 'docker run -d --restart unless-stopped --name devzone-devzone-auto-8080' "$BATS_TEST_TMPDIR/docker.log"
    : >"$BATS_TEST_TMPDIR/ss.listen"
    run bash "$PORTS_AUTO" tour
    [ "$status" -eq 0 ]
    sleep 2
    run bash "$PORTS_AUTO" tour
    [ "$status" -eq 0 ]
    grep -q 'docker rm -f devzone-devzone-auto-8080' "$BATS_TEST_TMPDIR/docker.log"
}

@test "auto : ports ignorés < 1024, DNS docker, services devzone, manuel, exclu" {
    printf 'ports=3000\nports_exclus=8080\n' >"$DEVZONE_ETAT"
    cat >"$BATS_TEST_TMPDIR/ss.listen" <<'SS'
LISTEN 0 511 127.0.0.1:80 127.0.0.1:*
LISTEN 0 511 127.0.0.1:5432 127.0.0.1:*
LISTEN 0 511 127.0.0.1:8080 127.0.0.1:*
LISTEN 0 511 127.0.0.1:8929 127.0.0.1:*
LISTEN 0 511 127.0.0.1:2224 127.0.0.1:*
LISTEN 0 511 127.0.0.1:3000 127.0.0.1:*
SS
    run bash "$PORTS_AUTO" tour
    [ "$status" -eq 0 ]
    [ "$(grep -c 'docker run' "$BATS_TEST_TMPDIR/docker.log")" -eq 0 ]
}

@test "auto : port pris sur le poste → occupé, plus aucun nouvel essai" {
    printf 'LISTEN 0 511 0.0.0.0:8080 0.0.0.0:*\n' >"$BATS_TEST_TMPDIR/ss.listen"
    FAUX_ECHEC_PORT=8080 run bash "$PORTS_AUTO" tour
    [ "$status" -eq 0 ]
    [ "$(grep -c 'docker run' "$BATS_TEST_TMPDIR/docker.log")" -eq 1 ]
    FAUX_ECHEC_PORT=8080 run bash "$PORTS_AUTO" tour
    [ "$(grep -c 'docker run' "$BATS_TEST_TMPDIR/docker.log")" -eq 1 ]
    run bash "$PORTS_AUTO" liste_auto
    [ "$status" -eq 0 ]
    [[ "$output" == *"8080"*"occupé sur le poste"* ]] || false
}

@test "auto off : aucun relais au tour suivant, les relais automatiques retirés" {
    printf 'LISTEN 0 511 127.0.0.1:8080 127.0.0.1:*\n' >"$BATS_TEST_TMPDIR/ss.listen"
    run bash "$PORTS_AUTO" tour
    [ "$status" -eq 0 ]
    grep -q 'docker run -d --restart unless-stopped --name devzone-devzone-auto-8080' "$BATS_TEST_TMPDIR/docker.log"
    run bash "$PORTS" auto off
    [ "$status" -eq 0 ]
    grep -qx 'ports_auto=off' "$DEVZONE_ETAT"
    [[ "$output" == *"ports auto désactivés"* ]] || false
    : >"$BATS_TEST_TMPDIR/docker.log"
    run bash "$PORTS_AUTO" tour
    [ "$status" -eq 0 ]
    [ "$(grep -c 'docker run' "$BATS_TEST_TMPDIR/docker.log")" -eq 0 ]
}

@test "veilleur : boucle et demarrer refusent sous bats (code 2), rien lancé" {
    run bash "$PORTS_AUTO" boucle
    [ "$status" -eq 2 ]
    [[ "$output" == *"refus"* ]] || false
    run bash "$PORTS_AUTO" demarrer
    [ "$status" -eq 2 ]
    [[ "$output" == *"refus"* ]] || false
    # Le garde-fou agit avant tout : aucun verrou, aucun relais, aucun pont.
    [ ! -e "$DEVZONE_PORTS_AUTO_DIR/devzone/verrou" ]
    [ "$(grep -c 'docker run' "$BATS_TEST_TMPDIR/docker.log")" -eq 0 ]
    [ ! -s "$BATS_TEST_TMPDIR/socat.log" ]
}

@test "veilleur : refus sans le contexte réel, message devzone reparer (code 2)" {
    # bats posé aussi : garantit que le message de refus réel est atteignable
    run env -u BATS_TEST_TMPDIR bash "$PORTS_AUTO" boucle
    [ "$status" -eq 2 ]
    [[ "$output" == *"devzone reparer"* ]] || false
    run env -u BATS_TEST_TMPDIR bash "$PORTS_AUTO" demarrer
    [ "$status" -eq 2 ]
    [[ "$output" == *"devzone reparer"* ]] || false
    [ ! -e "$DEVZONE_PORTS_AUTO_DIR/devzone/verrou" ]
}

@test "veilleur : refus même avec le contexte réel posé, sous bats (code 2)" {
    DEVZONE_PORTS_AUTO_REEL=oui run bash "$PORTS_AUTO" boucle
    [ "$status" -eq 2 ]
    DEVZONE_PORTS_AUTO_REEL=oui run bash "$PORTS_AUTO" demarrer
    [ "$status" -eq 2 ]
    [ ! -e "$DEVZONE_PORTS_AUTO_DIR/devzone/verrou" ]
    [ "$(grep -c 'docker run' "$BATS_TEST_TMPDIR/docker.log")" -eq 0 ]
}

@test "veilleur : verrou recyclé d'une instance morte, tenu par une vivante qui le rafraît, volé si rouillé" {
    run bash -c '
    . "$1"
    mkdir -p "$VERROU"
    echo 4194303 >"$VERROU/pid" # pid au-delà de la limite du noyau : titulaire mort
    verrou_prendre; echo "rc_morte=$?"
    echo $$ >"$VERROU/pid"      # titulaire vivant (ce shell), verrou vieux
    touch -d "2 minutes ago" "$VERROU"
    verrou_rafraichir
    verrou_prendre; echo "rc_vivante=$?"
    touch -d "2 minutes ago" "$VERROU"
    verrou_prendre; echo "rc_rouille=$?"
    ' x "$PORTS_AUTO"
    [ "$status" -eq 0 ]
    [[ "$output" == *"rc_morte=0"* ]] || false
    [[ "$output" == *"rc_vivante=1"* ]] || false
    [[ "$output" == *"rc_rouille=0"* ]] || false
}

@test "isolement : un vrai veilleur dans un autre dossier n'est ni lu ni modifié" {
    # Faux état d'un veilleur réel, posé hors du dossier du test (#394).
    local vrai="$BATS_TEST_TMPDIR/vrai"
    mkdir -p "$vrai/devzone/bridges" "$vrai/devzone/verrou"
    echo $$ >"$vrai/devzone/verrou/pid"
    printf '8081\n' >"$vrai/devzone/occupes"
    printf 'LISTEN 0 511 127.0.0.1:8081 127.0.0.1:*\n' >"$vrai/devzone/actifs"
    avant="$(find "$vrai" -printf '%p %s %T@\n' | sort; cat "$vrai/devzone/verrou/pid" "$vrai/devzone/occupes" "$vrai/devzone/actifs")"
    printf 'LISTEN 0 511 127.0.0.1:8080 127.0.0.1:*\n' >"$BATS_TEST_TMPDIR/ss.listen"
    # Le dossier des tests est bien celui du test, pas celui du veilleur réel.
    run bash -c '. "$1"; echo "$BASE"' x "$PORTS_AUTO"
    [ "$status" -eq 0 ]
    [ "$output" = "$BATS_TEST_TMPDIR/ports-auto/devzone" ]
    run bash "$PORTS_AUTO" tour
    [ "$status" -eq 0 ]
    grep -q 'docker run -d --restart unless-stopped --name devzone-devzone-auto-8080' "$BATS_TEST_TMPDIR/docker.log"
    [ -d "$BATS_TEST_TMPDIR/ports-auto/devzone/bridges" ]
    apres="$(find "$vrai" -printf '%p %s %T@\n' | sort; cat "$vrai/devzone/verrou/pid" "$vrai/devzone/occupes" "$vrai/devzone/actifs")"
    [ "$avant" = "$apres" ]
}

@test "teardown : seul un veilleur lancé par le test est orphelin, jamais le vrai" {
    # Faux veilleur lancé par le test : même nom de commande, BATS_TEST_TMPDIR hérité.
    bash -c 'exec -a "bash .devcontainer/ports-auto.sh boucle" sleep 60' >/dev/null 2>&1 &
    faux=$!
    # Faux veilleur sans BATS_TEST_TMPDIR : représente le vrai veilleur du conteneur.
    env -u BATS_TEST_TMPDIR bash -c 'exec -a "bash .devcontainer/ports-auto.sh boucle" sleep 60' >/dev/null 2>&1 &
    vrai=$!
    run orphelins_du_test
    [ "$status" -eq 0 ]
    echo "$output" | grep -qx "$faux"
    [ "$(echo "$output" | grep -cx "$vrai")" -eq 0 ]
    kill "$faux" "$vrai"
    wait "$faux" 2>/dev/null || true
    wait "$vrai" 2>/dev/null || true
    run orphelins_du_test
    [ -z "$output" ]
}

# Pids des veilleurs ports-auto.sh (boucle ou demarrer) dont l'environnement
# porte BATS_TEST_TMPDIR de ce test ; le vrai veilleur du conteneur n'en a pas.
orphelins_du_test() {
    local pid
    for pid in $(pgrep -f "bash +[^ ]*ports-auto[.]sh (boucle|demarrer)" 2>/dev/null); do
        if tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep -qxF "BATS_TEST_TMPDIR=$BATS_TEST_TMPDIR"; then
            echo "$pid"
        fi
    done
}

teardown() {
    # Incident #394 : aucun veilleur lancé par un test ne doit survivre au test.
    local orphelins
    orphelins="$(orphelins_du_test)"
    if [ -n "$orphelins" ]; then
        echo "veilleurs orphelins du test : $orphelins" >&2
        return 1
    fi
    return 0
}
