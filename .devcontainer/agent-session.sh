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
# modèle. mkdir est atomique et présent partout (flock manque sur macOS) ; seul
# l'âge du verrou décide (#377), le pid écrit n'étant qu'un détail de
# diagnostic : un pid lu dans un autre conteneur du volume n'existe pas ici.
verrou_prendre() {
    local fin age
    fin=$(( $(date +%s) + ${DEVZONE_AGENT_VERROU_MAX:-10} ))
    while ! mkdir "$AGENT_ETAT/verrou" 2>/dev/null; do
        # Un verrou n'est orphelin que par son âge : le rang n'est tenu que
        # quelques millisecondes, 30 s ne peut être qu'un arrêt à reprendre,
        # sinon on attend puis on renonce (code 1).
        age=""
        if [ -d "$AGENT_ETAT/verrou" ]; then
            age="$(mtime "$AGENT_ETAT/verrou" 2>/dev/null)" || age=""
        fi
        if [ -n "$age" ] && [ "$(( $(date +%s) - age ))" -gt 30 ]; then
            rm -f "$AGENT_ETAT/verrou/pid"
            if rmdir "$AGENT_ETAT/verrou" 2>/dev/null; then continue; fi
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
    droits_alertes
}
