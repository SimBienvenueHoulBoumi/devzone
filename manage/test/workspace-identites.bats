#!/usr/bin/env bats
# Identites et connexions du workspace Kubernetes gardees dans le volume etat (#402).
# Seulement helm lint et helm template : aucun cluster n'est touche.

setup() {
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CHART="$RACINE/charts/devzone-workspace"
    command -v helm >/dev/null 2>&1 || skip "helm absent"
}

# Rendu complet du chart, avec les options passees en arguments.
rendu() {
    helm template t "$CHART" --namespace devzone-workspace "$@"
}

# Rendu du StatefulSet seul.
rendu_ss() {
    helm template t "$CHART" --namespace devzone-workspace --show-only templates/statefulset.yaml "$@"
}

# Bloc de l'initContainer etat-init, tel que rendu.
bloc_etat_init() {
    awk '/^        - name: etat-init$/{p=1;print;next} /^        # kubedock/{p=0} p' <<<"$1"
}

# Bloc du conteneur workspace (de son nom jusqu'a volumeClaimTemplates : ses montages
# viennent apres ses ressources).
bloc_workspace() {
    awk '/^        - name: workspace$/{p=1} /^  volumeClaimTemplates:/{p=0} p' <<<"$1"
}

# Les 9 chemins par defaut de persistence.state.paths (sans les tirets).
chemins_defaut() {
    printf '%s\n' .config/gh .config/git .claude .config/opencode \
        .local/share/opencode .local/state/oc-lancer .m2 .gradle .local/share/pnpm
}

@test "etat : helm lint du chart" {
    run helm lint "$CHART"
    [ "$status" -eq 0 ]
}

@test "etat-init : initContainer present, avant kubedock, dans l'image du workspace" {
    run rendu_ss
    [ "$status" -eq 0 ]
    local init
    init="$(bloc_etat_init "$output")"
    grep -q -- '- name: etat-init' <<<"$init" || false
    grep -q -- 'image: "ghcr.io/simbienvenuehoulboumi/devzone-workspace:' <<<"$init" || false
    # Il tourne avant les sidecars : sa ligne precede celle de kubedock.
    local l_init l_kd
    l_init="$(grep -n -- '- name: etat-init' <<<"$output" | cut -d: -f1)"
    l_kd="$(grep -n -- '- name: kubedock' <<<"$output" | cut -d: -f1)"
    [ "$l_init" -lt "$l_kd" ]
}

@test "etat-init : tourne en vscode (UID 1000), sans privilege ni escalade" {
    run rendu_ss
    [ "$status" -eq 0 ]
    local init
    init="$(bloc_etat_init "$output")"
    grep -q -- 'runAsUser: 1000' <<<"$init" || false
    grep -q -- 'runAsGroup: 1000' <<<"$init" || false
    grep -q -- 'allowPrivilegeEscalation: false' <<<"$init" || false
    grep -q -- 'drop: \["ALL"\]' <<<"$init" || false
    ! grep -q -- 'privileged' <<<"$init" || false
}

@test "etat-init : cree les 9 dossiers du volume etat, sous /home/vscode/.devzone-etat" {
    run rendu_ss
    [ "$status" -eq 0 ]
    local cmd
    cmd="$(grep -- 'command: \["sh", "-c"' <<<"$output")"
    local c
    while read -r c; do
        grep -q -- "/home/vscode/.devzone-etat/$c " <<<"$cmd" || grep -q -- "/home/vscode/.devzone-etat/$c\"" <<<"$cmd" || false
    done < <(chemins_defaut)
    grep -q -- 'command: \["sh", "-c", "mkdir -p ' <<<"$cmd" || false
}

@test "etat-init : monte le volume etat sur /home/vscode/.devzone-etat" {
    run rendu_ss
    [ "$status" -eq 0 ]
    local init
    init="$(bloc_etat_init "$output")"
    grep -q -- '- name: etat' <<<"$init" || false
    grep -q -- 'mountPath: /home/vscode/.devzone-etat' <<<"$init" || false
}

@test "montages : le workspace monte chaque chemin du volume etat a son emplacement habituel" {
    run rendu_ss
    [ "$status" -eq 0 ]
    local principal
    principal="$(bloc_workspace "$output")"
    local c
    while read -r c; do
        grep -q -- "subPath: \"$c\"" <<<"$principal" || false
        grep -q -- "mountPath: \"/home/vscode/$c\"" <<<"$principal" || false
    done < <(chemins_defaut)
    # Le volume entier reste visible sous .devzone-etat.
    grep -q -- 'mountPath: /home/vscode/.devzone-etat' <<<"$principal" || false
    # Le volume etat n'est plus monte sous /etat.
    ! grep -q -- 'mountPath: /etat' <<<"$output" || false
}

@test "montages : un chemin ajoute dans persistence.state.paths est monte et cree" {
    run rendu_ss --set 'persistence.state.paths[9]=.config/devzone'
    [ "$status" -eq 0 ]
    grep -q -- '/home/vscode/.devzone-etat/.config/devzone' <<<"$output" || false
    grep -q -- 'subPath: ".config/devzone"' <<<"$output" || false
    grep -q -- 'mountPath: "/home/vscode/.config/devzone"' <<<"$output" || false
}

@test "montages : aucun lien symbolique (un lien cree dans l'initContainer ne survit pas)" {
    run rendu
    [ "$status" -eq 0 ]
    ! grep -q -- 'ln -s' <<<"$output" || false
    ! grep -q -- 'ln -sfn' <<<"$output" || false
}

@test "pod : fsGroup 1000 pour que le volume etat soit ecrit par vscode" {
    run rendu_ss
    [ "$status" -eq 0 ]
    grep -q -- 'securityContext:' <<<"$output" || false
    grep -q -- 'fsGroup: 1000' <<<"$output" || false
}

@test "pod : runAsUser 1000, runAsGroup 1000, runAsNonRoot true (jamais root)" {
    run rendu_ss
    [ "$status" -eq 0 ]
    local pod
    pod="$(awk '/^      securityContext:$/{p=1} /^      # Sidecars/{p=0} p' <<<"$output")"
    grep -q -- 'runAsUser: 1000' <<<"$pod" || false
    grep -q -- 'runAsGroup: 1000' <<<"$pod" || false
    grep -q -- 'runAsNonRoot: true' <<<"$pod" || false
    grep -q -- 'fsGroup: 1000' <<<"$pod" || false
    ! grep -q -- 'runAsUser: 0' <<<"$output" || false
}

@test "workspace : HOME=/home/vscode dans le conteneur workspace" {
    run rendu_ss
    [ "$status" -eq 0 ]
    local principal
    principal="$(bloc_workspace "$output")"
    grep -q -- '- name: HOME' <<<"$principal" || false
    grep -q -- 'value: /home/vscode$' <<<"$principal" || false
    # Pas de HOME /root nulle part dans le rendu.
    ! grep -q -- '/root' <<<"$output" || false
}

@test "privilege : aucun conteneur privileged, dans tout le rendu" {
    run rendu
    [ "$status" -eq 0 ]
    ! grep -q -- 'privileged' <<<"$output" || false
    ! grep -q -- 'privileged: true' <<<"$output" || false
}

@test "pvc : etat garde a la desinstallation (annotation keep et retention Retain)" {
    run rendu_ss
    [ "$status" -eq 0 ]
    local etat
    etat="$(awk '/^    - metadata:/{p=0} /^        name: etat$/{p=1} p' <<<"$output")"
    grep -q -- 'helm.sh/resource-policy: keep' <<<"$etat" || false
    grep -q -- 'persistentVolumeClaimRetentionPolicy:' <<<"$output" || false
    grep -q -- 'whenDeleted: Retain' <<<"$output" || false
    grep -q -- 'whenScaled: Retain' <<<"$output" || false
}

@test "pvc : etat reste un volumeClaimTemplate, taille par defaut 10Gi" {
    run rendu_ss
    [ "$status" -eq 0 ]
    grep -q -- '^        name: etat$' <<<"$output" || false
    grep -q -- 'storage: 10Gi' <<<"$output" || false
}

@test "secrets : le rendu ne contient aucun identifiant ni mot de passe" {
    run rendu
    [ "$status" -eq 0 ]
    ! grep -qi -- 'password' <<<"$output" || false
    ! grep -qi -- 'GH_TOKEN' <<<"$output" || false
    ! grep -qi -- 'secretName' <<<"$output" || false
    ! grep -q -- 'privileged' <<<"$output" || false
}
