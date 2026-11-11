#!/usr/bin/env bash
# Dirige opencode sur une consigne : rotation des modèles gratuits (quota,
# filtre de contenu, modèle indisponible), silence au départ, session figée
# reprise sur une session neuve, permissions sûres. Module ia (#221).
#   devzone agent <dossier> <fichier-consigne>
#   devzone agent etat
#   devzone agent liberer [<modèle>|--tous]
# Au premier plan ; & ou nohup pour plusieurs sessions en parallèle, une par
# dossier (le journal et le rang des modèles sont partagés par instance).
set -euo pipefail

# Dossier du script, liens symboliques suivis à la main : readlink -f n'existe
# pas sur macOS (tests sous bash 3.2).
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    case "$SOURCE" in
        /*) ;;
        *) SOURCE="$DIR/$SOURCE" ;;
    esac
done
ICI="$(cd -P "$(dirname "$SOURCE")" && pwd)"
# shellcheck disable=SC2034 # lue par agent-session.sh
RACINE="${DEVZONE_RACINE:-$(dirname "$ICI")}"

# Écarts de modèles et attente du réseau (#328)
# shellcheck source=agent-erreurs.sh
# shellcheck disable=SC1091
. "$ICI/agent-erreurs.sh"
# Fichiers de droits des agents protégés (#361)
# shellcheck source=agent-droits.sh
# shellcheck disable=SC1091
. "$ICI/agent-droits.sh"
# Configuration, rang partagé, journal et état (#328)
# shellcheck source=agent-session.sh
# shellcheck disable=SC1091
. "$ICI/agent-session.sh"

# Liste de secours si « opencode models opencode » ne répond pas : même ordre
# que la configuration opencode livrée par devzone.
FREE_MODELS=(big-pickle deepseek-v4.1-flash-free glm-5.3-flash-free nemotron-3.5-super-vl-free
    nemotron-3.5-lightning-free mimo-v2.6-flash-free beam-free flint-40b-free nemotron-3-ultra-free)
SILENCE="${DEVZONE_AGENT_SILENCE:-45}"
FIGEE="${DEVZONE_AGENT_FIGEE:-600}"
AGENT_ETAT="${DEVZONE_AGENT_ETAT:-$HOME/.local/state/oc-lancer}"
# Pause entre lecture et écriture du rang (tests seulement) : active seulement
# si DEVZONE_AGENT_PAUSE_RANG est défini sous bats ; jamais de pause par défaut.
PAUSE_RANG=0
if [ -n "${DEVZONE_AGENT_PAUSE_RANG:-}" ] && [ -n "${BATS_TEST_TMPDIR:-}" ]; then PAUSE_RANG="$DEVZONE_AGENT_PAUSE_RANG"; fi
# Relances d'une même session pour cause réseau, par modèle, avant le modèle suivant
RELANCES_RESEAU=3

refuse() { echo "devzone agent : $*" >&2; exit 2; }

agent_lancer() {
    local dossier="$1" consigne="$2"
    local journal etat debut m i pid code offset taille demarre freeze discard nouveau
    local consigne_courante repris=0 maintenant dernier sortie cause
    local reseau_pour="" reseau_n=0
    # Chemins relatifs au dossier d'appel : rendus absolus avant tout cd, verrou ou
    # écriture d'état ; le nom de la consigne est conservé.
    [ -d "$dossier" ] || refuse "dossier introuvable : $dossier (cherché depuis $(pwd))"
    [ -r "$consigne" ] || refuse "consigne introuvable : $consigne (cherché depuis $(pwd))"
    dossier="$(cd "$dossier" && pwd -P)"
    consigne="$(cd "$(dirname "$consigne")" && pwd -P)/$(basename "$consigne")"
    # Module ia requis : sans assistants, rien à diriger.
    if ! bash "$ICI/devzone" actif ia >/dev/null 2>&1; then
        refuse "module ia désactivé : devzone activer ia"
    fi
    configurer
    journal="$(journal_de "$dossier")"
    export AGENT_JOURNAL="$journal"
    etat="$AGENT_ETAT"
    mkdir -p "$(dirname "$journal")" "$etat"
    droits_photo "$dossier"
    FREE_MODELS=()
    while IFS= read -r m; do
        if [ -n "$m" ]; then FREE_MODELS+=("$m"); fi
    done < <(liste_modeles)
    [ "${#FREE_MODELS[@]}" -gt 0 ] || refuse "aucun modèle gratuit disponible"
    verrou_prendre || refuse "rang des modèles verrouillé : réessayer"
    debut=$(( $(cat "$etat/rang" 2>/dev/null || echo 0) % ${#FREE_MODELS[@]} ))
    if [ "$PAUSE_RANG" -gt 0 ]; then sleep "$PAUSE_RANG"; fi
    echo $(( debut + 1 )) >"$etat/rang"
    verrou_lacher
    echo "=== rang $(( debut + 1 ))/${#FREE_MODELS[@]}" >>"$journal"

    consigne_courante="$consigne"
    # Reprise : une session neuve repart du travail déjà présent (git status,
    # diff, log), sans historique de conversation.
    reprise() {
        if [ "$repris" = 1 ]; then return 0; fi
        repris=1
        local c
        c="$(mktemp)"
        cat "$consigne_courante" >"$c"
        printf '\n\nREPRISE : une session précédente a été interrompue. Lis git status, git diff et git log dans le dossier, vérifie ce travail contre la consigne ci-dessus, corrige ce qui s en écarte et termine ce qui manque.\n' >>"$c"
        consigne_courante="$c"
    }

    i=0
    while [ "$i" -lt "${#FREE_MODELS[@]}" ]; do
        m="${FREE_MODELS[$(( (debut + i) % ${#FREE_MODELS[@]} ))]}"
        if [ "$m" != "$reseau_pour" ]; then reseau_pour="$m"; reseau_n=0; fi
        if modele_ecarte "$m"; then
            i=$(( i + 1 ))
            continue
        fi
        echo "=== modèle opencode/$m début $(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$journal"
        offset="$(wc -c <"$journal")"
        (cd "$dossier" && DEVZONE_AGENT_SESSION=1 opencode run --print-logs --log-level ERROR --auto -m "opencode/$m" "$(cat "$consigne_courante")" </dev/null >>"$journal" 2>&1) &
        pid=$!
        demarre=0
        discard=0
        local debut_t
        debut_t="$(date +%s)"
        while kill -0 "$pid" 2>/dev/null; do
            if session_erreur_fatale "$pid" "$journal" "$offset" "$m" "$dossier"; then discard=1; break; fi
            if [ "$(wc -c <"$journal")" -gt "$offset" ]; then
                nouveau="$(tail -c "+$(( offset + 1 ))" "$journal" 2>/dev/null || true)"
                if [ "$(erreur_cause "$(lignes_erreur "$nouveau")")" != "quota" ]; then demarre=1; break; fi
            fi
            if [ $(( $(date +%s) - debut_t )) -ge "$SILENCE" ]; then break; fi
            sleep "${DEVZONE_AGENT_PAS:-1}"
        done
        if [ "$discard" = 1 ]; then reprise; i=$(( i + 1 )); continue; fi
        if kill -0 "$pid" 2>/dev/null && [ "$demarre" = 0 ]; then
            pkill -P "$pid" 2>/dev/null || true
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            droits_verifier "$dossier"
            echo "=== opencode/$m muet au départ : écarté 1 h, modèle suivant" >>"$journal"
            modele_ecarter "$m" mute
            reprise
            i=$(( i + 1 ))
            continue
        fi
        # Session figée : plus rien écrit depuis FIGEE secondes en cours de
        # route → arrêtée, puis session neuve avec la consigne de reprise.
        freeze=0
        if kill -0 "$pid" 2>/dev/null && [ "$demarre" = 1 ]; then
            dernier="$(date +%s)"
            taille="$(wc -c <"$journal")"
            while kill -0 "$pid" 2>/dev/null; do
                if session_erreur_fatale "$pid" "$journal" "$offset" "$m" "$dossier"; then discard=1; break; fi
                sleep "${DEVZONE_AGENT_PAS:-1}"
                maintenant="$(date +%s)"
                if [ "$(wc -c <"$journal")" -gt "$taille" ]; then
                    taille="$(wc -c <"$journal")"
                    dernier="$maintenant"
                fi
                if [ $(( maintenant - dernier )) -gt "$FIGEE" ]; then
                    pkill -P "$pid" 2>/dev/null || true
                    kill "$pid" 2>/dev/null || true
                    wait "$pid" 2>/dev/null || true
                    droits_verifier "$dossier"
                    freeze=1
                    break
                fi
            done
        fi
        if [ "$discard" = 1 ]; then reprise; i=$(( i + 1 )); continue; fi
        if [ "$freeze" = 1 ]; then
            echo "=== opencode/$m figé ($FIGEE s sans écrire) : session neuve, modèle suivant" >>"$journal"
            reprise
            i=$(( i + 1 ))
            continue
        fi
        code=0
        wait "$pid" || code=$?
        droits_verifier "$dossier"
        # Seule la sortie de cette tentative compte : une erreur d'un modèle
        # précédent ne doit pas condamner le suivant. On ne lit que ses 30
        # dernières lignes, et seulement si le code de sortie est non nul ou si
        # opencode a écrit sa propre ligne d'erreur : du code affiché contenant
        # « Free usage limit » qui finit normalement n'est pas un échec.
        sortie="$(tail -c "+$(( offset + 1 ))" "$journal" 2>/dev/null || true)"
        recent="$(printf '%s\n' "$sortie" | tail -n 30)"
        if [ "$code" -ne 0 ] || printf '%s\n' "$recent" | grep -qE "$LIGNE_ERREUR"; then
            if printf '%s\n' "$recent" | grep -qE "$ERREURS"; then
                cause="$(erreur_cause "$(printf '%s\n' "$recent" | grep -oE "$ERREURS" | tail -1)")"
                # Une erreur « réseau » n'est retenue que si le réseau est coupé
                # maintenant : sinon elle se répéterait sans fin sur un réseau bon.
                if [ "$cause" = reseau ] && reseau_joignable; then
                    echo "=== erreur réseau signalée mais réseau joignable : traité comme autre" >>"$journal"
                    cause=autre
                fi
                if [ "$cause" = reseau ] && [ "$reseau_n" -ge "$RELANCES_RESEAU" ]; then
                    echo "=== opencode/$m réseau coupé $RELANCES_RESEAU fois : modèle suivant, sans écart" >>"$journal"
                    cause=autre
                fi
                if [ "$cause" = reseau ]; then
                    if reseau_attendre; then
                        reseau_n=$(( reseau_n + 1 ))
                        reprise
                        continue
                    fi
                    echo "=== réseau indisponible" >>"$journal"
                    exit 4
                fi
                if [ "$cause" = autre ]; then
                    echo "=== opencode/$m erreur, sans écart : modèle suivant" >>"$journal"
                else
                    modele_ecarter "$m" "$cause"
                    echo "=== opencode/$m écarté ($cause, $(ecart_libelle "$cause")) : modèle suivant" >>"$journal"
                fi
                reprise
                i=$(( i + 1 ))
                continue
            fi
        fi
        if [ "$code" -ne 0 ]; then
            echo "=== opencode/$m arrêté en erreur (code $code) : modèle suivant" >>"$journal"
            reprise
            i=$(( i + 1 ))
            continue
        fi
        echo "=== fin avec opencode/$m (code $code)" >>"$journal"
        exit "$code"
    done
    echo "=== aucun modèle gratuit disponible" >>"$journal"
    exit 3
}

agent_aide() {
    cat <<'AGENTEOF2'
usage : devzone agent <dossier> <fichier-consigne>
        lance opencode sur la consigne, modèles gratuits en rotation
        devzone agent etat
        sessions connues et modèles écartés
        devzone agent liberer [<modèle>|--tous]
        lève un écart de modèle
AGENTEOF2
}

case "${1:-}" in
    etat) if [ "${2:-}" = "--json" ]; then exec bash "$ICI/agent-etat-json.sh"; else agent_etat; fi ;;
    liberer)
        [ -n "${2:-}" ] || { agent_aide >&2; exit 2; }
        ecart_liberer "$2"
        ;;
    -h | --help | aide) agent_aide ;;
    "")
        agent_aide
        exit 2
        ;;
    *)
        if [ "$#" -lt 2 ]; then
            agent_aide >&2
            exit 2
        fi
        agent_lancer "$1" "$2"
        ;;
esac
