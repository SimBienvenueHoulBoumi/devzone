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

# Libère le rang partagé pris par verrou_prendre : retire le pid, puis le dossier.
verrou_lacher() {
    rm -f "$AGENT_ETAT/verrou/pid"
    rmdir "$AGENT_ETAT/verrou" 2>/dev/null || true
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

# Sessions connues (journal, dernier modèle, début, dernier écrit) et modèles
# écartés par le superviseur, avec l'heure de fin d'écart.
agent_etat() {
    local f m debut dernier vu=0
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
    agent_ecarts
}
