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

@test "veilleur : deux instances lancées → une seule tourne" {
    run bash "$PORTS_AUTO" demarrer
    [ "$status" -eq 0 ]
    [[ "$output" == *"lancé"* ]] || false
    sleep 2
    run bash "$PORTS_AUTO" demarrer
    [ "$status" -eq 0 ]
    [[ "$output" == *"déjà lancé"* ]] || false
    run bash "$PORTS_AUTO" arreter
    [ "$status" -eq 0 ]
    [[ "$output" == *"arrêté"* ]] || false
}
