#!/usr/bin/env bats
# Relais de ports (#290) : un conteneur alpine/socat par port, sur le Docker
# de l'hôte, de 127.0.0.1 du poste vers l'IP du conteneur devzone. Faux docker
# et curl dans le PATH : aucun conteneur lancé, arguments journalisés.

setup() {
    load commun
    kind_vide
    kube_isole
    PORTS="$BATS_TEST_DIRNAME/../../.devcontainer/ports.sh"
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    export HOME="$BATS_TEST_TMPDIR/home"
    export DEVZONE_RACINE="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_ETAT="$BATS_TEST_TMPDIR/etat"
    export DEVZONE_INSTANCE=devzone
    mkdir -p "$HOME" "$DEVZONE_RACINE/workspace" "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/relais"
    # le veilleur de ports automatiques reste sous le dossier du test (#394)
    export DEVZONE_PORTS_AUTO_DIR="$BATS_TEST_TMPDIR/ports-auto"
    : >"$DEVZONE_ETAT"
    : >"$BATS_TEST_TMPDIR/docker.log"
    : >"$BATS_TEST_TMPDIR/curl.log"

    cat >"$BATS_TEST_TMPDIR/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
echo "docker $*" >>"$T/docker.log"
case "${1:-}" in
    inspect)
        case "$*" in
            *NetworkSettings.Networks*)
                [ "${FAUX_SANS_CONTENEUR:-0}" = 1 ] && exit 1
                echo "devzone_default 172.18.0.5"
                ;;
            *)
                nom="${2:-}"
                [ -f "$T/relais/$nom" ] || exit 1
                case "$*" in *State.Running*) echo true ;; esac
                ;;
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
            allocation)
                echo "docker: Error response from daemon: Bind for 127.0.0.1:8080 failed: port is already allocated." >&2
                exit 1
                ;;
            adresse)
                echo "docker: Error response from daemon: address already in use" >&2
                exit 1
                ;;
            autre)
                echo "docker: daemon error" >&2
                exit 1
                ;;
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
            if [ "$nom" = "$m" ]; then
                if [ "$show_all" = 1 ] || [ ! -s "$f" ]; then
                    echo "$nom"
                fi
            fi
        done
        ;;
    stop)
        nom="${2:-}"
        [ -f "$T/relais/$nom" ] && echo stopped >"$T/relais/$nom"
        ;;
    rm)
        nom="${3:-${2:-}}"
        rm -f "$T/relais/$nom"
        ;;
esac
exit 0
DOCKER

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

@test "ouvrir : relais socat vers l'IP du conteneur, étiqueté, état trié" {
    run bash "$PORTS" 8080
    [ "$status" -eq 0 ]
    grep -q 'docker run -d --restart unless-stopped --name devzone-devzone-port-8080' "$BATS_TEST_TMPDIR/docker.log"
    grep -q -- '--label devzone.instance=devzone' "$BATS_TEST_TMPDIR/docker.log"
    grep -q -- '--label devzone.port=8080' "$BATS_TEST_TMPDIR/docker.log"
    grep -q -- '--network devzone_default' "$BATS_TEST_TMPDIR/docker.log"
    grep -q -- '-p 127.0.0.1:8080:8080' "$BATS_TEST_TMPDIR/docker.log"
    grep -q 'alpine/socat:1.8.0.3 tcp-listen:8080,fork,reuseaddr tcp-connect:172.18.0.5:8080' "$BATS_TEST_TMPDIR/docker.log"
    grep -qx 'ports=8080' "$DEVZONE_ETAT"
    [[ "$output" == *"127.0.0.1:8080 du poste"*"8080 du conteneur"* ]] || false
}

@test "ouvrir : relais déjà ouvert idempotent, état complété sans second docker run" {
    bash "$PORTS" 8080
    run bash "$PORTS" 8080
    [ "$status" -eq 0 ]
    [ "$(grep -c 'docker run' "$BATS_TEST_TMPDIR/docker.log")" -eq 1 ]
    [[ "$output" == *"déjà ouvert"* ]] || false
    grep -qx 'ports=8080' "$DEVZONE_ETAT"
}

@test "ouvrir : relais arrêté → rm -f puis run vers l'IP actuelle" {
    printf 'ports=8080\n' >"$DEVZONE_ETAT"
    bash "$PORTS" 8080 >/dev/null
    run "$BATS_TEST_TMPDIR/bin/docker" stop devzone-devzone-port-8080
    [ "$status" -eq 0 ]
    : >"$BATS_TEST_TMPDIR/docker.log"
    run bash "$PORTS" 8080
    [ "$status" -eq 0 ]
    grep -q 'docker rm -f devzone-devzone-port-8080' "$BATS_TEST_TMPDIR/docker.log"
    grep -q 'docker run -d --restart unless-stopped --name devzone-devzone-port-8080' "$BATS_TEST_TMPDIR/docker.log"
    grep -q 'tcp-connect:172.18.0.5:8080' "$BATS_TEST_TMPDIR/docker.log"
    [ "$(grep -c 'docker run' "$BATS_TEST_TMPDIR/docker.log")" -eq 1 ]
    grep -qx 'ports=8080' "$DEVZONE_ETAT"
    [[ "$output" == *"127.0.0.1:8080 du poste"*"8080 du conteneur"* ]] || false
}

@test "ouvrir : l'état garde les autres lignes et trie les ports" {
    printf 'ia=on\nports=3000\n' >"$DEVZONE_ETAT"
    run bash "$PORTS" 8080
    [ "$status" -eq 0 ]
    grep -qx 'ia=on' "$DEVZONE_ETAT"
    grep -qx 'ports=3000,8080' "$DEVZONE_ETAT"
}

@test "ouvrir : port invalide refusé (code 1), aucun relais, état intact" {
    printf 'ports=3000\n' >"$DEVZONE_ETAT"
    for p in "" 0 65536 abc 80a -1 999999999999999999999; do
        run bash "$PORTS" ouvrir "$p"
        [ "$status" -eq 1 ]
        [[ "$output" == *"port invalide"* ]] || false
    done
    ! grep -q 'docker run' "$BATS_TEST_TMPDIR/docker.log" || false
    grep -qx 'ports=3000' "$DEVZONE_ETAT"
}

@test "ouvrir : conteneur devzone introuvable (Docker de l'hôte absent) → refus code 1" {
    FAUX_SANS_CONTENEUR=1 run bash "$PORTS" 8080
    [ "$status" -eq 1 ]
    [[ "$output" == *"conteneur devzone introuvable"* ]] || false
    [ ! -s "$DEVZONE_ETAT" ]
}

@test "ouvrir : port déjà pris sur le poste → refus clair, état inchangé" {
    for cas in allocation adresse; do
        : >"$DEVZONE_ETAT"
        FAUX_RUN_ECHEC="$cas" run bash "$PORTS" 8080
        [ "$status" -eq 1 ]
        [[ "$output" == *"port déjà utilisé sur le poste : 8080"* ]] || false
        [ ! -s "$DEVZONE_ETAT" ]
    done
}

@test "ouvrir : autre échec de docker run → message du relais, code 1" {
    FAUX_RUN_ECHEC=autre run bash "$PORTS" 8080
    [ "$status" -eq 1 ]
    [[ "$output" == *"échec du relais 8080"*"daemon error"* ]] || false
    [ ! -s "$DEVZONE_ETAT" ]
}

@test "liste : triée sans doublon, ● actif, ○ arrêté, application derrière" {
    printf 'ports=3000,8080,8080\n' >"$DEVZONE_ETAT"
    : >"$BATS_TEST_TMPDIR/relais/devzone-devzone-port-8080"
    FAUX_REPOND=8080 run bash "$PORTS" liste
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c '^')" -eq 2 ]
    printf '%s\n' "$output" | sed -n '1p' | grep -q '3000 *○ arrêté *aucune application'
    printf '%s\n' "$output" | sed -n '2p' | grep -q '8080 *● actif *application répond'
    grep -q -- '--max-time 2 http://127.0.0.1:3000' "$BATS_TEST_TMPDIR/curl.log"
    grep -q -- '--max-time 2 http://127.0.0.1:8080' "$BATS_TEST_TMPDIR/curl.log"
}

@test "liste : aucun relais" {
    run bash "$PORTS"
    [ "$status" -eq 0 ]
    [[ "$output" == *"aucun relais"* ]] || false
}

@test "fermer : relais supprimé, port retiré de l'état, autres ports gardés" {
    bash "$PORTS" 8080
    bash "$PORTS" 3000
    run bash "$PORTS" --fermer 8080
    [ "$status" -eq 0 ]
    grep -q 'docker rm -f devzone-devzone-port-8080' "$BATS_TEST_TMPDIR/docker.log"
    [ ! -e "$BATS_TEST_TMPDIR/relais/devzone-devzone-port-8080" ]
    grep -qx 'ports=3000' "$DEVZONE_ETAT"
    run bash "$PORTS" fermer 3000
    [ "$status" -eq 0 ]
    grep -qx 'ports=' "$DEVZONE_ETAT"
}

@test "fermer : port invalide refusé (code 1)" {
    run bash "$PORTS" --fermer 70000
    [ "$status" -eq 1 ]
    [[ "$output" == *"port invalide"* ]] || false
}

@test "relancer : chaque relais recréé vers l'IP actuelle, état inchangé" {
    printf 'ports=3000,8080\n' >"$DEVZONE_ETAT"
    : >"$BATS_TEST_TMPDIR/relais/devzone-devzone-port-3000"
    : >"$BATS_TEST_TMPDIR/relais/devzone-devzone-port-8080"
    run bash "$PORTS" relancer
    [ "$status" -eq 0 ]
    grep -q 'docker rm -f devzone-devzone-port-3000' "$BATS_TEST_TMPDIR/docker.log"
    grep -q 'docker rm -f devzone-devzone-port-8080' "$BATS_TEST_TMPDIR/docker.log"
    [ "$(grep -c 'docker run' "$BATS_TEST_TMPDIR/docker.log")" -eq 2 ]
    grep -q 'tcp-connect:172.18.0.5:3000' "$BATS_TEST_TMPDIR/docker.log"
    grep -q 'tcp-connect:172.18.0.5:8080' "$BATS_TEST_TMPDIR/docker.log"
    grep -qx 'ports=3000,8080' "$DEVZONE_ETAT"
}

@test "relancer : un échec avertit sans bloquer les autres, code 1" {
    printf 'ports=3000,8080\n' >"$DEVZONE_ETAT"
    FAUX_ECHEC_PORT=3000 run bash "$PORTS" relancer
    [ "$status" -eq 1 ]
    [[ "$output" == *"port déjà utilisé sur le poste : 3000"* ]] || false
    [ "$(grep -c 'docker run' "$BATS_TEST_TMPDIR/docker.log")" -eq 2 ]
    grep -q 'tcp-connect:172.18.0.5:8080' "$BATS_TEST_TMPDIR/docker.log"
    grep -qx 'ports=3000,8080' "$DEVZONE_ETAT"
}

@test "relancer : conteneur introuvable → avertissement, code 1, état intact" {
    printf 'ports=8080\n' >"$DEVZONE_ETAT"
    FAUX_SANS_CONTENEUR=1 run bash "$PORTS" relancer
    [ "$status" -eq 1 ]
    [[ "$output" == *"relais non relancés"* ]] || false
    grep -qx 'ports=8080' "$DEVZONE_ETAT"
}

@test "instance : nom et étiquette propres à DEVZONE_INSTANCE" {
    export DEVZONE_INSTANCE=mon-devzone
    run bash "$PORTS" 8080
    [ "$status" -eq 0 ]
    grep -q -- '--name devzone-mon-devzone-port-8080' "$BATS_TEST_TMPDIR/docker.log"
    grep -q -- '--label devzone.instance=mon-devzone' "$BATS_TEST_TMPDIR/docker.log"
}

@test "devzone port : ouvre, liste et ferme par le routage de la commande" {
    run bash "$DEVZONE" port 8080
    [ "$status" -eq 0 ]
    grep -qx 'ports=8080' "$DEVZONE_ETAT"
    : >"$BATS_TEST_TMPDIR/relais/devzone-devzone-port-8080"

    run bash "$DEVZONE" port
    [ "$status" -eq 0 ]
    [[ "$output" == *"8080"*"● actif"* ]] || false

    run bash "$DEVZONE" port --fermer 8080
    [ "$status" -eq 0 ]
    grep -qx 'ports=' "$DEVZONE_ETAT"
}

@test "devzone : récapitulatif ports vers le poste, actif puis aucun" {
    printf 'ports=8080\n' >"$DEVZONE_ETAT"
    : >"$BATS_TEST_TMPDIR/relais/devzone-devzone-port-8080"
    run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"✔ ports vers le poste 8080 ●"* ]] || false

    printf 'ports=\n' >"$DEVZONE_ETAT"
    run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"○ ports vers le poste aucun (devzone port <n>)"* ]] || false
}

@test "devzone --help cite devzone port" {
    run bash "$DEVZONE" --help
    [[ "$output" == *"devzone port [<n>|--fermer <n>]"* ]] || false
}

@test "ouvrir sans DEVZONE_ETAT ni DEVZONE_RACINE" {
    unset DEVZONE_ETAT DEVZONE_RACINE
    mkdir -p "$BATS_TEST_TMPDIR/depot"
    cp -r "$BATS_TEST_DIRNAME/../../.devcontainer" "$BATS_TEST_TMPDIR/depot/.devcontainer"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    run bash "$BATS_TEST_TMPDIR/depot/.devcontainer/ports.sh" 8080
    [ "$status" -eq 0 ]
    grep -qx 'ports=8080' "$BATS_TEST_TMPDIR/depot/.devzone.modules"
    [[ "$output" == *"127.0.0.1:8080 du poste"*"8080 du conteneur"* ]] || false
}

@test "ecrire_ports : échec écriture sur stderr, code 1" {
    unset DEVZONE_ETAT DEVZONE_RACINE
    mkdir -p "$BATS_TEST_TMPDIR/depot"
    cp -r "$BATS_TEST_DIRNAME/../../.devcontainer" "$BATS_TEST_TMPDIR/depot/.devcontainer"
    export TMPDIR="/nonexistent"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    run bash "$BATS_TEST_TMPDIR/depot/.devcontainer/ports.sh" ouvrir 8080
    [[ "$output" == *"devzone : port : état non enregistré"* ]] || false
    [ "$status" -eq 1 ]
}
