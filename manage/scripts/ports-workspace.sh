#!/usr/bin/env bash
# Applications et services du workspace Kubernetes sur localhost du poste (#401).
# Sourcé par manage/workspace.sh (fonctions ports_*) ; lancé directement avec
# « boucle » ou « tour », il est le veilleur du poste : un seul, verrou mkdir et pid
# dans .devzone.ports-workspace/. Il relaie par kubectl port-forward, sur 127.0.0.1
# seulement, les ports TCP ≥ 1024 en écoute dans le pod, et les services de devzone
# des modules actifs de .devzone.modules. Garde-fou : jamais sous bats sans
# DEVZONE_PORTS_WORKSPACE_REEL=oui.

PW_POD="devzone-workspace-0"
PW_NS="devzone-workspace"
# Ports internes du pod, jamais relayés : kubedock et buildkit.
PW_INTERNES=" 2475 1234 "
# Port du service pgAdmin : lu dans le service, sans lui rien n'est relayé.
PW_JSONPATH='jsonpath={.spec.ports[0].port}'

# Dossier d'état du veilleur : verrou, pid, relais, ports signalés, journal.
pw_dir() { printf '%s' "${DEVZONE_PORTS_WORKSPACE_DIR:-$PWD/.devzone.ports-workspace}"; }

# Drapeau de contexte kubectl : devzone s'il existe, sinon le contexte courant.
pw_ctx() {
    if kubectl config get-contexts -o name 2>/dev/null | grep -qx 'devzone'; then
        printf -- '--context devzone'
    fi
}

# kubectl du veilleur : contexte devzone s'il existe, puis les arguments reçus.
pw_kubectl() {
    # shellcheck disable=SC2046
    kubectl $(pw_ctx) "$@"
}

# Garde-fou : refuse sous bats sans DEVZONE_PORTS_WORKSPACE_REEL=oui (message si $1 vide).
pw_garde() {
    if [ -n "${BATS_TEST_TMPDIR:-}" ] && [ "${DEVZONE_PORTS_WORKSPACE_REEL:-}" != oui ]; then
        [ -n "${1:-}" ] || echo "✖ veilleur des ports refusé sous bats (DEVZONE_PORTS_WORKSPACE_REEL=oui requis)" >&2
        return 2
    fi
}

# Le processus $1 est-il en vie ?
pw_vivant() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

# Ports TCP ≥ 1024 en écoute dans le pod (ss -ltnH), hors ports internes, un par ligne.
pw_ports_pod() {
    local p
    pw_kubectl --namespace "$PW_NS" exec "$PW_POD" -c workspace -- ss -ltnH 2>/dev/null |
        awk '{n=split($4,a,":"); print a[n]}' | sort -un | while read -r p; do
        case "$p" in '' | *[!0-9]*) continue ;; esac
        [ "$p" -ge 1024 ] || continue
        case "$PW_INTERNES" in *" $p "*) continue ;; esac
        echo "$p"
    done
}

# Services de devzone à relayer, une ligne « port|namespace|cible » par service des
# modules actifs : postgres (5432), et pgAdmin s'il existe dans le namespace.
pw_services() {
    grep -qxE 'postgres=(on|true|oui)' .devzone.modules 2>/dev/null || return 0
    echo "5432|devzone-postgres|svc/postgres"
    local port
    port="$(pw_kubectl --namespace devzone-postgres get svc pgadmin -o "$PW_JSONPATH" 2>/dev/null || true)"
    case "$port" in '' | *[!0-9]*) ;; *) echo "$port|devzone-postgres|svc/pgadmin" ;; esac
}

# Le port $1 est-il déjà pris sur le poste ? (lsof, sinon nc -z)
pw_pris() {
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
    else
        nc -z 127.0.0.1 "$1" >/dev/null 2>&1
    fi
}

# Lance le relais du port $1 vers la cible $3 du namespace $2, sauf s'il vit déjà ;
# port pris sur le poste : une seule ligne d'avertissement par port.
pw_relayer() {
    local port="$1" ns="$2" cible="$3" d pid
    d="$(pw_dir)"
    pid="$(cat "$d/relais/$port" 2>/dev/null || true)"
    pw_vivant "$pid" && return 0
    if pw_pris "$port"; then
        [ -e "$d/pris/$port" ] || { : >"$d/pris/$port"; echo "⚠ port $port déjà pris sur le poste, non relayé"; }
        return 0
    fi
    # shellcheck disable=SC2046
    kubectl $(pw_ctx) --namespace "$ns" port-forward --address 127.0.0.1 "$cible" "$port:$port" </dev/null >/dev/null 2>&1 &
    echo $! >"$d/relais/$port"
    rm -f "$d/pris/$port"
    echo "→ port $port relayé sur 127.0.0.1"
}

# Arrête le relais du port $1 et oublie son avertissement.
pw_retirer() {
    local d pid
    d="$(pw_dir)"
    pid="$(cat "$d/relais/$1" 2>/dev/null || true)"
    if pw_vivant "$pid"; then kill "$pid" 2>/dev/null || true; fi
    rm -f "$d/relais/$1" "$d/pris/$1"
}

# Un tour du veilleur : relaie les nouveaux ports, retire ceux qui ont disparu.
pw_tour() {
    local d voulus="" p ns cible l f
    d="$(pw_dir)"
    mkdir -p "$d/relais" "$d/pris"
    while IFS='|' read -r p ns cible; do
        [ -n "$p" ] || continue
        voulus="$voulus $p "
        pw_relayer "$p" "$ns" "$cible"
    done <<<"$(pw_services)"
    for p in $(pw_ports_pod); do
        case "$voulus" in *" $p "*) continue ;; esac
        voulus="$voulus $p "
        pw_relayer "$p" "$PW_NS" "pod/$PW_POD"
    done
    for f in "$d"/relais/* "$d"/pris/*; do
        [ -e "$f" ] || continue
        l="$(basename "$f")"
        case "$voulus" in *" $l "*) ;; *) pw_retirer "$l" ;; esac
    done
}

# Retire tous les relais du dossier d'état.
pw_retirer_tout() {
    local f
    for f in "$(pw_dir)"/relais/*; do
        if [ -e "$f" ]; then pw_retirer "$(basename "$f")"; fi
    done
}

# Boucle du veilleur : un tour toutes les 3 s ; à l'arrêt, retire ses relais et son verrou.
pw_boucle() {
    local d
    d="$(pw_dir)"
    trap 'pw_retirer_tout; rm -rf "$d/verrou" "$d/pid"; exit 0' TERM INT
    while :; do
        pw_tour || true
        sleep "${DEVZONE_PORTS_WORKSPACE_PAS:-3}" &
        wait $!
    done
}

# Démarre le veilleur, un seul : verrou mkdir, pid noté ; $1=silence : sans message de garde.
# shellcheck disable=SC2120
ports_demarrer() {
    pw_garde "${1:-}" || return 0
    local d pid
    d="$(pw_dir)"
    mkdir -p "$d"
    pid="$(cat "$d/pid" 2>/dev/null || true)"
    if pw_vivant "$pid"; then
        echo "Ports du workspace : veilleur déjà lancé (pid $pid)"
        return 0
    fi
    rm -rf "$d/verrou"
    mkdir "$d/verrou" 2>/dev/null || return 0
    nohup bash "${BASH_SOURCE[0]}" boucle >>"$d/journal.log" 2>&1 &
    echo $! >"$d/pid"
    disown 2>/dev/null || true
    echo "Ports du workspace : veilleur lancé, journal $d/journal.log"
}

# Arrête le veilleur et tous ses port-forward ; sans veilleur, retire les restes.
ports_arreter() {
    local d pid
    d="$(pw_dir)"
    pid="$(cat "$d/pid" 2>/dev/null || true)"
    if pw_vivant "$pid"; then
        kill "$pid" 2>/dev/null || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do pw_vivant "$pid" || break; sleep 0.2; done
    fi
    pw_retirer_tout
    rm -rf "$d/verrou" "$d/pid"
}

# Affiche l'état : veilleur, ports relayés, ports pris signalés.
ports_etat() {
    local d pid f
    d="$(pw_dir)"
    pid="$(cat "$d/pid" 2>/dev/null || true)"
    if pw_vivant "$pid"; then echo "Veilleur des ports : actif (pid $pid)"; else echo "Veilleur des ports : arrêté"; fi
    for f in "$d"/relais/*; do
        if [ -e "$f" ] && pw_vivant "$(cat "$f")"; then echo "  127.0.0.1:$(basename "$f") relayé"; fi
    done
    for f in "$d"/pris/*; do
        if [ -e "$f" ]; then echo "  ⚠ port $(basename "$f") déjà pris sur le poste, non relayé"; fi
    done
    return 0
}

# Sous-commande « devzone workspace ports [demarrer|arreter|etat] » (défaut : etat).
ports() {
    case "${1:-etat}" in
        demarrer) ports_demarrer ;;
        arreter) ports_arreter ;;
        etat) ports_etat ;;
        *) echo "✖ devzone workspace ports demarrer|arreter|etat" >&2; return 1 ;;
    esac
}

# Lancé directement : la boucle du veilleur, ou un seul tour (tests).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    pw_garde quiet || exit 2
    case "${1:-}" in
        boucle) pw_boucle ;;
        tour) pw_tour ;;
    esac
fi
