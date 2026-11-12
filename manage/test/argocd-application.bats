#!/usr/bin/env bats
# Argo CD Application manifests of devzone (#516): application.sh prints the
# manifest, nothing is applied here.

setup() {
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    GEN="$RACINE/.devcontainer/argocd/application.sh"
}

@test "application: automated sync, finalizer, destination and source" {
    run bash "$GEN" devzone-postgres service devzone-postgres https://github.com/x/devzone.git v1.2.3 charts/devzone-postgres
    [ "$status" -eq 0 ]
    [[ "$output" == *"apiVersion: argoproj.io/v1alpha1"* ]] || false
    [[ "$output" == *"kind: Application"* ]] || false
    [[ "$output" == *"  name: devzone-postgres"* ]] || false
    [[ "$output" == *"  namespace: devzone-argocd"* ]] || false
    [[ "$output" == *"devzone.io/kind: service"* ]] || false
    [[ "$output" == *"app.kubernetes.io/managed-by: devzone"* ]] || false
    [[ "$output" == *"- resources-finalizer.argocd.argoproj.io"* ]] || false
    [[ "$output" == *"repoURL: https://github.com/x/devzone.git"* ]] || false
    [[ "$output" == *"targetRevision: v1.2.3"* ]] || false
    [[ "$output" == *"path: charts/devzone-postgres"* ]] || false
    [[ "$output" == *"server: https://kubernetes.default.svc"* ]] || false
    [[ "$output" == *"    namespace: devzone-postgres"* ]] || false
    [[ "$output" == *"prune: true"* ]] || false
    [[ "$output" == *"selfHeal: true"* ]] || false
    [[ "$output" == *"- CreateNamespace=true"* ]] || false
    [[ "$output" != *"helm:"* ]] || false
}

@test "application: Helm parameters, one per key=value" {
    run bash "$GEN" devzone-workspace workspace devzone-workspace https://x/devzone.git main charts/devzone-workspace image.tag=latest image.pullPolicy=Always
    [ "$status" -eq 0 ]
    [[ "$output" == *"    helm:"*"      parameters:"* ]] || false
    [[ "$output" == *"- name: image.tag"*'value: "latest"'* ]] || false
    [[ "$output" == *"- name: image.pullPolicy"*'value: "Always"'* ]] || false
    run bash "$GEN" devzone-workspace workspace devzone-workspace https://x/devzone.git main charts/devzone-workspace image.tag
    [ "$status" -eq 2 ]
    [[ "$output" == *"parameter without value: image.tag"* ]] || false
}

@test "application: usage, unknown kind and invalid name refused" {
    run bash "$GEN" only three args
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage:"* ]] || false
    run bash "$GEN" x other ns https://x r p
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown kind: other"* ]] || false
    run bash "$GEN" "Bad Name" project ns https://x r p
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid name"* ]] || false
    run bash "$GEN" -x project ns https://x r p
    [ "$status" -eq 2 ]
}
