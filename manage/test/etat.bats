#!/usr/bin/env bats
# Écriture sûre de l'état des modules (#417) : verrou, temporaire dans le
# dossier de l'état (jamais absent pour un lecteur), copie de secours,
# restauration, reconstruction depuis les namespaces, veilleur qui ne suit
# pas un état douteux. État, racine et outils sous $BATS_TEST_TMPDIR.

setup() {
    load commun
    relais_docker_isole
    kube_isole
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    ETAT_SH="$BATS_TEST_DIRNAME/../../.devcontainer/etat.sh"
    PORTS_AUTO="$BATS_TEST_DIRNAME/../../.devcontainer/ports-auto.sh"
    export DEVZONE_RACINE="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_ETAT="$BATS_TEST_TMPDIR/racine/.devzone.modules"
    export DEVZONE_INSTANCE=devzone
    export DEVZONE_PORTS_AUTO_DIR="$BATS_TEST_TMPDIR/ports-auto"
    export GIT_CONFIG_NOSYSTEM=1
    mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/relais" "$DEVZONE_RACINE/workspace"
    cd "$BATS_TEST_TMPDIR" || return 1

    # faux kubectl : namespaces étiquetés devzone selon FAUX_NS (#417, étape 3)
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"$BATS_TEST_TMPDIR/kubectl.log"
    case "$*" in
    "config get-contexts -o name") printf 'devzone\ndocker-desktop\n' ;;
    get\ namespaces*)
        for n in ${FAUX_NS:-}; do printf 'namespace/%s\n' "$n"; done
        ;;
    *"config view"*)
        nom=""
        for c in devzone docker-desktop; do
            if [[ "$*" == *"$c"* ]]; then nom="$c"; break; fi
        done
        case "$nom" in
            devzone | docker-desktop) echo "docker-desktop" ;;
            *) exit 1 ;;
        esac
        ;;
    *) exit 1 ;;
esac
exit 0
KUBE
    # faux docker : relais notés dans un fichier, aucun conteneur
    cat >"$BATS_TEST_TMPDIR/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
echo "docker $*" >>"$T/docker.log"
case "${1:-}" in
    inspect) echo "devzone_default 172.18.0.5" ;;
    run)
        nom=""; prec=""
        for a in "$@"; do
            [ "$prec" = --name ] && nom="$a"
            prec="$a"
        done
        mkdir -p "$T/relais"; : >"$T/relais/$nom"; echo "id-$nom"
        ;;
    rm) rm -f "$T/relais/${3:-${2:-}}" ;;
    ps) ;;
esac
exit 0
DOCKER
    # faux ss et socat : le veilleur voit un port écouté, rien n'est lancé
    cat >"$BATS_TEST_TMPDIR/bin/ss" <<'SS'
#!/usr/bin/env bash
cat "$BATS_TEST_TMPDIR/ss.listen" 2>/dev/null
exit 0
SS
    cat >"$BATS_TEST_TMPDIR/bin/socat" <<'SOCAT'
#!/usr/bin/env bash
echo "socat $*" >>"$BATS_TEST_TMPDIR/socat.log"
exit 0
SOCAT
    # faux npm : versions.sh --installees répond sans outil installé
    cat >"$BATS_TEST_TMPDIR/bin/npm" <<'NPM'
#!/usr/bin/env bash
echo "npm $*" >>"$BATS_TEST_TMPDIR/npm.log"
case "${1:-}" in ls) printf '{"dependencies":{}}\n' ;; esac
exit 0
NPM
    chmod +x "$BATS_TEST_TMPDIR/bin/"*
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    : >"$BATS_TEST_TMPDIR/docker.log"
    : >"$BATS_TEST_TMPDIR/ss.listen"
}

# Écrivain concurrent : $1 = préfixe de clé, $2 = nombre de clés (#417)
ecrivain() {
    ETAT="$DEVZONE_ETAT" bash -c '
        . "$1"
        i=1
        while [ "$i" -le "$2" ]; do
            etat_ecrire "$3$i" on || exit 1
            i=$((i + 1))
        done
    ' _ "$ETAT_SH" "$2" "$1"
}

# Lecteur : boucle sur l'existence de l'état jusqu'à la fin des écritures
lecteur() {
    while [ ! -f "$BATS_TEST_TMPDIR/fin-lecture" ]; do
        [ -f "$DEVZONE_ETAT" ] || { echo "état absent pendant une écriture (#417)"; return 1; }
    done
    return 0
}

@test "deux écrivains concurrents : aucune ligne perdue" {
    ecrivain a 25 &
    pid_a=$!
    ecrivain b 25 &
    pid_b=$!
    wait "$pid_a"
    wait "$pid_b"
    i=1
    while [ "$i" -le 25 ]; do
        grep -qx "a$i=on" "$DEVZONE_ETAT" || { echo "ligne a$i perdue"; false; }
        grep -qx "b$i=on" "$DEVZONE_ETAT" || { echo "ligne b$i perdue"; false; }
        i=$((i + 1))
    done
}

@test "lecteur pendant les écritures : le fichier n'est jamais absent" {
    # Le temporaire d'une écriture part d'un autre système de fichiers que
    # l'état : sans le fix, le mv copie puis supprime et le lecteur voit le
    # fichier absent (#417)
    if touch /dev/shm/devzone-etat-$$ 2>/dev/null; then
        rm -f /dev/shm/devzone-etat-$$
        export TMPDIR=/dev/shm
    fi
    printf 'ia=off\n' >"$DEVZONE_ETAT"
    lecteur &
    pid_l=$!
    ecrivain a 25 &
    pid_a=$!
    ecrivain b 25 &
    pid_b=$!
    code=0
    wait "$pid_a" || code=1
    wait "$pid_b" || code=1
    : >"$BATS_TEST_TMPDIR/fin-lecture"
    wait "$pid_l" || code=1
    [ "$code" -eq 0 ]
}

@test "état supprimé avec copie de secours : restauré" {
    printf 'ia=on\nkubernetes=off\ngitlab=on\npostgres=on\n' >"$DEVZONE_ETAT.prec"
    rm -f "$DEVZONE_ETAT"
    run bash "$DEVZONE" actif postgres
    [ "$status" -eq 0 ]
    [[ "$output" == *"restauré depuis la copie de secours"* ]] || false
    grep -qx 'postgres=on' "$DEVZONE_ETAT"
    grep -qx 'gitlab=on' "$DEVZONE_ETAT"
    [ -f "$DEVZONE_ETAT.recouvre" ]
}

@test "état supprimé sans copie de secours, namespaces devzone : reconstruit" {
    printf 'ia=on\n' >"$DEVZONE_ETAT"
    rm -f "$DEVZONE_ETAT"
    FAUX_NS="devzone-postgres devzone-gitlab devzone-mysql" run bash "$DEVZONE" actif postgres
    [ "$status" -eq 0 ]
    [[ "$output" == *"reconstruit depuis les namespaces"* ]] || false
    grep -qx 'postgres=on' "$DEVZONE_ETAT"
    grep -qx 'gitlab=on' "$DEVZONE_ETAT"
    grep -qx 'mysql=on' "$DEVZONE_ETAT"
    grep -qx 'ia=off' "$DEVZONE_ETAT"
    # cluster= attend le contexte réel de l'hôte qui pointe sur le cluster des
    # services (docker-desktop ici), pas le contexte « devzone »
    grep -qx 'cluster=docker-desktop' "$DEVZONE_ETAT"
    [ -f "$DEVZONE_ETAT.recouvre" ]
}

@test "reconstruction : contexte hôte introuvable, pas de ligne cluster= mais reconstruit" {
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
case "$*" in "config get-contexts -o name"|"config view") exit 1 ;; get\ namespaces*) for n in ${FAUX_NS:-}; do printf 'namespace/%s\n' "$n"; done ;; esac
KUBE
    chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
    printf 'ia=on\n' >"$DEVZONE_ETAT"
    rm -f "$DEVZONE_ETAT"
    FAUX_NS="devzone-postgres devzone-gitlab" run bash "$DEVZONE" actif postgres
    [ "$status" -eq 0 ]
    [[ "$output" == *"reconstruit depuis les namespaces"* ]] || false
    [[ "$output" == *"aucun contexte d'hôte"* ]] || false
    grep -qx 'postgres=on' "$DEVZONE_ETAT"
    ! grep -q '^cluster=' "$DEVZONE_ETAT" || false
    [ -f "$DEVZONE_ETAT.recouvre" ]
}

@test "première installation : état par défaut, sans copie de secours" {
    run bash "$DEVZONE" actif ia
    [ "$status" -eq 1 ]
    grep -qx 'ia=off' "$DEVZONE_ETAT"
    grep -qx 'kubernetes=off' "$DEVZONE_ETAT"
    grep -qx 'gitlab=off' "$DEVZONE_ETAT"
    run test -e "$DEVZONE_ETAT.prec"
    [ "$status" -ne 0 ]
    run test -e "$DEVZONE_ETAT.recouvre"
    [ "$status" -ne 0 ]
}

@test "aucun mv ni redirection vers l'état hors de etat.sh" {
    racine="$BATS_TEST_DIRNAME/../.."
    trouve="$(grep -rn 'mv .*"\$ETAT"\|> *"\$ETAT"' "$racine/.devcontainer" "$racine/manage" 2>/dev/null |
        grep -v '/etat.sh:' | grep -v '/test/' || true)"
    [ -z "$trouve" ] || { echo "écriture directe hors etat.sh : $trouve"; false; }
}

@test "restauration fraîche : le veilleur de ports ne fait rien 60 s" {
    printf 'ia=on\nports_auto=on\n' >"$DEVZONE_ETAT.prec"
    rm -f "$DEVZONE_ETAT"
    run bash "$DEVZONE" actif ia
    [ "$status" -eq 0 ]
    [ -f "$DEVZONE_ETAT.recouvre" ]
    # Port que le veilleur relaierait d'ordinaire (0.0.0.0, pas l'IP du conteneur)
    echo 'LISTEN 0 128 0.0.0.0:8080 0.0.0.0:*' >"$BATS_TEST_TMPDIR/ss.listen"
    run bash "$PORTS_AUTO" tour
    [ "$status" -eq 0 ]
    ! grep -q "docker run" "$BATS_TEST_TMPDIR/docker.log" || false
}

@test "état restauré non confirmé : le veilleur ne désinstalle pas" {
    printf 'ia=on\nports_auto=off\n' >"$DEVZONE_ETAT"
    # Marque de plus de 60 s : le délai est passé, rien n'est confirmé
    echo $(( $(date +%s) - 120 )) >"$DEVZONE_ETAT.recouvre"
    mkdir -p "$DEVZONE_PORTS_AUTO_DIR/devzone"
    printf '8080\n' >"$DEVZONE_PORTS_AUTO_DIR/devzone/actifs"
    : >"$BATS_TEST_TMPDIR/relais/devzone-devzone-auto-8080"
    run bash "$PORTS_AUTO" tour
    [ "$status" -eq 0 ]
    [ -e "$BATS_TEST_TMPDIR/relais/devzone-devzone-auto-8080" ]
}

@test "devzone appliquer confirme l'état : la désinstallation reprend" {
    printf 'ia=off\ngitlab=off\npostgres=off\nkubernetes=off\nports_auto=off\n' >"$DEVZONE_ETAT"
    echo $(( $(date +%s) - 120 )) >"$DEVZONE_ETAT.recouvre"
    mkdir -p "$DEVZONE_PORTS_AUTO_DIR/devzone"
    printf '8080\n' >"$DEVZONE_PORTS_AUTO_DIR/devzone/actifs"
    : >"$BATS_TEST_TMPDIR/relais/devzone-devzone-auto-8080"
    run bash "$DEVZONE" appliquer
    [ "$status" -eq 0 ]
    run test -e "$DEVZONE_ETAT.recouvre"
    [ "$status" -ne 0 ]
    run bash "$PORTS_AUTO" tour
    [ "$status" -eq 0 ]
    run test -e "$BATS_TEST_TMPDIR/relais/devzone-devzone-auto-8080"
    [ "$status" -ne 0 ]
}
