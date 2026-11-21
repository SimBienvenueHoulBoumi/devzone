#!/usr/bin/env bash
# shellcheck shell=bash
# devzone, repair of the workstation.
# Sourced by .devcontainer/devzone (split of the 1 600 lines file, #722):
# functions only, shared variables are defined in devzone.

# Lignes « paquet figée installée » des outils en retard ; échoue si le script
# versions.sh est absent ou ne peut pas répondre (l'état omet alors la ligne)
outils_retard() {
    [ -f "$VERSIONS" ] || return 1
    bash "$VERSIONS" --installees 2>/dev/null
}

# Remet repowarden à la version figée s'il en diffère, comme post-create.sh
# (il installe les hooks git globaux)
appliquer_repowarden() {
    local ligne figee installee paquet=repowarden
    [ -f "$VERSIONS" ] || return 0
    ligne="$(bash "$VERSIONS" --installees 2>/dev/null | awk '$1 == "repowarden"' || true)"
    [ -n "$ligne" ] || return 0
    read -r _ figee installee <<<"$ligne"
    echo "devzone : installation de repowarden ${figee}…"
    npm install -g "$paquet@$figee" >/dev/null
    repowarden install --global --lang fr
    echo "devzone : repowarden $installee → $figee"
}

# Chemins des worktrees du dépôt devzone et des dépôts du workspace absents
# ici : créés de l'autre côté (hôte), un git worktree prune les casserait.
# Lecture seule : rien n'est supprimé ni réparé.
worktrees_absents() {
    local depot ligne chemin
    {
        [ -e "$RACINE/.git" ] && echo "$RACINE"
        find "$RACINE/workspace" -mindepth 2 -maxdepth 3 -name .git -type d 2>/dev/null | sed 's|/\.git$||'
    } | while IFS= read -r depot; do
        { git -C "$depot" worktree list --porcelain 2>/dev/null || true; } | while IFS= read -r ligne; do
            case "$ligne" in
                "worktree "*)
                    chemin="${ligne#worktree }"
                    [ -d "$chemin" ] || echo "$chemin"
                    ;;
            esac
        done
    done || true
}

# Réparation (#341) : reprend la suite de startup.sh sans l'identité git ni
# les clusters. Chaque élément est réparé pour de vrai ; ✔ ou ✖ avec la raison.
reparer_element() {
    local nom="$1" sortie code raison
    shift
    if sortie="$("$@" 2>&1)"; then
        echo "✔ $nom"
    else
        code=$?
        raison="$(printf '%s\n' "$sortie" | sed '/^[[:space:]]*$/d' | tail -1)"
        [ -n "$raison" ] || raison="échec (code $code)"
        echo "✖ $nom : $raison"
        reparer_echec=1
    fi
}

# Réparations de l'application (#341) : relais Docker, services actifs, ports
# et identifiants ; un échec n'empêche pas les suivants.
reparer() {
    reparer_echec=0
    reparer_element "relais Docker" env DEVZONE_RELAIS_REEL=oui bash "$ICI/docker-relay.sh"
    # Jeton du compte Kubernetes limité (#430) : 24 h, renouvelé ici ; sans
    # module kubernetes et sans cluster des services, rien à faire
    if [ "$(valeur kubernetes)" = on ] || [ -n "$(cluster_saved)" ]; then
        reparer_element "compte kubernetes" bash "$ICI/kube-account.sh" jeton
    fi
    if [ "$(valeur gitlab)" = on ]; then
        reparer_element "nom gitlab" bash "$ICI/gitlab/gitlab.sh" hote-poser
        reparer_element "relais gitlab" bash "$ICI/gitlab/gitlab.sh" relay-start
    fi
    if [ "$(valeur postgres)" = on ]; then
        reparer_element "relais postgres" bash "$ICI/postgres/postgres.sh" relay-start
    fi
    if [ "$(valeur argocd)" = on ]; then
        reparer_element "relais argocd" bash "$ICI/argocd/argocd.sh" relay-start
    fi
    if [ "$(valeur mysql)" = on ]; then
        reparer_element "relais mysql" bash "$ICI/catalog/mysql/mysql.sh" relay-start
    fi
    reparer_element "relais de ports" bash "$ICI/ports.sh" restart
    # Kubernetes workspace (#517): no automatic port watcher
    if ! dans_pod; then
        reparer_element "veilleur ports auto" env DEVZONE_PORTS_AUTO_REEL=oui bash "$ICI/ports-auto.sh" demarrer
    fi
    reparer_element "veilleur catalogue" env DEVZONE_CATALOGUE_REEL=oui bash "$ICI/catalog/catalog-watcher.sh" demarrer
    reparer_element "identifiants" bash "$ICI/password.sh" regenerer
    return "$reparer_echec"
}
