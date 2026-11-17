#!/usr/bin/env bats
# yaml_valid (agent-pod-racine.bash, #222): checks a Pod manifest with Ruby or
# PyYAML, without any cluster. Each test skips when neither parser exists.

load agent-pod-racine

# Writes the stdin to <test tmp>/<name> and returns the path.
ecrire_yaml() {
    local file="$BATS_TEST_TMPDIR/$1"
    cat >"$file"
    echo "$file"
}

# Skips the test when no YAML parser is installed (yaml_valid returns 3).
sans_parser_skip() {
    [ "$status" -ne 3 ] || skip "neither ruby nor PyYAML : yaml_valid not tested"
}

@test "yaml_valid : a valid Pod is accepted" {
    file="$(ecrire_yaml ok.yaml <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: dz-222
spec:
  containers:
  - name: agent
    image: busybox
YAML
)"
    run yaml_valid "$file"
    sans_parser_skip
    [ "$status" -eq 0 ]
}

@test "yaml_valid : broken YAML is refused" {
    file="$(ecrire_yaml broken.yaml <<'YAML'
apiVersion: v1
kind: Pod
metadata: [unclosed
  name: "dz-222
YAML
)"
    run yaml_valid "$file"
    sans_parser_skip
    [ "$status" -eq 1 ]
}

@test "yaml_valid : a document that is not a Pod is refused" {
    file="$(ecrire_yaml deploy.yaml <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dz-222
spec:
  containers:
  - name: agent
YAML
)"
    run yaml_valid "$file"
    sans_parser_skip
    [ "$status" -eq 1 ]
}

@test "yaml_valid : a Pod without metadata.name is refused" {
    file="$(ecrire_yaml noname.yaml <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  labels:
    app: dz
spec:
  containers:
  - name: agent
YAML
)"
    run yaml_valid "$file"
    sans_parser_skip
    [ "$status" -eq 1 ]
}

@test "yaml_valid : a Pod without containers is refused" {
    file="$(ecrire_yaml nocontainers.yaml <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: dz-222
spec:
  containers: []
YAML
)"
    run yaml_valid "$file"
    sans_parser_skip
    [ "$status" -eq 1 ]
}
