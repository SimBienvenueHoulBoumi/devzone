#!/usr/bin/env bats
# Chart charts/devzone-postgres (#516): the chart alone, rendered by helm template.
# The expected values are written in this file. The helm-direct path
# (chart_install in .devcontainer/postgres/postgres.sh) passes the size with --set.
# Skipped without helm.

setup() {
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CHART="$RACINE/charts/devzone-postgres"
    command -v helm >/dev/null 2>&1 || skip "helm missing"
}

# Chart rendered in namespace team; extra arguments go to helm template
render() {
    helm template postgres "$CHART" --namespace team "$@"
}

# Name of the volume claim template of the rendered StatefulSet (stdin)
claim_template() {
    awk '/^  volumeClaimTemplates:/ {f = 1; next} f && /^ *name: / {print $2; exit}'
}

@test "chart devzone-postgres: helm lint" {
    run helm lint "$CHART"
    [ "$status" -eq 0 ]
}

@test "chart devzone-postgres: default values render a StatefulSet and a Service, no Secret" {
    run render
    [ "$status" -eq 0 ]
    [ "$(grep -c '^kind: ' <<<"$output")" -eq 2 ]
    [[ "$output" == *"kind: StatefulSet"* ]] || false
    [[ "$output" == *"kind: Service"* ]] || false
    [[ "$output" != *"kind: Secret"* ]] || false
}

@test "chart devzone-postgres: default values give image postgres:16.15-alpine, port 5432, 256Mi, 5Gi, claim donnees" {
    run render --show-only templates/statefulset.yaml
    [ "$status" -eq 0 ]
    [[ "$output" == *"image: postgres:16.15-alpine"* ]] || false
    [[ "$output" == *"containerPort: 5432"* ]] || false
    [[ "$output" == *"memory: 256Mi"* ]] || false
    [[ "$output" == *"storage: 5Gi"* ]] || false
    [ "$(claim_template <<<"$output")" = donnees ] || false
    [[ "$output" == *"- name: donnees"* ]] || false

    run render --show-only templates/service.yaml
    [ "$status" -eq 0 ]
    [[ "$output" == *"port: 5432"* ]] || false
    [[ "$output" == *"targetPort: 5432"* ]] || false
}

@test "chart devzone-postgres: --set size (chart_install path) gives the volume size, the rest unchanged" {
    run render --set size=20Gi --show-only templates/statefulset.yaml
    [ "$status" -eq 0 ]
    [[ "$output" == *"storage: 20Gi"* ]] || false
    [[ "$output" == *"image: postgres:16.15-alpine"* ]] || false
    [[ "$output" == *"memory: 256Mi"* ]] || false
    [ "$(claim_template <<<"$output")" = donnees ] || false
}

@test "chart devzone-postgres: --set image, port, memory and claim come from the values" {
    sets=(--set image=postgres:17-alpine --set port=5433 --set memory=512Mi --set claim=data)

    run render "${sets[@]}" --show-only templates/statefulset.yaml
    [ "$status" -eq 0 ]
    [[ "$output" == *"image: postgres:17-alpine"* ]] || false
    [[ "$output" == *"containerPort: 5432"* ]] || false
    [[ "$output" == *"memory: 512Mi"* ]] || false
    [ "$(claim_template <<<"$output")" = data ] || false
    [[ "$output" == *"- name: data"* ]] || false

    run render "${sets[@]}" --show-only templates/service.yaml
    [ "$status" -eq 0 ]
    [[ "$output" == *"port: 5433"* ]] || false
    [[ "$output" == *"targetPort: 5432"* ]] || false
}

@test "chart devzone-postgres: no namespace written in the chart, the release namespace is used" {
    run render
    [ "$status" -eq 0 ]
    [ "$(grep -c '^  namespace: team$' <<<"$output")" -eq 2 ]
    [[ "$output" != *"namespace: devzone"* ]] || false
}
