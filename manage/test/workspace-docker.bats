#!/usr/bin/env bats
# Workspace Kubernetes : Docker du pod pour Testcontainers (#400). Seulement
# helm template et helm lint : aucun cluster n'est touche, et le vrai helm est
# utilise (pas de faux helm dans le PATH, contrairement a workspace.bats).

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

# Bloc initContainers (du mot-clé jusqu'a containers), tel que rendu.
bloc_init() {
    awk '/^      initContainers:/{p=1} /^      containers:/{p=0} p' <<<"$1"
}

@test "docker : helm lint du chart" {
    run helm lint "$CHART"
    [ "$status" -eq 0 ]
}

@test "docker : conteneur workspace relie au Docker du pod (DOCKER_HOST, TESTCONTAINERS_HOST_OVERRIDE)" {
    run rendu_de templates/statefulset.yaml
    [ "$status" -eq 0 ]
    grep -q -- "value: tcp://localhost:2375" <<<"$output" || false
    grep -q -- "name: TESTCONTAINERS_HOST_OVERRIDE" <<<"$output" || false
    grep -q -- "value: localhost" <<<"$output" || false
}

@test "docker : sidecar docker en sidecar natif, avant le conteneur workspace" {
    run rendu_de templates/statefulset.yaml
    [ "$status" -eq 0 ]
    local init
    init="$(bloc_init "$output")"
    grep -q -- "- name: docker" <<<"$init" || false
    grep -q -- "restartPolicy: Always" <<<"$init" || false
    grep -q -- "privileged: true" <<<"$init" || false
    # Le sidecar n'est pas un conteneur ordinaire : il ne doit pas apparaitre dans containers.
    ! grep -q -- "- name: docker" <<<"$(awk '/^      containers:/{p=1} /^  volumeClaimTemplates:/{p=0} p' <<<"$output")" || false
}

@test "docker : le Docker n'ecoute que sur 127.0.0.1 du pod, sans TLS" {
    run rendu_de templates/statefulset.yaml
    [ "$status" -eq 0 ]
    grep -q -- "--host=tcp://127.0.0.1:2375" <<<"$output" || false
    grep -q -- "DOCKER_TLS_CERTDIR" <<<"$output" || false
    ! grep -q -- "0.0.0.0" <<<"$output" || false
}

@test "docker : le conteneur workspace attend le Docker (startupProbe docker info, 60 tentatives)" {
    run rendu_de templates/statefulset.yaml
    [ "$status" -eq 0 ]
    grep -q -- 'command: \["docker", "-H", "tcp://127.0.0.1:2375", "info"\]' <<<"$output" || false
    grep -q -- "failureThreshold: 60" <<<"$output" || false
    grep -q -- "periodSeconds: 1" <<<"$output" || false
}

@test "docker : aucun port 2375 expose (ni Service, ni NetworkPolicy, ni containerPort)" {
    run rendu
    [ "$status" -eq 0 ]
    ! grep -q -- "containerPort" <<<"$output" || false
    ! grep -q -- "hostPort" <<<"$output" || false
    run rendu_de templates/service.yaml
    [ "$status" -eq 0 ]
    ! grep -q -- "2375" <<<"$output" || false
    run rendu_de templates/networkpolicy.yaml
    [ "$status" -eq 0 ]
    ! grep -q -- "2375" <<<"$output" || false
}

@test "docker : PVC docker monte sur /var/lib/docker, taille par defaut 30Gi" {
    run rendu_de templates/statefulset.yaml
    [ "$status" -eq 0 ]
    grep -q -- "mountPath: /var/lib/docker" <<<"$output" || false
    grep -q -- "        name: docker" <<<"$output" || false
    grep -q -- "storage: 30Gi" <<<"$output" || false
}

@test "docker : taille et classe du PVC docker reglables" {
    run rendu_de templates/statefulset.yaml --set persistence.docker.size=50Gi --set persistence.docker.storageClass=rapide
    [ "$status" -eq 0 ]
    grep -q -- "storage: 50Gi" <<<"$output" || false
    grep -q -- "storageClassName: rapide" <<<"$output" || false
}

@test "docker : limites du sidecar lues dans les valeurs (2 CPU, 4 Gi par defaut)" {
    run rendu_de templates/statefulset.yaml
    [ "$status" -eq 0 ]
    local init
    init="$(bloc_init "$output")"
    grep -q -- 'cpu: "2"' <<<"$init" || false
    grep -q -- "memory: 4Gi" <<<"$init" || false
    run rendu_de templates/statefulset.yaml --set sidecar.resources.limits.memory=8Gi
    [ "$status" -eq 0 ]
    init="$(bloc_init "$output")"
    grep -q -- "memory: 8Gi" <<<"$init" || false
}
