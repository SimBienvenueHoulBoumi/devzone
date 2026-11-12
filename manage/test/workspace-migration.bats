#!/usr/bin/env bats
# Migration du poste Docker vers le workspace Kubernetes (#403). Faux docker et
# kubectl (voir migration.bash) : aucun volume Docker ni cluster reel touche.

setup() {
    load migration
    migration_isole
    export DEVZONE_WORKSPACE_ATTENTE=1 DEVZONE_WORKSPACE_PAS=0.1
}

@test "migrer : les cinq etapes, projets, identites, etat, bascule" {
    faux_volumes
    ws migrer --oui
    [ "$status" -eq 0 ]
    [[ "$output" == *"[1/5]"*"[2/5]"*"[3/5]"*"[4/5]"*"[5/5]"* ]] || false
    [ -f "$T/pod/workspaces/projets/alpha/a.txt" ]
    [ -f "$T/pod/workspaces/projets/beta/b.txt" ]
    [ -f "$T/pod/home/vscode/.config/gh/hosts.yml" ]
    [ -f "$T/pod/home/vscode/.m2/a.jar" ]
    [ -f "$T/pod/workspaces/projets/.devzone.modules" ]
    [ -f "$T/pod/workspaces/projets/.devzone.paquets" ]
    grep -qx "workspace=kubernetes" "$T/poste/.devzone.modules" || false
    grep -qx "ia=on" "$T/poste/.devzone.modules" || false
}

@test "migrer : volumes lus en lecture seule, jamais supprimes" {
    faux_volumes
    ws migrer --oui
    [ "$status" -eq 0 ]
    grep -q "docker run --rm -v devzone-gh:/src:ro" "$T/docker.log" || false
    ! grep -q "volume rm" "$T/docker.log" || false
    [ -f "$T/volumes/devzone-gh/hosts.yml" ]
    [ -f "$T/poste/workspace/alpha/a.txt" ]
}

@test "migrer : volume absent ignore, config sans chemin dans le chart ignore" {
    ws migrer --oui
    [ "$status" -eq 0 ]
    [[ "$output" == *"devzone-gh : absent, ignoré"* ]] || false
    [[ "$output" == *"devzone-config : aucun chemin"* ]] || false
}

@test "migrer : sans --oui et sans terminal, refuse et ne touche a rien" {
    ws migrer </dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"pas de terminal"* ]] || false
    [ ! -s "$T/kubectl.log" ]
    ! grep -q "workspace=" "$T/poste/.devzone.modules" || false
}

@test "migrer etape 1 : cluster injoignable, arret avant toute copie" {
    export FAUX_CLUSTER_KO=1
    ws migrer --oui
    [ "$status" -eq 1 ]
    [[ "$output" == *"cluster injoignable"* ]] || false
    ! grep -q " cp " "$T/kubectl.log" || false
    ! grep -q "workspace=" "$T/poste/.devzone.modules" || false
}

@test "migrer etape 1 : workspace non demarre, indique devzone workspace demarrer" {
    export FAUX_PHASE=Pending
    ws migrer --oui
    [ "$status" -eq 1 ]
    [[ "$output" == *"devzone workspace demarrer"* ]] || false
    ! grep -q " cp " "$T/kubectl.log" || false
}

@test "migrer etape 1 : espace insuffisant" {
    export FAUX_DF_KO=1
    ws migrer --oui
    [ "$status" -eq 1 ]
    [[ "$output" == *"espace insuffisant"* ]] || false
    ! grep -q " cp " "$T/kubectl.log" || false
}

@test "migrer etape 2 : copie echouee, arret sans suite ni bascule" {
    export FAUX_CP_ECHEC=1
    ws migrer --oui
    [ "$status" -eq 1 ]
    [[ "$output" == *"copie du projet alpha échouée"* ]] || false
    [[ "$output" != *"[3/5]"* ]] || false
    ! grep -q "workspace=" "$T/poste/.devzone.modules" || false
}

@test "migrer etape 2 : copie incomplete detectee par la verification" {
    export FAUX_CP_TRONQUE=1
    ws migrer --oui
    [ "$status" -eq 1 ]
    [[ "$output" == *"copie différente"* ]] || false
    [[ "$output" != *"[3/5]"* ]] || false
    ! grep -q "workspace=" "$T/poste/.devzone.modules" || false
}

@test "migrer etape 3 : lecture de volume echouee, arret avant l'etat et la bascule" {
    faux_volumes
    export FAUX_DOCKER_RUN_KO=1
    ws migrer --oui
    [ "$status" -eq 1 ]
    [[ "$output" == *"lecture du volume devzone-gh échouée"* ]] || false
    [[ "$output" != *"[4/5]"* ]] || false
    ! grep -q "workspace=" "$T/poste/.devzone.modules" || false
}

@test "migrer : option inconnue refusee" {
    ws migrer --tout
    [ "$status" -eq 1 ]
    [[ "$output" == *"option inconnue"* ]] || false
    [ ! -s "$T/kubectl.log" ]
}

@test "migrer : chemins des volumes identiques a persistence.state.paths du chart" {
    run grep -oE '^        [a-z0-9-]+\) echo \.[A-Za-z0-9_./-]+' "$RACINE/manage/scripts/migrer.sh"
    [ "$status" -eq 0 ]
    [ "$(wc -l <<<"$output")" -eq 9 ]
    while read -r chemin; do
        grep -qx "      - $chemin" "$RACINE/charts/devzone-workspace/values.yaml" || false
    done < <(sed -E 's/.*echo //' <<<"$output")
}
