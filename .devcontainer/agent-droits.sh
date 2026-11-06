#!/usr/bin/env bash
# Protège les fichiers de droits des agents pendant une session devzone agent (#361).
# Bibliothèque sourcée par agent.sh : aucune commande n'est lancée ici.

# Fichiers de droits, chemins relatifs à la racine du dossier de travail. Liste
# fixe : aucune variable d'environnement ne la change, un agent peut en poser.
# agent-droits.sh y figure, sinon un agent pourrait vider la liste.
DROITS_AGENT=(
    .devcontainer/opencode/agent.json
    .devcontainer/opencode.jsonc
    .repowarden.conf
    .devcontainer/agent-droits.sh
)

# Dossier de la photo des droits d'un projet, dans l'état de l'agent.
droits_dossier() {
    echo "$AGENT_ETAT/droits-$(basename "$1")"
}

# Au lancement : copie chaque fichier de droits (ou note son absence) et le HEAD de
# départ, puis efface l'alerte de la session précédente sur ce projet.
droits_photo() {
    local d f
    d="$(droits_dossier "$1")"
    rm -rf "$d" "$d.alerte"
    mkdir -p "$d/fichiers"
    : >"$d/absents"
    for f in "${DROITS_AGENT[@]}"; do
        if [ -f "$1/$f" ]; then
            mkdir -p "$d/fichiers/$(dirname "$f")"
            cp -p "$1/$f" "$d/fichiers/$f"
        else
            echo "$f" >>"$d/absents"
        fi
    done
    git -C "$1" rev-parse HEAD >"$d/head" 2>/dev/null || : >"$d/head"
}

# Remet un fichier de droits à l'identique de sa photo (supprimé s'il n'existait pas).
droits_remettre() {
    local d f
    d="$(droits_dossier "$1")"
    f="$2"
    if grep -qxF "$f" "$d/absents"; then
        rm -f "$1/$f"
    else
        mkdir -p "$(dirname "$1/$f")"
        cp -p "$d/fichiers/$f" "$1/$f"
    fi
}

# Après chaque session opencode : remet les fichiers modifiés dans l'arbre, signale
# dans le journal tout commit qui les touche (historique jamais réécrit), pose l'alerte.
droits_verifier() {
    local d f depart sha message
    d="$(droits_dossier "$1")"
    [ -d "$d" ] || return 0
    depart="$(cat "$d/head" 2>/dev/null || true)"
    for f in "${DROITS_AGENT[@]}"; do
        message=""
        if grep -qxF "$f" "$d/absents"; then
            if [ -e "$1/$f" ]; then message="changement annulé"; fi
        elif ! cmp -s "$d/fichiers/$f" "$1/$f"; then
            message="changement annulé"
        fi
        sha=""
        if [ -n "$depart" ]; then
            if [ -n "$(git -C "$1" diff --name-only "$depart" HEAD -- "$f" 2>/dev/null)" ]; then
                sha="$(git -C "$1" log -1 --format=%h "$depart..HEAD" -- "$f" 2>/dev/null || true)"
                message="changement annulé dans l'arbre, commité dans ${sha:-HEAD} : retirer ce commit avant tout push"
            fi
        fi
        [ -n "$message" ] || continue
        droits_remettre "$1" "$f"
        echo "=== ⚠ droits modifiés : $f : $message" >>"$AGENT_JOURNAL"
        echo "$f" >>"$d.alerte"
    done
    return 0
}

# Pour devzone agent etat : une ligne par projet dont les droits ont été modifiés.
droits_alertes() {
    local f
    for f in "$AGENT_ETAT"/droits-*.alerte; do
        [ -e "$f" ] || continue
        f="${f##*/droits-}"
        echo "  ⚠ droits modifiés (${f%.alerte}) : voir le journal"
    done
}
