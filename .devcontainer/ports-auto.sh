#!/usr/bin/env bash
ICI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ports.sh
# shellcheck disable=SC1091
. "$ICI/ports.sh"
PORTS_AUTO_DIR="${DEVZONE_PORTS_AUTO_DIR:-/tmp/devzone-ports-auto}"
BASE="$PORTS_AUTO_DIR/${INSTANCE:-devzone}"
BRIDGES="$BASE/bridges"
VERROU="$BASE/verrou"
OCCUPES="$BASE/occupes"
ACTIFS="$BASE/actifs"
PENDING="$BASE/pending"
COURANT="$BASE/courant"
mkdir -p "$BASE" "$BRIDGES"

# État de l'activation du veilleur : off dès que ports_auto= est à off.
ports_auto_actif() { local v; v="$(grep -E '^ports_auto=' "$ETAT" 2>/dev/null | tail -1 | cut -d= -f2- || true)"; case "$v" in off|false|0|non|no) echo off ;; *) echo on ;; esac; }
# Liste des ports exclus par l'utilisateur (ports_exclus=, virgules).
ports_exclus_lus() { grep -E '^ports_exclus=' "$ETAT" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
# Ecrit (ou efface) une ligne cle=valeur dans l'etat, comme ecrire_ports pour ports=
ecrire() {
    local cle="$1" valeur="${2:-}" tmp
    mkdir -p "$(dirname "$ETAT")"
    tmp="$(mktemp)" || { echo "devzone : port : etat non enregistre : $ETAT" >&2; return 1; }
    grep -vE "^${cle}=" "$ETAT" 2>/dev/null >"$tmp" || true
    echo "${cle}=${valeur}" >>"$tmp"
    mv "$tmp" "$ETAT" || { echo "devzone : port : etat non enregistre : $ETAT" >&2; return 1; }
}
# Un port est exclu quand il figure dans la liste ports_exclus=.
port_exclu() { case ",$(ports_exclus_lus)," in *",$1,"*) return 0 ;; esac; return 1; }
# Nom du relais automatique d'un port : devzone-<instance>-auto-<port>.
nom_relais_auto() { echo "devzone-$INSTANCE-auto-$1"; }
# Relais automatique <port> déjà en vie sur le Docker de l'hôte ?
relais_auto_actif() { local nom; nom="$(nom_relais_auto "$1")"; command -v docker >/dev/null 2>&1 || return 1; [ -n "$(docker ps --filter "name=^$nom$" --format '{{.Names}}' 2>/dev/null | grep -Fx "$nom" || true)" ]; }
# Délai après disparition d'un port avant de retirer le pont et le relais.
delai_disparition() { local v; for v in DEVZONE_PORTS_AUTO_DELAI_DISPARITION DEVZONE_PORTS_AUTO_DELAI DEVZONE_PORTS_AUTO_RETARD PORTS_AUTO_DELAI PORTS_AUTO_RETARD; do [ -n "${!v:-}" ] && { echo "${!v}"; return 0; }; done; echo 10; }

# Lance le relais automatique ; échec → message et code 1 (port déjà pris marqué).
lancer_auto() {
    local port="$1" reseau="$2" ip="$3" nom sortie
    nom="$(nom_relais_auto "$port")"
    if sortie="$(docker run -d --restart unless-stopped --name "$nom" --label "devzone.instance=$INSTANCE" --label "devzone.port=$port" --label "devzone.auto=true" --network "$reseau" -p "127.0.0.1:$port:$port" "$SOCAT_IMAGE" "tcp-listen:$port,fork,reuseaddr" "tcp-connect:$ip:$port" 2>&1)"; then return 0; fi
    case "$sortie" in *"port is already allocated"*|*"address already in use"*) echo "devzone : port : port déjà utilisé sur le poste : $port" >&2 ;; *) echo "devzone : port : échec du relais $port : $sortie" >&2 ;; esac
    return 1
}
# Démarre le pont interne : socat sur l'IP du conteneur, vers le 127.0.0.1 du port.
demarrer_pont() { local port="$1" ip="$2"; local pidfile="$BRIDGES/$port.pid"; if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then return 0; fi; socat "TCP-LISTEN:$port,bind=$ip,fork,reuseaddr" "TCP:127.0.0.1:$port" >/dev/null 2>&1 & echo "$!" >"$pidfile"; }
# Arrête le pont interne (pid dans $BRIDGES).
arreter_pont() { local port="$1"; local pidfile="$BRIDGES/$port.pid"; local pid; if [ -f "$pidfile" ]; then pid="$(cat "$pidfile" 2>/dev/null || true)"; if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi; wait "$pid" 2>/dev/null || true; rm -f "$pidfile"; fi; }
# Retire le relais automatique et son pont.
fermer_auto() { local port="$1"; docker rm -f "$(nom_relais_auto "$port")" >/dev/null 2>&1 || true; arreter_pont "$port"; }

# Retire tous les relais automatiques et leurs ponts, puis vide les états.
nettoyer_auto_tout() {
    local port
    [ -f "$ACTIFS" ] && while IFS= read -r port; do [ -n "$port" ] && fermer_auto "$port"; done <"$ACTIFS"
    [ -f "$OCCUPES" ] && while IFS= read -r port; do [ -n "$port" ] && arreter_pont "$port"; done <"$OCCUPES"
    : >"$ACTIFS" 2>/dev/null || true; : >"$OCCUPES" 2>/dev/null || true; : >"$PENDING" 2>/dev/null || true; rm -f "$BRIDGES"/*.pid 2>/dev/null || true
}
# Retire les relais automatiques d'une session précédente.
nettoyer_precedents() { docker ps -a --filter "name=devzone-$INSTANCE-auto-" --format '{{.Names}}' 2>/dev/null | while IFS= read -r nom; do case "$nom" in devzone-"$INSTANCE"-auto-*) docker rm -f "$nom" >/dev/null 2>&1 || true ;; esac; done; rm -f "$BRIDGES"/*.pid 2>/dev/null || true; }

# Verrou exclusif (mkdir) avec pid : une seule instance de veilleur.
verrou_prendre() {
    local debut now age pid
    debut="$(date +%s)"
    while true; do
        if mkdir "$VERROU" 2>/dev/null; then echo "$$" >"$VERROU/pid"; return 0; fi
        now="$(date +%s)"; age=""; [ -d "$VERROU" ] && age="$(stat -c %Y "$VERROU" 2>/dev/null || stat -f %m "$VERROU" 2>/dev/null || true)"
        pid="$(cat "$VERROU/pid" 2>/dev/null || true)"
        if [ -n "$age" ] && [ "$(( now - age ))" -gt 30 ]; then rm -rf "$VERROU"; continue; fi
        if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then rm -rf "$VERROU"; continue; fi
        [ "$(( now - debut ))" -ge 5 ] && return 1
        sleep 1
    done
}

# Un tour de veilleur : relaie les ports écoutés, retire les disparus.
ports_auto_tour() {
    local port now delay sortie
    if [ "$(ports_auto_actif)" = off ]; then nettoyer_auto_tout; return 0; fi
    : >"$COURANT"
    ss -ltnH 2>/dev/null | awk '{ if (NF >= 4) print $4; else if (NF >= 1) print $1 }' | while IFS= read -r local; do
        [ -n "$local" ] || continue
        p="${local##*:}"; a="${local%:*}"; a="${a#[}"; a="${a%]}"
        case "$p" in ''|*[!0-9]*) continue ;; esac
        [ "$a" = "127.0.0.11" ] && continue
        [ "$p" -lt 1024 ] 2>/dev/null && continue
        case "$p" in 5432|8929|2224) continue ;; esac
        case ",$(lire_ports)," in *",$p,"*) continue ;; esac
        port_exclu "$p" && continue
        [ "$a" = "$IP" ] && continue
        printf '%s %s\n' "$a" "$p" >>"$COURANT"
    done
    awk '{print $2}' "$COURANT" 2>/dev/null | sort -n -u >"$BASE/actuels"
    awk '$1=="0.0.0.0" || $1=="::" || $1=="*" || $1==":::" {print $2}' "$COURANT" 2>/dev/null | sort -n -u >"$BASE/allif"
    : >"$BASE/managed"
    [ -f "$ACTIFS" ] && cat "$ACTIFS" >>"$BASE/managed"
    for f in "$BRIDGES"/*.pid; do [ -e "$f" ] || continue; basename "${f%.pid}" >>"$BASE/managed"; done
    [ -f "$OCCUPES" ] && cat "$OCCUPES" >>"$BASE/managed"
    sort -n -u "$BASE/managed" -o "$BASE/managed" 2>/dev/null || true

    if ! reseau_ip; then echo "devzone : ports-auto : conteneur devzone introuvable" >&2; return 1; fi
    now="$(date +%s)"; delay="$(delai_disparition)"
    while IFS= read -r port; do
        [ -n "$port" ] || continue
        grep -qxF "$port" "$OCCUPES" 2>/dev/null && continue
        grep -qxF "$port" "$ACTIFS" 2>/dev/null && continue
        grep -qxF "$port" "$BASE/allif" || demarrer_pont "$port" "$IP"
        # shellcheck disable=SC2153
        if sortie="$(lancer_auto "$port" "$RESEAU" "$IP" 2>&1)"; then
            grep -qxF "$port" "$ACTIFS" 2>/dev/null || echo "$port" >>"$ACTIFS"
        else
            printf '%s\n' "$sortie" >&2
            grep -qxF "$port" "$BASE/allif" || arreter_pont "$port"
            case "$sortie" in *"déjà utilisé sur le poste"*|*"already in use"*|*"already allocated"*) echo "$port" >>"$OCCUPES" ;; esac
        fi
    done <"$BASE/actuels"

    while IFS= read -r port; do
        [ -n "$port" ] || continue
        grep -qxF "$port" "$BASE/actuels" 2>/dev/null && continue
        if grep -qxF "$port" "$OCCUPES" 2>/dev/null; then
            grep -vxF "$port" "$OCCUPES" >"$OCCUPES.tmp" 2>/dev/null || true; mv "$OCCUPES.tmp" "$OCCUPES" 2>/dev/null || true
            arreter_pont "$port"; continue
        fi
        if grep -q "^$port " "$PENDING" 2>/dev/null; then
            ancien="$(grep "^$port " "$PENDING" | head -1 | cut -d' ' -f2)"
            if [ -n "$ancien" ] && [ "$(( now - ancien ))" -ge "$delay" ]; then
                fermer_auto "$port"
                grep -v "^$port " "$PENDING" >"$PENDING.tmp" 2>/dev/null || true; mv "$PENDING.tmp" "$PENDING" 2>/dev/null || true
                grep -vxF "$port" "$ACTIFS" >"$ACTIFS.tmp" 2>/dev/null || true; mv "$ACTIFS.tmp" "$ACTIFS" 2>/dev/null || true
            fi
        else
            echo "$port $now" >>"$PENDING"
        fi
    done <"$BASE/managed"

    while IFS= read -r port; do
        [ -n "$port" ] || continue
        grep -v "^$port " "$PENDING" >"$PENDING.tmp" 2>/dev/null || true; mv "$PENDING.tmp" "$PENDING" 2>/dev/null || true
    done <"$BASE/actuels"
}

# Arrête le veilleur et nettoie ses relais.
arreter_veilleur() { local pid; pid="$(cat "$VERROU/pid" 2>/dev/null || true)"; if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi; nettoyer_auto_tout; rm -rf "$VERROU"; }

# Boucle : un tour toutes les DEVZONE_PORTS_AUTO_PAS secondes.
ports_auto_boucle() {
    if ! verrou_prendre; then return 0; fi
    nettoyer_precedents
    trap 'nettoyer_auto_tout; rm -rf "$VERROU"' EXIT INT TERM
    while true; do
        [ "$(ports_auto_actif)" = off ] && { nettoyer_auto_tout; break; }
        ports_auto_tour || true
        sleep "${DEVZONE_PORTS_AUTO_PAS:-2}"
    done
}

# Exclut un port de la liste automatique (écrit ports_exclus=).
ports_auto_exclure() { valider_port "${1:-}"; local cur; cur="$(ports_exclus_lus)"; case ",$cur," in *",$1,"*) echo "port $1 déjà exclu"; return 0 ;; esac; ecrire ports_exclus "$(trier_ports "$cur,$1")"; echo "✔ port $1 exclu"; }
# Réintègre un port à la liste automatique (retire ports_exclus=).
ports_auto_inclure() { valider_port "${1:-}"; local cur reste p; cur="$(ports_exclus_lus)"; reste=""; for p in $(printf '%s' "$cur" | tr ',' ' '); do [ "$p" = "$1" ] || reste="$reste${reste:+,}$p"; done; ecrire ports_exclus "$(trier_ports "$reste")"; echo "✔ port $1 inclus"; }

# Liste les relais automatiques en vie (ou occupés sur le poste).
ports_auto_liste() {
    local port marque app
    if [ -f "$ACTIFS" ]; then
        while IFS= read -r port; do
            [ -n "$port" ] || continue
            if grep -qxF "$port" "$OCCUPES" 2>/dev/null; then printf '  %-5s %s  auto\n' "$port" "occupé sur le poste"; continue; fi
            if relais_auto_actif "$port"; then marque="● actif"; else marque="○ arrêté"; fi
            if application_repond "$port"; then app="application répond"; else app="aucune application"; fi
            printf '  %-5s %s  auto  %s\n' "$port" "$marque" "$app"
        done <"$ACTIFS"
    fi
    if [ -f "$OCCUPES" ]; then
        while IFS= read -r port; do
            [ -n "$port" ] || continue
            grep -qxF "$port" "$ACTIFS" 2>/dev/null && continue
            printf '  %-5s %s  auto\n' "$port" "occupé sur le poste"
        done <"$OCCUPES"
    fi
}

# Sortie machine (jq) des relais automatiques.
ports_auto_liste_json() {
    local port actif app json='[]' ports=""
    [ -f "$ACTIFS" ] && ports="$(cat "$ACTIFS")"
    [ -f "$OCCUPES" ] && ports="$ports"$'\n'"$(cat "$OCCUPES")"
    ports="$(printf '%s\n' "$ports" | awk 'NF' | sort -n -u)"
    while IFS= read -r port; do
        [ -n "$port" ] || continue
        if grep -qxF "$port" "$OCCUPES" 2>/dev/null; then
            json="$(jq -c --argjson port "$port" '. + [{port:$port,actif:false,application:"occupé sur le poste",auto:true}]' <<<"$json")"; continue
        fi
        if relais_auto_actif "$port"; then actif=true; else actif=false; fi
        if application_repond "$port"; then app="application répond"; else app="aucune application"; fi
        json="$(jq -c --argjson port "$port" --argjson actif "$actif" --arg app "$app" '. + [{port:$port,actif:$actif,application:$app,auto:true}]' <<<"$json")"
    done <<<"$ports"
    printf '%s\n' "$json"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
case "${1:-}" in
    ''|boucle|loop) ports_auto_boucle ;;
    tour|one|un-tour) ports_auto_tour ;;
    demarrer|start|lancer) if kill -0 "$(cat "$VERROU/pid" 2>/dev/null)" 2>/dev/null; then echo "déjà lancé"; else bash "$0" boucle >/dev/null 2>&1 & echo "lancé"; fi ;;
    arreter|stop) arreter_veilleur; echo "arrêté" ;;
    nettoyer|clean) nettoyer_auto_tout ;;
    auto) case "${2:-}" in on) ecrire ports_auto on; echo "✔ ports auto activés" ;; off) ecrire ports_auto off; arreter_veilleur; echo "✔ ports auto désactivés" ;; *) echo "devzone : port : auto on|off" >&2; exit 2 ;; esac ;;
    exclure) ports_auto_exclure "${2:-}" ;;
    inclure) ports_auto_inclure "${2:-}" ;;
    liste_auto) ports_auto_liste ;;
    liste_json_auto) ports_auto_liste_json ;;
    -h|--help|aide) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) echo "devzone : ports-auto : commande inconnue : ${1:-}" >&2; exit 2 ;;
esac
fi
