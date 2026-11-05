#!/usr/bin/env bash
# Relais du socket Docker (#293), lancé en premier par demarrage.sh.
#
# Pourquoi : la feature docker-outside-of-docker relaie le socket de l'hôte
# par « socat UNIX-LISTEN:/var/run/docker.sock,… UNIX-CONNECT:… » sans
# option -t (seulement sous Docker Desktop, socket au gid 0 ; sous Linux elle
# passe par un groupe, sans socat). Dès que le client ferme son côté (un
# « docker exec » sans entrée standard), socat coupe la connexion 0,5 s plus
# tard : la sortie est tronquée et docker exec renvoie quand même 0. kind lance
# kubeadm init ainsi, et le croit réussi au bout de 0,5 s (cluster kind et
# module gitlab impossibles depuis devzone). Le même socat avec -t 86400 laisse
# passer la réponse du démon jusqu'à ce qu'il ferme lui-même.
#
# Ce que fait le script : relais de la feature sans -t → remplacé par le même
# avec -t 86400 (fichier PID de la feature mis à jour, docker-init.sh ne le
# relance donc pas) ; puis contrôle qu'un docker exec long va au bout. Sans
# relais socat (Linux), seul le contrôle est fait. Idempotent.
#
# Sûr par construction : chemins et commandes réglables (tests : tout sous un
# dossier temporaire), et refus de toucher au vrai socket sans
# DEVZONE_RELAIS_REEL=oui, que seul demarrage.sh pose.
# Code : 0 contrôle réussi, 1 contrôle en échec (marque écrite pour le
# récapitulatif devzone), 2 refus de la garde. Compatible bash 3.2.
set -euo pipefail

SOCKET="${DEVZONE_RELAIS_SOCKET:-/var/run/docker.sock}"
SOURCE="${DEVZONE_RELAIS_SOURCE:-/var/run/docker-host.sock}"
# Fichiers de la feature (/usr/local/share/docker-init.sh : SOCAT_PID, SOCAT_LOG)
PID_FICHIER="${DEVZONE_RELAIS_PID:-/tmp/vscr-docker-from-docker.pid}"
JOURNAL="${DEVZONE_RELAIS_LOG:-/tmp/vscr-docker-from-docker.log}"
UTILISATEUR="${DEVZONE_RELAIS_UTILISATEUR:-vscode}"
DOCKER="${DEVZONE_RELAIS_DOCKER:-docker}"
# Marque d'échec lue par le récapitulatif (.devcontainer/devzone) : propre au
# conteneur, effacée à chaque redémarrage avec /tmp
MARQUE="${DEVZONE_RELAIS_MARQUE:-/tmp/devzone-relais-docker.echec}"
ATTENTE="${DEVZONE_RELAIS_ATTENTE:-10}"
# Le relais de la feature tourne en root : sudo sauf si on est déjà root
if [ -n "${DEVZONE_RELAIS_SUDO+x}" ]; then
    SUDO="$DEVZONE_RELAIS_SUDO"
elif [ "$(id -u)" = 0 ]; then
    SUDO=""
else
    SUDO=sudo
fi

if [ -n "${BATS_TEST_TMPDIR:-}" ] && [ "$SOCKET" = /var/run/docker.sock ]; then
    echo "docker-relais : refus sous bats (tests)" >&2
    exit 2
fi

if [ "$SOCKET" = /var/run/docker.sock ] && [ "${DEVZONE_RELAIS_REEL:-}" != oui ]; then
    echo "docker-relais : refus de toucher au vrai socket ($SOCKET) sans DEVZONE_RELAIS_REEL=oui" >&2
    exit 2
fi

# $SUDO vide : commande lancée par env, jamais en commande intégrée (kill est
# un builtin de bash : env passe par le PATH, comme sudo ; les tests y mettent
# leurs faux outils)
en_root() {
    if [ -n "$SUDO" ]; then
        "$SUDO" "$@"
    else
        env "$@"
    fi
}

echec() {
    echo "docker-relais : $1" >&2
    printf '%s\n' "$1" >"$MARQUE" 2>/dev/null || true
    exit 1
}

# « <pid> <a_t> » du socat qui écoute sur $SOCKET (a_t : 1 s'il a -t), rien
# sinon. Seul le processus socat lui-même compte (pas un « sudo socat » parent),
# et seulement s'il écoute sur ce socket-là.
relais_trouve() {
    local pid args
    while read -r pid args; do
        case "$args" in
            "socat "*) ;;
            *) continue ;;
        esac
        case "$args" in
            *"UNIX-LISTEN:$SOCKET,"* | *"UNIX-LISTEN:$SOCKET "* | *"UNIX-LISTEN:$SOCKET") ;;
            *) continue ;;
        esac
        case " $args " in
            *" -t "*) echo "$pid 1" ;;
            *) echo "$pid 0" ;;
        esac
        return 0
    done < <(ps -eo pid=,args=)
}

remplacer() {
    local ancien="$1" nouveau i
    en_root kill "$ancien" 2>/dev/null || true
    i=0
    while [ "$i" -lt 20 ] && en_root kill -0 "$ancien" 2>/dev/null; do
        sleep 0.1
        i=$((i + 1))
    done
    en_root rm -f "$SOCKET"
    # setsid -f : socat détaché, il survit à la fin du démarrage ; -lf : son
    # journal (fichier de root) est ouvert par socat lui-même
    en_root setsid -f socat -t 86400 -lf "$JOURNAL" \
        "UNIX-LISTEN:$SOCKET,fork,mode=660,user=$UTILISATEUR,backlog=128" \
        "UNIX-CONNECT:$SOURCE" </dev/null >/dev/null 2>&1 ||
        echec "relais non relancé (socat -t 86400)"
    # PID du nouveau socat dans le fichier de la feature : docker-init.sh le
    # voit vivant et ne relance pas l'ancien relais
    i=0
    nouveau=""
    while [ "$i" -lt 20 ]; do
        nouveau="$(relais_trouve || true)"
        [ -n "$nouveau" ] && break
        sleep 0.1
        i=$((i + 1))
    done
    [ -n "$nouveau" ] || echec "relais relancé introuvable (ps)"
    printf '%s\n' "${nouveau%% *}" | en_root tee "$PID_FICHIER" >/dev/null
    echo "✔ relais Docker : socat -t 86400 (docker exec longs non coupés)"
}

trouve="$(relais_trouve || true)"
if [ -n "$trouve" ] && [ "${trouve##* }" = 0 ]; then
    remplacer "${trouve%% *}"
fi

i=0
until "$DOCKER" version >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -lt "$ATTENTE" ] || echec "le socket $SOCKET ne répond pas"
    sleep 1
done

# Contrôle : 1 s dépasse les 0,5 s de socat sans -t ; « ok » prouve que la
# sortie d'un docker exec sans entrée standard arrive en entier
sortie="$("$DOCKER" exec "$(hostname)" sh -c 'sleep 1; echo ok' </dev/null 2>&1 || true)"
[ "$sortie" = ok ] || echec "docker exec long coupé (sortie : ${sortie:-vide})"
rm -f "$MARQUE" 2>/dev/null || true
