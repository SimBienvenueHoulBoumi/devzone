#!/usr/bin/env bats
# Workspace Kubernetes sans Docker : kubedock (API Docker) et BuildKit rootless,
# sans conteneur privilegie (#410). Seulement helm lint et helm template : aucun
# cluster n'est touche, et le vrai helm est utilise (pas de faux helm dans le PATH,
# contrairement a workspace.bats).

setup() {
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CHART="$RACINE/charts/devzone-workspace"
    command -v helm >/dev/null 2>&1 || skip "helm absent"
}

# Rendu complet du chart, avec les options passees en arguments.
rendu() {
    helm template t "$CHART" --namespace devzone-workspace "$@"
}

# Rendu d'un seul template (--show-only).
rendu_de() {
    local template="$1"
    shift
    helm template t "$CHART" --namespace devzone-workspace --show-only "$template" "$@"
}

# Bloc initContainers (du mot-cle jusqu'a containers), tel que rendu.
bloc_init() {
    awk '/^      initContainers:/{p=1} /^      containers:/{p=0} p' <<<"$1"
}

# Bloc containers (du mot-cle jusqu'a volumeClaimTemplates), tel que rendu.
bloc_containers() {
    awk '/^      containers:/{p=1} /^  volumeClaimTemplates:/{p=0} p' <<<"$1"
}

# Bloc d'un conteneur d'initContainers, identifie par son nom.
bloc_sidecar() {
    awk -v nom="$2" '
        /^        - name: /{ p = ($0 == nom) }
        /^      containers:/{ p = 0 }
        p' <<<"$1"
}

@test "sans-docker : helm lint du chart" {
    run helm lint "$CHART"
    [ "$status" -eq 0 ]
}

@test "securite : aucun conteneur privilegie dans le rendu (valeurs par defaut)" {
    run rendu
    [ "$status" -eq 0 ]
    ! grep -q -- "privileged" <<<"$output" || false
}

@test "securite : aucun conteneur privilegie avec buildkit.unconfined=false" {
    run rendu --set buildkit.unconfined=false
    [ "$status" -eq 0 ]
    ! grep -q -- "privileged" <<<"$output" || false
}

@test "sans-docker : plus de dind, ni image docker, ni PVC docker" {
    run rendu
    [ "$status" -eq 0 ]
    ! grep -q -- "dind" <<<"$output" || false
    ! grep -q -- "docker:27" <<<"$output" || false
    ! grep -q -- "/var/lib/docker" <<<"$output" || false
    ! grep -q -- "name: docker" <<<"$output" || false
}

@test "sans-docker : le StatefulSet n'a que les PVC workspace et etat" {
    run rendu_de templates/statefulset.yaml
    [ "$status" -eq 0 ]
    local pvc
    pvc="$(awk '/^  volumeClaimTemplates:/{p=1} p && /^    - metadata:/{getline; print}' <<<"$output")"
    [ "$(wc -l <<<"$pvc" | tr -d ' ')" -eq 2 ]
    grep -q -- "name: workspace" <<<"$pvc" || false
    grep -q -- "name: etat" <<<"$pvc" || false
}

@test "kubedock : sidecar natif, avant le conteneur workspace, image 0.23.0" {
    run rendu_de templates/statefulset.yaml
    [ "$status" -eq 0 ]
    local kd
    kd="$(bloc_sidecar "$(bloc_init "$output")" "        - name: kubedock")"
    grep -q -- "image: joyrex2001/kubedock:0.23.0" <<<"$kd" || false
    grep -q -- "restartPolicy: Always" <<<"$kd" || false
    # Un sidecar natif est un initContainer : il n'apparait pas dans containers.
    ! grep -q -- "- name: kubedock" <<<"$(bloc_containers "$output")" || false
}

@test "kubedock : arguments de l'essai (server --port-forward --reverse-proxy --timeout)" {
    run rendu_de templates/statefulset.yaml
    [ "$status" -eq 0 ]
    local args
    args="$(awk '/^          args:/{p=1;next} p && /^          [a-z]/{exit} p' <<<"$(bloc_sidecar "$(bloc_init "$output")" "        - name: kubedock")" | sed 's/^ *- //' | paste -sd' ' -)"
    [ "$args" = 'server --port-forward --reverse-proxy --timeout "5m"' ]
}

@test "kubedock : --timeout depuis kubedock.delai (5m par defaut, premier tirage d'image)" {
    run rendu_de templates/statefulset.yaml
    [ "$status" -eq 0 ]
    local args
    args="$(awk '/^          args:/{p=1;next} p && /^          [a-z]/{exit} p' <<<"$(bloc_sidecar "$(bloc_init "$output")" "        - name: kubedock")" | sed 's/^ *- //' | paste -sd' ' -)"
    [ "$args" = 'server --port-forward --reverse-proxy --timeout "5m"' ]
    run rendu_de templates/statefulset.yaml --set kubedock.delai=10m
    [ "$status" -eq 0 ]
    grep -q -- '- "10m"' <<<"$(bloc_sidecar "$(bloc_init "$output")" "        - name: kubedock")" || false
}

@test "kubedock : NAMESPACE vient de metadata.namespace du pod" {
    run rendu_de templates/statefulset.yaml
    [ "$status" -eq 0 ]
    local kd
    kd="$(bloc_sidecar "$(bloc_init "$output")" "        - name: kubedock")"
    grep -q -- "name: NAMESPACE" <<<"$kd" || false
    grep -q -- "fieldPath: metadata.namespace" <<<"$kd" || false
}

@test "kubedock : attente du port 2475 (startupProbe tcpSocket)" {
    run rendu_de templates/statefulset.yaml
    [ "$status" -eq 0 ]
    local kd
    kd="$(bloc_sidecar "$(bloc_init "$output")" "        - name: kubedock")"
    grep -q -- "tcpSocket:" <<<"$kd" || false
    grep -q -- "port: 2475" <<<"$kd" || false
}

@test "buildkit : sidecar natif rootless, image figee en version rootless" {
    run rendu_de templates/statefulset.yaml
    [ "$status" -eq 0 ]
    local bk
    bk="$(bloc_sidecar "$(bloc_init "$output")" "        - name: buildkitd")"
    grep -q -- "image: moby/buildkit:v0.34.2-rootless" <<<"$bk" || false
    grep -q -- "restartPolicy: Always" <<<"$bk" || false
    grep -q -- "runAsUser: 1000" <<<"$bk" || false
    grep -q -- "runAsGroup: 1000" <<<"$bk" || false
}

@test "buildkit : arguments rootless (sans sandbox de processus, ecoute sur 127.0.0.1:1234)" {
    run rendu_de templates/statefulset.yaml
    [ "$status" -eq 0 ]
    local bk
    bk="$(bloc_sidecar "$(bloc_init "$output")" "        - name: buildkitd")"
    grep -q -- "- --oci-worker-no-process-sandbox" <<<"$bk" || false
    grep -q -- "- --addr=tcp://127.0.0.1:1234" <<<"$bk" || false
    ! grep -q -- "0.0.0.0" <<<"$output" || false
}

@test "buildkit : seccomp et AppArmor Unconfined par defaut, retires si unconfined=false" {
    run rendu_de templates/statefulset.yaml
    [ "$status" -eq 0 ]
    local bk
    bk="$(bloc_sidecar "$(bloc_init "$output")" "        - name: buildkitd")"
    grep -q -- "seccompProfile:" <<<"$bk" || false
    grep -q -- "appArmorProfile:" <<<"$bk" || false
    [ "$(grep -c -- "type: Unconfined" <<<"$bk")" -eq 2 ]
    run rendu_de templates/statefulset.yaml --set buildkit.unconfined=false
    [ "$status" -eq 0 ]
    bk="$(bloc_sidecar "$(bloc_init "$output")" "        - name: buildkitd")"
    ! grep -q -- "Unconfined" <<<"$bk" || false
}

@test "buildkit : attente de buildctl debug workers (startupProbe)" {
    run rendu_de templates/statefulset.yaml
    [ "$status" -eq 0 ]
    local bk
    bk="$(bloc_sidecar "$(bloc_init "$output")" "        - name: buildkitd")"
    grep -q -- 'command: \["buildctl", "--addr", "tcp://127.0.0.1:1234", "debug", "workers"\]' <<<"$bk" || false
}

@test "variables : le workspace parle a kubedock, BuildKit et desactive Ryuk et les checks" {
    run rendu_de templates/statefulset.yaml
    [ "$status" -eq 0 ]
    local principal
    principal="$(awk '/^        - name: workspace$/{p=1} /^          resources:/{p=0} p' <<<"$output")"
    grep -q -- "- name: DOCKER_HOST" <<<"$principal" || false
    grep -q -- "value: tcp://127.0.0.1:2475" <<<"$principal" || false
    grep -q -- "- name: TESTCONTAINERS_RYUK_DISABLED" <<<"$principal" || false
    grep -q -- 'value: "true"' <<<"$principal" || false
    grep -q -- "- name: TESTCONTAINERS_CHECKS_DISABLE" <<<"$principal" || false
    grep -q -- "- name: BUILDKIT_HOST" <<<"$principal" || false
    grep -q -- "value: tcp://127.0.0.1:1234" <<<"$principal" || false
}

@test "workspace : une commande qui ne se termine pas (sleep infinity par defaut)" {
    run rendu_de templates/statefulset.yaml
    [ "$status" -eq 0 ]
    local principal
    principal="$(awk '/^        - name: workspace$/{p=1} /^          resources:/{p=0} p' <<<"$output")"
    grep -q -- 'command: \["sleep","infinity"\]' <<<"$principal" || false
}

@test "reseau : aucun port declare (ni containerPort, ni hostPort) et aucun port d'API Docker expose" {
    run rendu
    [ "$status" -eq 0 ]
    ! grep -q -- "containerPort" <<<"$output" || false
    ! grep -q -- "hostPort" <<<"$output" || false
    run rendu_de templates/service.yaml
    [ "$status" -eq 0 ]
    ! grep -q -- "2475" <<<"$output" || false
    ! grep -q -- "1234" <<<"$output" || false
    run rendu_de templates/networkpolicy.yaml
    [ "$status" -eq 0 ]
    ! grep -q -- "2475" <<<"$output" || false
    ! grep -q -- "1234" <<<"$output" || false
}

@test "reseau : par defaut la NetworkPolicy ne limite que l'entree (pas de Egress)" {
    run rendu_de templates/networkpolicy.yaml
    [ "$status" -eq 0 ]
    grep -q -- "- Ingress" <<<"$output" || false
    ! grep -q -- "Egress" <<<"$output" || false
    ! grep -q -- "egress:" <<<"$output" || false
}

@test "reseau : sortieRestreinte=true ajoute la regle Egress (namespace et DNS)" {
    run rendu_de templates/networkpolicy.yaml --set networkPolicy.sortieRestreinte=true
    [ "$status" -eq 0 ]
    grep -q -- "- Egress" <<<"$output" || false
    grep -q -- "egress:" <<<"$output" || false
    grep -q -- "kubernetes.io/metadata.name: kube-system" <<<"$output" || false
    grep -q -- "port: 53" <<<"$output" || false
}

@test "role : Role (pas ClusterRole), limite au namespace, sans secrets ni deployments" {
    run rendu_de templates/role.yaml
    [ "$status" -eq 0 ]
    grep -q -- "kind: Role$" <<<"$output" || false
    ! grep -q -- "ClusterRole" <<<"$output" || false
    ! grep -q -- '"secrets"' <<<"$output" || false
    ! grep -q -- '"deployments"' <<<"$output" || false
}

@test "role : droits de kubedock (pods, pods/log, pods/exec, pods/portforward, services, configmaps)" {
    run rendu_de templates/role.yaml
    [ "$status" -eq 0 ]
    grep -q -- '"pods/log"' <<<"$output" || false
    grep -q -- '"pods/exec"' <<<"$output" || false
    grep -q -- '"pods/portforward"' <<<"$output" || false
    grep -q -- '"services"' <<<"$output" || false
    grep -q -- '"configmaps"' <<<"$output" || false
    # Jamais de joker sur les verbes ou les ressources.
    ! grep -q -- '"\*"' <<<"$output" || false
}

@test "chart : helm lint et helm template" {
    run helm lint "$CHART"
    [ "$status" -eq 0 ]
    run helm template devzone-workspace "$CHART" --namespace devzone-workspace
    [ "$status" -eq 0 ]
}
