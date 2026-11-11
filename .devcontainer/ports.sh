#!/usr/bin/env bash
# Relais de ports (#290) : applications du conteneur devzone accessibles
# depuis 127.0.0.1 du poste, un conteneur alpine/socat par port.
#   ports.sh ouvrir <n>     ouvre le relais du port <n>
#   ports.sh liste          relais de l'état : port, actif, application
#   ports.sh fermer <n>     retire le relais et le port de l'état
#   ports.sh relancer       recrée les relais de l'état vers l'IP actuelle
#   ports.sh resume         résumé d'une ligne pour le récapitulatif devzone
# L'état est la ligne « ports=8080,3000 » de DEVZONE_ETAT (triée, sans doublon).
# RACINE : un seul dirname depuis ICI (.devcontainer) → racine du dépôt devzone.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then set -euo pipefail; fi

SOCAT_IMAGE=alpine/socat:1.8.0.3

ICI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RACINE="${DEVZONE_RACINE:-$(dirname "$ICI")}"
ETAT="${DEVZONE_ETAT:-$RACINE/.devzone.modules}"
INSTANCE="${DEVZONE_INSTANCE:-devzone}"

# Écriture sûre de l'état (#417) : verrou, temporaire dans le dossier de
# l'état, copie de secours .prec
# shellcheck source=SCRIPTDIR/etat.sh
# shellcheck disable=SC1091
. "$ICI/etat.sh"

refuse() { echo "devzone : port : $*" >&2; exit 1; }

nom_relais() { echo "devzone-$INSTANCE-port-$1"; }

port_valide() { case "${1:-}" in '' | *[!0-9]*) return 1 ;; esac; [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null; }

valider_port() { port_valide "${1:-}" || refuse "port invalide : ${1:-(aucun)} (1-65535)"; }

lire_ports() { grep -E '^ports=' "$ETAT" 2>/dev/null | tail -1 | cut -d= -f2- || true; }

trier_ports() {
    printf '%s\n' "${1:-}" | tr ',' '\n' |
        awk 'NF && $0 ~ /^[0-9]+$/ { print }' |
        sort -n -u | paste -sd, -
}

# Écrit la ligne ports= de l'état (#417 : jamais de mv hors de etat.sh)
ecrire_ports() {
    etat_ecrire ports "${1:-}" || {
        echo "devzone : port : état non enregistré : $ETAT" >&2
        exit 1
    }
}

ajouter_port() {
    local port="$1"
    ecrire_ports "$(trier_ports "$(lire_ports),$port")"
}

retirer_port() {
    local port="$1" reste="" p
    # shellcheck disable=SC2046 # liste de ports séparés par des virgules
    for p in $(printf '%s' "$(lire_ports)" | tr ',' ' '); do
        [ "$p" = "$port" ] || reste="$reste${reste:+,}$p"
    done
    ecrire_ports "$(trier_ports "$reste")"
}

# Réseau et adresse du conteneur devzone, lus sur le Docker de l'hôte : le
# relais tourne sur ce Docker et doit joindre le conteneur par son IP.
reseau_ip() {
    local ligne
    command -v docker >/dev/null 2>&1 || return 1
    ligne="$(docker inspect "$(hostname)" \
        --format '{{range $nom, $r := .NetworkSettings.Networks}}{{$nom}} {{$r.IPAddress}}{{"\n"}}{{end}}' 2>/dev/null |
        awk 'NF >= 2 && $2 != "" { print; exit }')" || return 1
    [ -n "$ligne" ] || return 1
    RESEAU="${ligne%% *}"
    IP="${ligne#* }"
    [ -n "$RESEAU" ] && [ -n "$IP" ]
}

relais_existe() {
    local nom
    nom="$(nom_relais "$1")"
    command -v docker >/dev/null 2>&1 || return 1
    [ -n "$(docker ps -a --filter "name=^$nom$" --format '{{.Names}}' 2>/dev/null |
        grep -Fx "$nom" || true)" ]
}

relais_actif() {
    local nom
    nom="$(nom_relais "$1")"
    command -v docker >/dev/null 2>&1 || return 1
    [ -n "$(docker ps --filter "name=^$nom$" --format '{{.Names}}' 2>/dev/null |
        grep -Fx "$nom" || true)" ]
}

# Lance le relais ; en cas d'échec, message clair et code 1 (l'état n'est pas
# modifié par cette fonction)
lancer() {
    local port="$1" reseau="$2" ip="$3" nom sortie
    nom="$(nom_relais "$port")"
    if sortie="$(docker run -d --restart unless-stopped \
        --name "$nom" \
        --label "devzone.instance=$INSTANCE" \
        --label "devzone.port=$port" \
        --network "$reseau" \
        -p "127.0.0.1:$port:$port" \
        "$SOCAT_IMAGE" \
        "tcp-listen:$port,fork,reuseaddr" "tcp-connect:$ip:$port" 2>&1)"; then
        return 0
    fi
    case "$sortie" in
        *"port is already allocated"* | *"address already in use"*)
            echo "devzone : port : port déjà utilisé sur le poste : $port" >&2
            ;;
        *)
            echo "devzone : port : échec du relais $port : $sortie" >&2
            ;;
    esac
    return 1
}

ouvrir() {
    local port="${1:-}"
    valider_port "$port"
    if relais_actif "$port"; then
        ajouter_port "$port"
        echo "✔ relais déjà ouvert : 127.0.0.1:$port du poste → $port du conteneur"
        return 0
    fi
    reseau_ip || refuse "conteneur devzone introuvable : Docker de l'hôte injoignable ?"
    docker rm -f "$(nom_relais "$port")" >/dev/null 2>&1 || true
    lancer "$port" "$RESEAU" "$IP" || exit 1
    ajouter_port "$port"
    echo "✔ 127.0.0.1:$port du poste → $port du conteneur (relais $(nom_relais "$port"))"
}

fermer() {
    local port="${1:-}"
    valider_port "$port"
    docker rm -f "$(nom_relais "$port")" >/dev/null 2>&1 || true
    retirer_port "$port"
    echo "✔ relais fermé : $port"
}

application_repond() { curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$1" >/dev/null 2>&1; }

liste() {
    local ports port marque app
    ports="$(trier_ports "$(lire_ports)")"
    if [ -z "$ports" ]; then
        echo "aucun relais (devzone port <n>)"
        return 0
    fi
    # shellcheck disable=SC2046 # liste de ports séparés par des virgules
    for port in $(printf '%s' "$ports" | tr ',' ' '); do
        if relais_actif "$port"; then
            marque="● actif"
        else
            marque="○ arrêté"
        fi
        if application_repond "$port"; then
            app="application répond"
        else
            app="aucune application"
        fi
        printf '  %-5s %s  %s\n' "$port" "$marque" "$app"
    done
    bash "$ICI/ports-auto.sh" liste_auto 2>/dev/null || true
}

resume() {
    local ports port sortie=""
    ports="$(trier_ports "$(lire_ports)")"
    if [ -z "$ports" ]; then
        echo "aucun (devzone port <n>)"
        return 0
    fi
    # shellcheck disable=SC2046 # liste de ports séparés par des virgules
    for port in $(printf '%s' "$ports" | tr ',' ' '); do
        if relais_actif "$port"; then
            sortie="$sortie${sortie:+, }$port ●"
        else
            sortie="$sortie${sortie:+, }$port ○"
        fi
    done
    echo "$sortie"
}

relancer() {
    local ports port rc=0
    ports="$(trier_ports "$(lire_ports)")"
    [ -n "$ports" ] || return 0
    if ! reseau_ip; then
        echo "devzone : port : relais non relancés : conteneur devzone introuvable (Docker de l'hôte injoignable ?)" >&2
        return 1
    fi
    # shellcheck disable=SC2046 # liste de ports séparés par des virgules
    for port in $(printf '%s' "$ports" | tr ',' ' '); do
        if ! port_valide "$port"; then
            echo "devzone : port : port invalide dans l'état, ignoré : $port" >&2
            rc=1
            continue
        fi
        # L'IP du conteneur change à chaque démarrage : le relais est recréé
        docker rm -f "$(nom_relais "$port")" >/dev/null 2>&1 || true
        lancer "$port" "$RESEAU" "$IP" || rc=1
    done
    return "$rc"
}

# Sortie lisible par machine de liste : tableau JSON [{port,actif,application}], via jq seul.
liste_json() {
    local ports port actif app json='[]'
    ports="$(trier_ports "$(lire_ports)")"
    if [ -z "$ports" ]; then
        printf '[]\n'
        return 0
    fi
    # shellcheck disable=SC2046 # liste de ports séparés par des virgules
    for port in $(printf '%s' "$ports" | tr ',' ' '); do
        if relais_actif "$port"; then
            actif=true
        else
            actif=false
        fi
        if application_repond "$port"; then
            app="application répond"
        else
            app="aucune application"
        fi
        json="$(jq -c --argjson port "$port" --argjson actif "$actif" --arg app "$app" \
            '. + [{port:$port,actif:$actif,application:$app,auto:false}]' <<<"$json")"
    done
    auto_json="$(bash "$ICI/ports-auto.sh" liste_json_auto 2>/dev/null || echo '[]')"
    if [ -n "$auto_json" ] && [ "$auto_json" != "[]" ]; then
        json="$(jq -s 'add' <<<"$json"$'\n'"$auto_json")"
    fi
    printf '%s\n' "$json"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
case "${1:-}" in
    '' | liste)
        if [ "${2:-}" = "--json" ]; then liste_json; else liste; fi
        ;;
    ouvrir) ouvrir "${2:-}" ;;
    fermer | --fermer) fermer "${2:-}" ;;
    relancer) relancer ;;
    resume) resume ;;
    auto) bash "$ICI/ports-auto.sh" auto "${2:-}" "${3:-}" ;;
    exclure) bash "$ICI/ports-auto.sh" exclure "${2:-}" ;;
    inclure) bash "$ICI/ports-auto.sh" inclure "${2:-}" ;;
    -h | --help | aide) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) ouvrir "$1" ;;
esac
fi
