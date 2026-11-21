#!/usr/bin/env bats
# check-charts.sh declares the http(s) repositories of a wrapper's dependencies
# before helm dependency build (#559). A fake helm on PATH logs its calls to
# HELM_LOG (with the helm repository config it was given) and succeeds; the
# real helm is never run here.

setup() {
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$RACINE/manage/scripts/ci/check-charts.sh"
    export CHARTS_DIR="$BATS_TEST_TMPDIR/charts"
    export CHARTS_CODE_DIRS="$BATS_TEST_TMPDIR/code"
    export HELM_LOG="$BATS_TEST_TMPDIR/helm.log"
    mkdir -p "$CHARTS_DIR" "$CHARTS_CODE_DIRS" "$BATS_TEST_TMPDIR/bin"
    cat >"$BATS_TEST_TMPDIR/bin/helm" <<'EOF'
#!/usr/bin/env bash
printf '%s [cfg=%s]\n' "$*" "${HELM_REPOSITORY_CONFIG:-}" >>"$HELM_LOG"
exit 0
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/helm"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    export CHARTS_NO_HELM=0
}

# A wrapper, devzone-wrap, with the given dependencies (the lines after
# "dependencies:" in the Chart.yaml), and its Chart.lock
make_wrapper() {
    local d="$CHARTS_DIR/devzone-wrap"
    mkdir -p "$d"
    cat >"$d/Chart.yaml" <<EOF
apiVersion: v2
name: devzone-wrap
description: Wrapper of the helm repositories tests (#559)
type: application
version: 0.1.0
appVersion: "1.0"
dependencies:
$1
EOF
    printf 'dependencies: []\n' >"$d/Chart.lock"
    printf 'argo-cd: {}\n' >"$d/values.yaml"
}

@test "check-charts helm: two dependencies on one https URL declare the repository once, before the build" {
    make_wrapper '  - name: gitlab
    version: 9.11.16
    repository: https://charts.example.test
  - name: gitlab-runner
    version: 0.88.2
    repository: "https://charts.example.test"'
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(grep -c '^repo add ' "$HELM_LOG")" -eq 1 ]
    grep -q '^repo add devzone-charts-example-test https://charts.example.test --force-update ' "$HELM_LOG"
    grep -q '^repo update devzone-charts-example-test ' "$HELM_LOG"
    add_line="$(grep -n '^repo add ' "$HELM_LOG" | cut -d: -f1)"
    build_line="$(grep -n '^dependency build ' "$HELM_LOG" | cut -d: -f1)"
    [ "$add_line" -lt "$build_line" ]
    [[ "$output" == *"✔ charts : 1 charts conformes"* ]] || false
}

@test "check-charts helm: the repository goes to a temporary config, removed after the check" {
    make_wrapper '  - name: gitlab
    version: 9.11.16
    repository: https://charts.example.test'
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    cfg="$(sed -n 's/^repo add .*\[cfg=\(.*\)\/repositories.yaml\]$/\1/p' "$HELM_LOG" | head -1)"
    [ -n "$cfg" ]
    [ "$cfg" != "${HOME:-/nonexistent}/.config/helm" ]
    [ ! -e "$cfg" ]
}

@test "check-charts helm: an oci:// dependency declares no repository" {
    make_wrapper '  - name: argo-cd
    version: 10.14.0
    repository: oci://ghcr.io/argoproj/argo-helm'
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(grep -c '^repo ' "$HELM_LOG")" -eq 0 ]
    grep -q '^dependency build ' "$HELM_LOG"
}

@test "check-charts helm: a file:// dependency declares no repository" {
    make_wrapper '  - name: local
    version: 0.1.0
    repository: file://../local'
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(grep -c '^repo ' "$HELM_LOG")" -eq 0 ]
}

@test "check-charts helm: two different https URLs get two distinct names" {
    make_wrapper '  - name: a
    version: 1.0.0
    repository: https://charts.example.test/one
  - name: b
    version: 1.0.0
    repository: https://charts.example.test/two'
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(grep -c '^repo add ' "$HELM_LOG")" -eq 2 ]
    grep -q '^repo add devzone-charts-example-test-one https://charts.example.test/one ' "$HELM_LOG"
    grep -q '^repo add devzone-charts-example-test-two https://charts.example.test/two ' "$HELM_LOG"
}
