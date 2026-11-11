#!/usr/bin/env bats
# Retour arriere et nettoyage Docker du workspace Kubernetes (#403). Faux docker et
# kubectl (voir migration.bash) : aucun volume Docker ni cluster reel touche.

setup() {
    load migration
    migration_isole
}

@test "revenir : workspace=docker, poste Docker intact, rappelle make shell" {
    echo "workspace=kubernetes" >>"$T/poste/.devzone.modules"
    ws revenir
    [ "$status" -eq 0 ]
    grep -qx "workspace=docker" "$T/poste/.devzone.modules" || false
    ! grep -q "workspace=kubernetes" "$T/poste/.devzone.modules" || false
    [[ "$output" == *"make shell"* ]] || false
    [ ! -s "$T/docker.log" ]
    [ ! -s "$T/kubectl.log" ]
    [ -f "$T/poste/workspace/alpha/a.txt" ]
}

@test "revenir --rapatrier : projets du pod recopies dans ./workspace" {
    mkdir -p "$T/pod/workspaces/projets/gamma" "$T/pod/workspaces/projets/alpha"
    echo "g" >"$T/pod/workspaces/projets/gamma/g.txt"
    echo "modifie au pod" >"$T/pod/workspaces/projets/alpha/a.txt"
    ws revenir --rapatrier
    [ "$status" -eq 0 ]
    [ "$(cat "$T/poste/workspace/alpha/a.txt")" = "modifie au pod" ]
    [ -f "$T/poste/workspace/gamma/g.txt" ]
    grep -qx "workspace=docker" "$T/poste/.devzone.modules" || false
    ! grep -q "volume rm" "$T/docker.log" || false
}

@test "revenir --rapatrier : version du poste sauvegardee avant d'etre remplacee" {
    echo "travail local" >"$T/poste/workspace/alpha/local.txt"
    mkdir -p "$T/pod/workspaces/projets/alpha"
    echo "modifie au pod" >"$T/pod/workspaces/projets/alpha/a.txt"
    ws revenir --rapatrier
    [ "$status" -eq 0 ]
    [[ "$output" == *"projet alpha : version du poste sauvegardée dans .devzone.sauvegarde/"* ]] || false
    sauv="$(find "$T/poste/.devzone.sauvegarde" -mindepth 1 -maxdepth 1 -type d | head -1)"
    [[ "$(basename "$sauv")" =~ ^[0-9]{8}-[0-9]{6}$ ]] || false
    [ "$(cat "$sauv/workspace/alpha/local.txt")" = "travail local" ]
    [ "$(cat "$sauv/workspace/alpha/a.txt")" = "a" ]
    [ "$(cat "$T/poste/workspace/alpha/a.txt")" = "modifie au pod" ]
    ! [ -e "$T/poste/workspace/alpha/local.txt" ] || false
    [ -f "$T/poste/workspace/beta/b.txt" ]
}

@test "revenir --rapatrier : copie echouee, pas de bascule" {
    echo "workspace=kubernetes" >>"$T/poste/.devzone.modules"
    mkdir -p "$T/pod/workspaces/projets/alpha"
    export FAUX_CP_ECHEC=1
    ws revenir --rapatrier
    [ "$status" -eq 1 ]
    grep -qx "workspace=kubernetes" "$T/poste/.devzone.modules" || false
}

@test "revenir : option inconnue refusee" {
    ws revenir --tout
    [ "$status" -eq 1 ]
    [[ "$output" == *"option inconnue"* ]] || false
}

@test "nettoyer-docker : sans terminal ni --oui, refuse, aucun volume supprime" {
    faux_volumes
    ws nettoyer-docker </dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"pas de terminal"* ]] || false
    [[ "$output" == *"devzone-gh"* ]] || false
    ! grep -q "volume rm" "$T/docker.log" || false
    [ -d "$T/volumes/devzone-gh" ]
    [ -d "$T/volumes/devzone-m2" ]
}

@test "nettoyer-docker --oui : supprime seulement les volumes devzone-*" {
    faux_volumes
    mkdir -p "$T/volumes/autre-volume"
    ws nettoyer-docker --oui
    [ "$status" -eq 0 ]
    [ ! -d "$T/volumes/devzone-gh" ]
    [ ! -d "$T/volumes/devzone-m2" ]
    [ -d "$T/volumes/autre-volume" ]
    ! grep -q "volume rm autre-volume" "$T/docker.log" || false
}

@test "nettoyer-docker : aucun volume, rien a faire" {
    ws nettoyer-docker --oui
    [ "$status" -eq 0 ]
    [[ "$output" == *"Aucun volume"* ]] || false
    ! grep -q "volume rm" "$T/docker.log" || false
}

@test "migrer, revenir : jamais d'appel destructif de docker ni de kubectl" {
    faux_volumes
    ws migrer --oui
    [ "$status" -eq 0 ]
    ws revenir --rapatrier
    [ "$status" -eq 0 ]
    ! grep -qE "volume rm|volume prune|system prune|rm -f| rm " "$T/docker.log" || false
    ! grep -qE " delete |uninstall" "$T/kubectl.log" || false
}

@test "aide : migrer, revenir et nettoyer-docker listes" {
    ws --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"migrer [--oui]"* ]] || false
    [[ "$output" == *"revenir [--rapatrier]"* ]] || false
    [[ "$output" == *"nettoyer-docker"* ]] || false
}
