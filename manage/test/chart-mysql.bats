#!/usr/bin/env bats
# Chart charts/devzone-mysql (#538): the chart alone, rendered by helm template.
# The expected values are written in this file. The helm-direct path
# (chart_install in .devcontainer/chart-direct.sh) passes them with --set.
# Skipped without helm.

setup() {
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CHART="$RACINE/charts/devzone-mysql"
    command -v helm >/dev/null 2>&1 || skip "helm missing"
}

# Chart rendered in namespace team; extra arguments go to helm template
render() {
    helm template mysql "$CHART" --namespace team "$@"
}

# Name of the volume claim template of the rendered StatefulSet (stdin)
claim_template() {
    awk '/^  volumeClaimTemplates:/ {f = 1; next} f && /^ *name: / {print $2; exit}'
}

@test "chart devzone-mysql: helm lint" {
    run helm lint "$CHART"
    [ "$status" -eq 0 ]
}

@test "chart devzone-mysql: default values render a StatefulSet and a Service, no Secret" {
    run render
    [ "$status" -eq 0 ]
    [ "$(grep -c '^kind: ' <<<"$output")" -eq 2 ]
    [[ "$output" == *"kind: StatefulSet"* ]] || false
    [[ "$output" == *"kind: Service"* ]] || false
    [[ "$output" != *"kind: Secret"* ]] || false
}

@test "chart devzone-mysql: default values give image mysql:8.4, port 3306, 1Gi, 5Gi, claim donnees" {
    run render --show-only templates/statefulset.yaml
    [ "$status" -eq 0 ]
    [[ "$output" == *"image: mysql:8.4"* ]] || false
    [[ "$output" == *"containerPort: 3306"* ]] || false
    [[ "$output" == *"memory: 1Gi"* ]] || false
    [[ "$output" == *"storage: 5Gi"* ]] || false
    [ "$(claim_template <<<"$output")" = donnees ] || false
    [[ "$output" == *"- name: donnees"* ]] || false

    run render --show-only templates/service.yaml
    [ "$status" -eq 0 ]
    [[ "$output" == *"port: 3306"* ]] || false
    [[ "$output" == *"targetPort: 3306"* ]] || false
}

@test "chart devzone-mysql: --set image, port, memory, size and claim (chart_install path)" {
    sets=(--set image=mysql:9.1 --set port=3307 --set memory=2Gi --set size=10Gi --set claim=data)

    run render "${sets[@]}" --show-only templates/statefulset.yaml
    [ "$status" -eq 0 ]
    [[ "$output" == *"image: mysql:9.1"* ]] || false
    [[ "$output" == *"containerPort: 3306"* ]] || false
    [[ "$output" == *"memory: 2Gi"* ]] || false
    [[ "$output" == *"storage: 10Gi"* ]] || false
    [ "$(claim_template <<<"$output")" = data ] || false
    [[ "$output" == *"- name: data"* ]] || false

    run render "${sets[@]}" --show-only templates/service.yaml
    [ "$status" -eq 0 ]
    [[ "$output" == *"port: 3307"* ]] || false
    [[ "$output" == *"targetPort: 3306"* ]] || false
}

@test "chart devzone-mysql: no namespace written in the chart, the release namespace is used" {
    run render
    [ "$status" -eq 0 ]
    [ "$(grep -c '^  namespace: team$' <<<"$output")" -eq 2 ]
    [[ "$output" != *"namespace: devzone"* ]] || false
}
