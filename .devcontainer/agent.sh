#!/usr/bin/env bash
# Dirige opencode sur une consigne : rotation des modèles gratuits (quota,
# filtre de contenu, modèle indisponible), silence au départ, session figée
# reprise sur une session neuve, permissions sûres. Module ia (#221).
#   devzone agent <dossier> <fichier-consigne>
#   devzone agent etat
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
RACINE="${DEVZONE_RACINE:-$(dirname "$ICI")}"

# Liste de secours si « opencode models opencode » ne répond pas : même ordre
# que la configuration opencode livrée par devzone.
FREE_MODELS=(big-pickle deepseek-v4.1-flash-free glm-5.3-flash-free nemotron-3.5-super-vl-free
    nemotron-3.5-lightning-free mimo-v2.6-flash-free beam-free flint-40b-free nemotron-3-ultra-free)
ERREURS='Free usage limit|content filter|Model is unavailable|Upstream request failed|ProviderHeaderTimeout|ENOTFOUND'
# Ligne d'erreur écrite par opencode lui-même : seule une sortie qui la porte
# (ou un code de sortie non nul) peut être un échec, pas du code affiché.
LIGNE_ERREUR='(^|[[:space:]])(Error|ERROR|Erreur):'
SILENCE="${DEVZONE_AGENT_SILENCE:-45}"
FIGEE="${DEVZONE_AGENT_FIGEE:-600}"
AGENT_ETAT="${DEVZONE_AGENT_ETAT:-$HOME/.local/state/oc-lancer}"

refuse() { echo "devzone agent : $*" >&2; exit 2; }

# Configuration sûre : agent.json par défaut, complétée par
# OPENCODE_CONFIG_CONTENT s'il est défini. opencode applique la dernière règle
# qui correspond : les deny de devzone sont donc retirés de la fusion puis
# ré-ajoutés à la fin (l'ordre des clés d'un objet jq est l'ordre d'insertion),
# si bien que l'appelant peut ajouter des permissions, jamais retirer un interdit
# de devzone. ~/bash32 est toujours protégé : le bash 3.2 du conteneur a déjà
# été remplacé par un lien (#210).
configurer() {
    local def config
    def="$ICI/opencode/agent.json"
    [ -r "$def" ] || refuse "configuration par défaut absente : $def"
    if [ -n "${OPENCODE_CONFIG_CONTENT:-}" ]; then
        config="$(jq -ce -s '
            .[0] as $def | .[1] as $env |
            ($def.permission.bash // {}) as $bashdef |
            ($env.permission.bash // {}) as $bashenv |
            ([ $bashdef | to_entries[] | select(.value == "deny") | .key ]) as $deny |
            (($def * $env)
             | .permission.bash = (($bashdef + $bashenv) | delpaths($deny | map([.])))
             | reduce $deny[] as $k (. ; .permission.bash[$k] = "deny"))
        ' "$def" <(printf '%s' "$OPENCODE_CONFIG_CONTENT"))" ||
            refuse "configuration opencode illisible : rien lancé"
    else
        config="$(jq -ce . "$def")" || refuse "configuration opencode illisible : rien lancé"
    fi
    config="$(jq -ce '.permission.bash = ((.permission.bash // {}) + {
        "git commit*": "allow",
        "ln *bash32*": "deny",
        "cp *bash32*": "deny",
        "mv *bash32*": "deny",
        "rm *bash32*": "deny",
        "chmod *bash32*": "deny",
        "install *bash32*": "deny"
    })' <<<"$config")" || refuse "configuration opencode illisible : rien lancé"
    grep -q '"git push\*":"deny"' <<<"$config" || refuse "git push non interdit : rien lancé"
    export OPENCODE_CONFIG_CONTENT="$config"
}

# Modèles gratuits de la version installée, préfixe « opencode/ » retiré :
# « opencode models opencode » peut rendre « opencode/big-pickle ».
liste_modeles() {
    local l
    l="$(opencode models opencode 2>/dev/null | sed 's#^opencode/##' |
        grep -E '(-free$|^big-pickle$)' | awk 'NF && !vu[$0]++' || true)"
    if [ -n "$l" ]; then
        printf '%s\n' "$l"
    else
        printf '%s\n' "${FREE_MODELS[@]}"
    fi
}

journal_de() {
    echo "$RACINE/workspace/.agents/$(basename "$1").log"
}

# Époque de dernière écriture, GNU (stat -c) ou BSD/macOS (stat -f).
mtime() {
    if stat -c %Y "$1" >/dev/null 2>&1; then
        stat -c %Y "$1"
    else
        stat -f %m "$1"
    fi
}

heure() {
    if date -u -d "@$1" '+%Y-%m-%d %H:%M:%S' >/dev/null 2>&1; then
        date -u -d "@$1" '+%Y-%m-%d %H:%M:%S'
    else
        date -u -r "$1" '+%Y-%m-%d %H:%M:%S'
    fi
}

# Rang partagé : deux lancements simultanés ne doivent pas partir sur le même
# modèle. mkdir est atomique et présent partout (flock manque sur macOS) ;
# le pid permet de retirer un verrou laissé par un processus tué.
verrou_prendre() {
    local fin p
    fin=$(( $(date +%s) + 10 ))
    while ! mkdir "$AGENT_ETAT/verrou" 2>/dev/null; do
        if [ -f "$AGENT_ETAT/verrou/pid" ]; then
            p="$(cat "$AGENT_ETAT/verrou/pid" 2>/dev/null || true)"
            if [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null; then
                rm -f "$AGENT_ETAT/verrou/pid"
                rmdir "$AGENT_ETAT/verrou" 2>/dev/null || true
                continue
            fi
        fi
        if [ "$(date +%s)" -ge "$fin" ]; then return 1; fi
        sleep 1
    done
    echo "$$" >"$AGENT_ETAT/verrou/pid"
}

verrou_lacher() {
    rm -f "$AGENT_ETAT/verrou/pid"
    rmdir "$AGENT_ETAT/verrou" 2>/dev/null || true
}

agent_lancer() {
    local dossier="$1" consigne="$2"
    local journal etat debut m i pid code offset taille demarre freeze
    local consigne_courante repris=0 maintenant dernier sortie
    [ -d "$dossier" ] || refuse "dossier introuvable : $dossier"
    [ -r "$consigne" ] || refuse "consigne illisible : $consigne"
    configurer
    journal="$(journal_de "$dossier")"
    etat="$AGENT_ETAT"
    mkdir -p "$(dirname "$journal")" "$etat"
    FREE_MODELS=()
    while IFS= read -r m; do
        if [ -n "$m" ]; then FREE_MODELS+=("$m"); fi
    done < <(liste_modeles)
    [ "${#FREE_MODELS[@]}" -gt 0 ] || refuse "aucun modèle gratuit disponible"
    verrou_prendre || refuse "rang des modèles verrouillé : réessayer"
    debut=$(( $(cat "$etat/rang" 2>/dev/null || echo 0) % ${#FREE_MODELS[@]} ))
    echo $(( debut + 1 )) >"$etat/rang"
    verrou_lacher

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

    for i in $(seq 0 $(( ${#FREE_MODELS[@]} - 1 ))); do
        m="${FREE_MODELS[$(( (debut + i) % ${#FREE_MODELS[@]} ))]}"
        if [ -f "$etat/muet-$m" ] && [ $(( $(date +%s) - $(cat "$etat/muet-$m") )) -lt 3600 ]; then
            continue
        fi
        echo "=== modèle opencode/$m début $(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$journal"
        offset="$(wc -c <"$journal")"
        (cd "$dossier" && opencode run --auto -m "opencode/$m" "$(cat "$consigne_courante")" </dev/null >>"$journal" 2>&1) &
        pid=$!
        demarre=0
        # Silence au départ : rien écrit pendant SILENCE secondes alors que le
        # processus vit encore (quota : opencode réessaie sans rien dire).
        local debut_t
        debut_t="$(date +%s)"
        while kill -0 "$pid" 2>/dev/null; do
            if [ "$(wc -c <"$journal")" -gt "$offset" ]; then demarre=1; break; fi
            if [ $(( $(date +%s) - debut_t )) -ge "$SILENCE" ]; then break; fi
            sleep 1
        done
        if kill -0 "$pid" 2>/dev/null && [ "$demarre" = 0 ]; then
            pkill -P "$pid" 2>/dev/null || true
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            echo "=== opencode/$m muet au départ : écarté 1 h, modèle suivant" >>"$journal"
            date +%s >"$etat/muet-$m"
            reprise
            continue
        fi
        # Session figée : plus rien écrit depuis FIGEE secondes en cours de
        # route → arrêtée, puis session neuve avec la consigne de reprise.
        freeze=0
        if kill -0 "$pid" 2>/dev/null && [ "$demarre" = 1 ]; then
            dernier="$(date +%s)"
            taille="$(wc -c <"$journal")"
            while kill -0 "$pid" 2>/dev/null; do
                sleep 1
                maintenant="$(date +%s)"
                if [ "$(wc -c <"$journal")" -gt "$taille" ]; then
                    taille="$(wc -c <"$journal")"
                    dernier="$maintenant"
                fi
                if [ $(( maintenant - dernier )) -gt "$FIGEE" ]; then
                    pkill -P "$pid" 2>/dev/null || true
                    kill "$pid" 2>/dev/null || true
                    wait "$pid" 2>/dev/null || true
                    freeze=1
                    break
                fi
            done
        fi
        if [ "$freeze" = 1 ]; then
            echo "=== opencode/$m figé ($FIGEE s sans écrire) : session neuve, modèle suivant" >>"$journal"
            reprise
            continue
        fi
        code=0
        wait "$pid" || code=$?
        # Seule la sortie de cette tentative compte : une erreur d'un modèle
        # précédent ne doit pas condamner le suivant. On ne lit que ses 30
        # dernières lignes, et seulement si le code de sortie est non nul ou si
        # opencode a écrit sa propre ligne d'erreur : du code affiché contenant
        # « Free usage limit » qui finit normalement n'est pas un échec.
        sortie="$(tail -c "+$(( offset + 1 ))" "$journal" 2>/dev/null || true)"
        recent="$(printf '%s\n' "$sortie" | tail -n 30)"
        if [ "$code" -ne 0 ] || printf '%s\n' "$recent" | grep -qE "$LIGNE_ERREUR"; then
            if printf '%s\n' "$recent" | grep -qE "$ERREURS"; then
                echo "=== opencode/$m refusé ($(printf '%s\n' "$recent" | grep -oE "$ERREURS" | tail -1)) : modèle suivant" >>"$journal"
                reprise
                continue
            fi
        fi
        if [ "$code" -ne 0 ]; then
            echo "=== opencode/$m arrêté en erreur (code $code) : modèle suivant" >>"$journal"
            reprise
            continue
        fi
        echo "=== fin avec opencode/$m (code $code)" >>"$journal"
        exit "$code"
    done
    echo "=== aucun modèle gratuit disponible" >>"$journal"
    exit 3
}

# Sessions connues (journal, dernier modèle, début, dernier écrit) et modèles
# écartés par le superviseur, avec l'heure de fin d'écart.
agent_etat() {
    local f m debut dernier e vu=0
    echo "devzone agent : état"
    for f in "$RACINE"/workspace/.agents/*.log; do
        [ -e "$f" ] || continue
        vu=1
        m="$(grep -oE 'opencode/[A-Za-z0-9._-]+' "$f" 2>/dev/null | tail -1 || true)"
        debut="$(grep '^=== modèle ' "$f" 2>/dev/null | tail -1 |
            sed -E 's/.* début ([^ ]+).*/\1/' || true)"
        dernier="$(heure "$(mtime "$f")")"
        echo "  session $(basename "$f") : modèle ${m:-inconnu}, depuis ${debut:-inconnu}, dernier écrit $dernier"
    done
    [ "$vu" = 1 ] || echo "  aucune session"
    for f in "$AGENT_ETAT"/muet-*; do
        [ -e "$f" ] || continue
        m="${f##*/muet-}"
        e="$(cat "$f" 2>/dev/null || true)"
        echo "  modèle $m écarté jusqu'à $(heure "${e:-0}")"
    done
}

agent_aide() {
    cat <<'AGENTEOF2'
usage : devzone agent <dossier> <fichier-consigne>
        lance opencode sur la consigne, modèles gratuits en rotation
        devzone agent etat
        sessions connues et modèles écartés
AGENTEOF2
}

case "${1:-}" in
    etat) agent_etat ;;
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
