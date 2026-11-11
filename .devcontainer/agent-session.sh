#!/usr/bin/env bash
# Session du superviseur d'agent : configuration opencode, rang partagé, journal,
# état (#328). Bibliothèque sourcée par agent.sh : aucune commande n'est lancée ici.

# Chemin du journal d'un dossier dans workspace/.agents/ : hors dépôt, ignoré par git.
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

# Date UTC lisible d'une époque, GNU puis BSD date : affichée par devzone agent etat.
heure() {
    if date -u -d "@$1" '+%Y-%m-%d %H:%M:%S' >/dev/null 2>&1; then
        date -u -d "@$1" '+%Y-%m-%d %H:%M:%S'
    else
        date -u -r "$1" '+%Y-%m-%d %H:%M:%S'
    fi
}

# Trace de verrou dans le journal de l'agent ($AGENT_JOURNAL, défini par
# agent.sh) : une ligne à la prise et une au rendu, avec l'horloge et le pid,
# pour le diagnostic des lancements simultanés du rang en CI (#421). Sans
# journal, rien n'est écrit. Une mention optionnelle (second argument) précise
# le chemin, l'âge ou le pid lu.
verrou_tracer() {
    local d
    [ -n "${AGENT_JOURNAL:-}" ] || return 0
    d="$(date +%s.%N 2>/dev/null)" || d=""
    case "$d" in "" | *N*) d="$(date +%s)" ;; esac
    echo "=== verrou $1 $d pid $$${2:+ $2}" >>"$AGENT_JOURNAL"
}

# Rang partagé : deux lancements simultanés ne doivent pas partir sur le même
# modèle. mkdir est atomique et présent partout (flock manque sur macOS) ; seul
# l'âge du verrou décide (#377), le pid écrit n'étant qu'un détail de
# diagnostic : un pid lu dans un autre conteneur du volume n'existe pas ici.
# Quand flock existe, la section rang est en outre prise sous son verrou sur
# rang.lock (#421) : si deux mkdir réussissaient, flock sérialise quand même
# la lecture et l'écriture du rang. Chaque branche est tracée (échec mkdir,
# purge, prise) pour établir en CI lequel des deux lancements a réussi mkdir.
verrou_prendre() {
    local fin age vpid
    fin=$(( $(date +%s) + ${DEVZONE_AGENT_VERROU_MAX:-10} ))
    while ! mkdir "$AGENT_ETAT/verrou" 2>/dev/null; do
        # Un verrou n'est orphelin que par son âge : le rang n'est tenu que
        # quelques millisecondes, 30 s ne peut être qu'un arrêt à reprendre,
        # sinon on attend puis on renonce (code 1).
        age=""
        if [ -d "$AGENT_ETAT/verrou" ]; then
            age="$(mtime "$AGENT_ETAT/verrou" 2>/dev/null)" || age=""
        fi
        vpid="$(cat "$AGENT_ETAT/verrou/pid" 2>/dev/null)" || vpid=""
        verrou_tracer "échec mkdir" "age=${age:-inconnue} pid-verrou=${vpid:-aucun}"
        if [ -n "$age" ] && [ "$(( $(date +%s) - age ))" -gt 30 ]; then
            rm -f "$AGENT_ETAT/verrou/pid"
            if rmdir "$AGENT_ETAT/verrou" 2>/dev/null; then
                verrou_tracer "purgé" "age=$age"
                continue
            fi
        fi
        if [ "$(date +%s)" -ge "$fin" ]; then return 1; fi
        sleep 1
    done
    # pid avant flock : l'autre agent ne retire jamais le dossier pendant notre
    # attente sur rang.lock, sinon notre écriture de pid tomberait sur ENOENT.
    echo "$$" >"$AGENT_ETAT/verrou/pid"
    if command -v flock >/dev/null 2>&1; then
        # exec dans un if conditionne l'échec au lieu de tuer le shell (bash
        # 3.2 comme GNU) ; sans flock, mkdir reste le seul garde-fou (macOS).
        if { exec 9>"$AGENT_ETAT/rang.lock"; } && flock -w "${DEVZONE_AGENT_VERROU_MAX:-10}" 9; then
            AGENT_VERROU_FLOCK=1
        else
            verrou_lacher
            return 1
        fi
    fi
    verrou_tracer pris "chemin=$AGENT_ETAT/verrou"
}

# Libère le rang partagé pris par verrou_prendre : retire le pid, puis le dossier,
# mais seulement si ce verrou appartient à l'agent appelant (pid du fichier == $$).
# Un verrou détenu par un autre agent n'est jamais supprimé ici. flock (#421)
# est libéré dans tous les cas, même si le pid lu ne correspond pas : sinon le
# prochain appelant resterait bloqué sur rang.lock.
verrou_lacher() {
    local pid
    pid="$(cat "$AGENT_ETAT/verrou/pid" 2>/dev/null)" || pid=""
    if [ "$pid" = "$$" ]; then
        rm -f "$AGENT_ETAT/verrou/pid"
        rmdir "$AGENT_ETAT/verrou" 2>/dev/null || true
        verrou_tracer rendu
    fi
    if [ "${AGENT_VERROU_FLOCK:-0}" = 1 ]; then
        flock -u 9 2>/dev/null || true
        exec 9>&-
        AGENT_VERROU_FLOCK=0
    fi
}

# Passe permission.edit en objet et ajoute en dernier un deny par fichier de droits
# (#361) : la dernière règle qui correspond l'emporte, l'appelant ne peut pas le retirer.
droits_edit_deny() {
    local motifs f
    motifs="[]"
    for f in "${DROITS_AGENT[@]}"; do
        motifs="$(jq -c --arg f "$f" '. + [$f, "**/" + $f]' <<<"$motifs")"
    done
    jq -ce --argjson m "$motifs" '
        (.permission.edit // "allow") as $e |
        (if ($e | type) == "object" then $e else {"*": $e} end) as $o |
        .permission.edit = (reduce $m[] as $k ($o; del(.[$k])) + ($m | map({(.): "deny"}) | add))
    ' <<<"$1"
}

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
    config="$(droits_edit_deny "$config")" || refuse "configuration opencode illisible : rien lancé"
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

# Modèle et début d'une session (#308) : lus uniquement sur la dernière ligne
# « === modèle opencode/? début » du superviseur ; le texte écrit par le
# modèle dans le journal (un « opencode/agent.json » possible) n'est pas lu.
session_modele_debut() {
    local ligne
    ligne="$(grep '^=== modèle opencode/' "$1" 2>/dev/null | tail -1 || true)"
    MODELE_SESSION="$(sed -nE 's/^=== modèle opencode\/([^ ]+) début .*/\1/p' <<<"$ligne")"
    DEBUT_SESSION="$(sed -nE 's/.* début ([^ ]+).*/\1/p' <<<"$ligne")"
}

# Une session est en cours (#308) si un processus agent.sh vivant a pour
# premier argument (le dossier, absolu depuis #287) un chemin dont le nom est
# exactement le journal sans « .log » ; un simple dossier contenant ce nom ne
# suffit pas, ni un chemin qui ne serait pas le dossier d'un agent.
session_en_cours() {
    local ligne dossier
    while IFS= read -r ligne; do
        case "$ligne" in
            *agent.sh\ *) dossier="${ligne#*agent.sh }" ;;
            *) continue ;;
        esac
        dossier="${dossier%% *}"
        [ -n "$dossier" ] || continue
        if [ "$(basename "$dossier")" = "$1" ]; then return 0; fi
    done < <(ps -eo args= 2>/dev/null || true)
    return 1
}

# Sessions connues (journal, dernier modèle, début, dernier écrit) et modèles
# écartés par le superviseur, avec l'heure de fin d'écart.
agent_etat() {
    local f m debut dernier vu=0
    echo "devzone agent : état"
    for f in "$RACINE"/workspace/.agents/*.log; do
        [ -e "$f" ] || continue
        vu=1
        session_modele_debut "$f"
        m="${MODELE_SESSION:+opencode/$MODELE_SESSION}"
        debut="$DEBUT_SESSION"
        dernier="$(heure "$(mtime "$f")")"
        echo "  session $(basename "$f") : modèle ${m:-inconnu}, depuis ${debut:-inconnu}, dernier écrit $dernier"
    done
    [ "$vu" = 1 ] || echo "  aucune session"
    agent_ecarts
    droits_alertes
}
