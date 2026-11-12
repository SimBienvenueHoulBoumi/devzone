#!/usr/bin/env bats
# Chart charts/devzone-postgres (#516): lint, and the same objects as the
# helm-direct manifest .devcontainer/postgres/postgres.yaml (POSTGRES_TAILLE
# 5Gi), so that Argo CD adopts an existing installation without change.

setup() {
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CHART="$RACINE/charts/devzone-postgres"
    MANIFEST="$RACINE/.devcontainer/postgres/postgres.yaml"
    command -v helm >/dev/null 2>&1 || skip "helm missing"
}

# Comments, separators and blank lines dropped: the objects alone
objects() {
    grep -vE '^[[:space:]]*(#|---[[:space:]]*$|$)'
}

@test "chart devzone-postgres: helm lint" {
    run helm lint "$CHART"
    [ "$status" -eq 0 ]
}

@test "chart devzone-postgres: renders the objects of postgres.yaml" {
    rendered="$(helm template postgres "$CHART" --namespace devzone-postgres | objects)"
    expected="$(sed 's/__TAILLE__/5Gi/' "$MANIFEST" | objects)"
    [ -n "$rendered" ]
    if [ "$rendered" != "$expected" ]; then
        diff <(printf '%s\n' "$expected") <(printf '%s\n' "$rendered") >&2 || true
        false
    fi
}

@test "chart devzone-postgres: size and image come from the values" {
    run helm template postgres "$CHART" --namespace devzone-postgres --set size=20Gi --set image=postgres:17-alpine
    [ "$status" -eq 0 ]
    [[ "$output" == *"storage: 20Gi"* ]] || false
    [[ "$output" == *"image: postgres:17-alpine"* ]] || false
    [[ "$output" != *"kind: Secret"* ]] || false
}
