#!/usr/bin/env bats
# Convention of the devzone charts (#554): manage/scripts/check-charts.sh on
# fake charts under BATS_TEST_TMPDIR (CHARTS_DIR), never on the real charts
# (that is the CI's job). helm is not run here (CHARTS_NO_HELM=1).

setup() {
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$RACINE/manage/scripts/check-charts.sh"
    export CHARTS_DIR="$BATS_TEST_TMPDIR/charts"
    export CHARTS_CODE_DIRS="$BATS_TEST_TMPDIR/code"
    export CHARTS_NO_HELM=1
    mkdir -p "$CHARTS_DIR" "$CHARTS_CODE_DIRS"
    good_service
}

# A conforming service chart, devzone-demo: every rule satisfied
good_service() {
    local d="$CHARTS_DIR/devzone-demo"
    mkdir -p "$d/templates"
    cat >"$d/Chart.yaml" <<'EOF'
apiVersion: v2
name: devzone-demo
description: Demo service of the convention tests (#554)
type: application
version: 0.1.0
appVersion: "1.0"
EOF
    cat >"$d/values.yaml" <<'EOF'
image: demo:1.0
size: 1Gi
memory: 256Mi
port: 8080
claim: donnees
resources:
  requests:
    cpu: 100m
EOF
    cat >"$d/templates/service.yaml" <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: demo
  namespace: {{ .Release.Namespace }}
  labels:
    app.kubernetes.io/name: demo
    app.kubernetes.io/part-of: devzone
    app.kubernetes.io/managed-by: devzone
spec:
  ports:
    - port: {{ .Values.port }}
EOF
}

# A conforming wrapper chart, devzone-wrap: dependency, Chart.lock, values under the key
good_wrapper() {
    local d="$CHARTS_DIR/devzone-wrap"
    mkdir -p "$d"
    cat >"$d/Chart.yaml" <<'EOF'
apiVersion: v2
name: devzone-wrap
description: Wrapper of the convention tests (#554)
type: application
version: 0.1.0
appVersion: "3.3.0"
dependencies:
  - name: argo-cd
    version: 10.14.0
    repository: oci://ghcr.io/argoproj/argo-helm
EOF
    printf 'dependencies: []\n' >"$d/Chart.lock"
    printf 'argo-cd:\n  dex:\n    enabled: false\n' >"$d/values.yaml"
}

# Replaces one line of a file of the fake service chart (sed on the copy)
edit_demo() {
    sed -i "$2" "$CHARTS_DIR/devzone-demo/$1"
}

@test "check-charts: conforming charts pass" {
    good_wrapper
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"✔ charts : 2 charts conformes"* ]] || false
}

@test "check-charts: a name different from the folder is refused" {
    edit_demo Chart.yaml 's/^name: devzone-demo/name: demo/'
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *'✖ charts/devzone-demo : Chart.yaml name must be "devzone-demo"'* ]] || false
}

@test "check-charts: a folder outside devzone-[a-z0-9-]+ is refused" {
    mv "$CHARTS_DIR/devzone-demo" "$CHARTS_DIR/devzone_demo"
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"✖ charts/devzone_demo : folder name must match devzone-[a-z0-9-]+"* ]] || false
}

@test "check-charts: type other than application is refused" {
    edit_demo Chart.yaml 's/^type: application/type: library/'
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Chart.yaml type must be application"* ]] || false
}

@test "check-charts: a version that is not semver is refused" {
    edit_demo Chart.yaml 's/^version: 0.1.0/version: one/'
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Chart.yaml version must be semver"* ]] || false
}

@test "check-charts: an empty appVersion or description is refused" {
    edit_demo Chart.yaml 's/^appVersion: .*/appVersion: ""/'
    edit_demo Chart.yaml '/^description:/d'
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"appVersion must not be empty"* ]] || false
    [[ "$output" == *"description must not be empty"* ]] || false
}

@test "check-charts: a label missing from an object is refused" {
    edit_demo templates/service.yaml '/app.kubernetes.io\/part-of/d'
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"templates/service.yaml: label app.kubernetes.io/part-of: devzone missing"* ]] || false
}

@test "check-charts: a hard-coded namespace is refused" {
    edit_demo templates/service.yaml 's/namespace: {{ .Release.Namespace }}/namespace: devzone-demo/'
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"namespace must be {{ .Release.Namespace }}, not hard-coded"* ]] || false
}

@test "check-charts: a Secret in a template is refused" {
    printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: demo-admin\n' >"$CHARTS_DIR/devzone-demo/templates/secret.yaml"
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"templates/secret.yaml: no Secret in a chart"* ]] || false
}

@test "check-charts: an Ingress or a LoadBalancer is refused" {
    edit_demo templates/service.yaml 's/^spec:/spec:\n  type: LoadBalancer/'
    printf 'apiVersion: networking.k8s.io/v1\nkind: Ingress\nmetadata:\n  name: demo\n' >"$CHARTS_DIR/devzone-demo/templates/ingress.yaml"
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no LoadBalancer in a chart"* ]] || false
    [[ "$output" == *"templates/ingress.yaml: no Ingress in a chart"* ]] || false
}

@test "check-charts: a common key missing from values.yaml is refused" {
    edit_demo values.yaml '/^claim:/d'
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"values.yaml lacks the common key claim"* ]] || false
}

@test "check-charts: a wrapper without Chart.lock is refused" {
    good_wrapper
    rm "$CHARTS_DIR/devzone-wrap/Chart.lock"
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"✖ charts/devzone-wrap : wrapper without Chart.lock"* ]] || false
}

@test "check-charts: a dependency outside oci:// is a warning, not a fault" {
    good_wrapper
    sed -i 's|oci://ghcr.io/argoproj/argo-helm|https://argoproj.github.io/argo-helm|' "$CHARTS_DIR/devzone-wrap/Chart.yaml"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"⚠ charts/devzone-wrap : a dependency repository is not oci://"* ]] || false
}

@test "check-charts: a code reference to a missing chart is refused" {
    printf 'helm install x charts/devzone-absent\n' >"$CHARTS_CODE_DIRS/appli.sh"
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"✖ charts/devzone-absent : named in"*"but the folder is absent"* ]] || false
}

@test "check-charts: a code reference to an existing chart, or a variable, passes" {
    printf 'charts/devzone-demo\ncharts/devzone-$svc\n' >"$CHARTS_CODE_DIRS/appli.sh"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "check-charts: a missing charts folder is refused" {
    CHARTS_DIR="$BATS_TEST_TMPDIR/absent" run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"folder not found"* ]] || false
}

@test "check-charts: the charts of the repository conform (helm not run here)" {
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    run env -u CHARTS_DIR -u CHARTS_CODE_DIRS CHARTS_NO_HELM=1 bash "$RACINE/manage/scripts/check-charts.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"✔ charts : 5 charts conformes"* ]] || false
}
