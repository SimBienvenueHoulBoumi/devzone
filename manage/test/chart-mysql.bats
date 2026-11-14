#!/usr/bin/env bats
# Chart charts/devzone-mysql (#538): lint, and the same objects as the
# helm-direct manifest .devcontainer/catalogue/mysql/manifeste.yaml with the
# values of app.conf (image mysql:8.4, port 3306, memory 1Gi, size 5Gi,
# claim donnees), so that Argo CD adopts an existing installation without
# change.

setup() {
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CHART="$RACINE/charts/devzone-mysql"
    MANIFEST="$RACINE/.devcontainer/catalogue/mysql/manifeste.yaml"
    command -v helm >/dev/null 2>&1 || skip "helm missing"
}

# Comments, separators and blank lines dropped: the objects alone
objects() {
    grep -vE '^[[:space:]]*(#|---[[:space:]]*$|$)'
}

@test "chart devzone-mysql: helm lint" {
    run helm lint "$CHART"
    [ "$status" -eq 0 ]
}

@test "chart devzone-mysql: renders the objects of manifeste.yaml" {
    rendered="$(helm template mysql "$CHART" --namespace devzone-mysql | objects)"
    expected="$(sed -e 's|__APP__|mysql|g' -e 's|__NS__|devzone-mysql|g' -e 's|__IMAGE__|mysql:8.4|g' \
        -e 's|__PORT__|3306|g' -e 's|__MEMOIRE__|1Gi|g' -e 's|__TAILLE__|5Gi|g' \
        -e 's|__CLAIM__|donnees|g' "$MANIFEST" | objects)"
    [ -n "$rendered" ]
    if [ "$rendered" != "$expected" ]; then
        diff <(printf '%s\n' "$expected") <(printf '%s\n' "$rendered") >&2 || true
        false
    fi
}

@test "chart devzone-mysql: name, image, port, memory and claim come from the values" {
    run helm template mydb "$CHART" --namespace team --set name=mydb --set image=mysql:9.1 \
        --set port=3307 --set memory=2Gi --set size=10Gi --set claim=data
    [ "$status" -eq 0 ]
    [[ "$output" == *"name: mydb"*"port: 3307"* ]] || false
    [[ "$output" == *"image: mysql:9.1"* ]] || false
    [[ "$output" == *"memory: 2Gi"* ]] || false
    [[ "$output" == *"storage: 10Gi"* ]] || false
    [[ "$output" == *"name: data"* ]] || false
    [[ "$output" != *"kind: Secret"* ]] || false
}
