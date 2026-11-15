#!/usr/bin/env bash
# CI check of the convention of the devzone charts (#554), documented in the
# section "Charts de devzone" of manage/docs/reference.md. Each folder of
# charts/ is checked: its name, Chart.yaml, then its family, by its
# dependencies: a wrapper (Chart.lock, oci:// recommended) or a service
# (templates without a hard-coded namespace, Secret, Ingress or LoadBalancer,
# the three labels on each object; the common keys in values.yaml). Every
# charts/devzone-<x> named by the code must be a folder. helm lint and helm
# template run when helm is installed. A fault is printed as
# "✖ charts/<x> : <rule>" and the run exits 1; otherwise
# "✔ charts : N charts conformes". Tests: CHARTS_DIR, CHARTS_CODE_DIRS and
# CHARTS_NO_HELM=1. bash 3.2 (macOS).

set -u

ICI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$ICI/../.." && pwd)"
CHARTS_DIR="${CHARTS_DIR:-$ROOT/charts}"
CHARTS_CODE_DIRS="${CHARTS_CODE_DIRS:-$ROOT/.devcontainer $ROOT/manage/scripts}"
# The workstation keeps its own values (per volume, not a shared service)
CHARTS_NO_COMMON="devzone-workspace"
COMMON_KEYS="image size memory port claim resources"
FAULTS=0
COUNT=0

fault() {
    printf '✖ charts/%s : %s\n' "$1" "$2"
    FAULTS=$((FAULTS + 1))
}

# Top-level key of Chart.yaml (file, key), quotes removed
chart_key() {
    sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1 |
        sed -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}

# Chart.yaml: name equal to the folder, type, version (semver), appVersion and
# description not empty
charts_check_chart_yaml() {
    local f="$1/Chart.yaml" name="$2" re='^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]*)?$'
    [ "$(chart_key "$f" name)" = "$name" ] || fault "$name" "Chart.yaml name must be \"$name\""
    [ "$(chart_key "$f" type)" = application ] || fault "$name" "Chart.yaml type must be application"
    [[ "$(chart_key "$f" version)" =~ $re ]] || fault "$name" "Chart.yaml version must be semver"
    [ -n "$(chart_key "$f" appVersion)" ] || fault "$name" "Chart.yaml appVersion must not be empty"
    [ -n "$(chart_key "$f" description)" ] || fault "$name" "Chart.yaml description must not be empty"
}

# Wrapper: Chart.lock committed; a repository outside oci:// is a warning
charts_check_wrapper() {
    local dir="$1" name="$2"
    [ -f "$dir/Chart.lock" ] || fault "$name" "wrapper without Chart.lock (commit it)"
    if grep -E '^[[:space:]]*repository:' "$dir/Chart.yaml" | grep -qv 'oci://'; then
        echo "⚠ charts/$name : a dependency repository is not oci:// (recommended)"
    fi
}

# Service: objects (a kind: line) with the labels, no hard-coded namespace,
# no Secret, no Ingress, no LoadBalancer
charts_check_templates() {
    local dir="$1" name="$2" f rel label
    for f in "$dir"/templates/*.yaml; do
        [ -f "$f" ] || continue
        rel="templates/$(basename "$f")"
        if grep -E '^[[:space:]]*namespace:' "$f" | grep -qv 'Release\.Namespace'; then
            fault "$name" "$rel: namespace must be {{ .Release.Namespace }}, not hard-coded"
        fi
        grep -Eq '^kind:[[:space:]]*Secret' "$f" && fault "$name" "$rel: no Secret in a chart (created apart)"
        grep -Eq '^kind:[[:space:]]*Ingress' "$f" && fault "$name" "$rel: no Ingress in a chart"
        grep -Eq 'type:[[:space:]]*LoadBalancer' "$f" && fault "$name" "$rel: no LoadBalancer in a chart"
        grep -Eq '^kind:' "$f" || continue
        for label in 'app.kubernetes.io/name:' 'app.kubernetes.io/part-of: devzone' 'app.kubernetes.io/managed-by: devzone'; do
            grep -Fq "$label" "$f" || fault "$name" "$rel: label $label missing"
        done
    done
}

# Service: the common keys of values.yaml (the workstation is exempt)
charts_check_values() {
    local dir="$1" name="$2" key
    case " $CHARTS_NO_COMMON " in *" $name "*) return 0 ;; esac
    for key in $COMMON_KEYS; do
        grep -Eq "^$key:" "$dir/values.yaml" || fault "$name" "values.yaml lacks the common key $key"
    done
}

# helm lint and template, on a copy: the wrapper gets its dependency built
# first, with an empty DOCKER_CONFIG (anonymous pull)
charts_check_helm() {
    local dir="$1" name="$2" tmp conf
    [ "${CHARTS_NO_HELM:-0}" = 1 ] && return 0
    command -v helm >/dev/null 2>&1 || return 0
    tmp="$(mktemp -d)" || return 0
    conf="$(mktemp -d)"
    cp -R "$dir" "$tmp/$name"
    if grep -q '^dependencies:' "$dir/Chart.yaml"; then
        DOCKER_CONFIG="$conf" helm dependency build "$tmp/$name" >"$tmp/log" 2>&1 ||
            fault "$name" "helm dependency build fails: $(tail -1 "$tmp/log")"
    fi
    helm lint --quiet "$tmp/$name" >"$tmp/log" 2>&1 || fault "$name" "helm lint fails: $(tail -1 "$tmp/log")"
    DOCKER_CONFIG="$conf" helm template "$name" "$tmp/$name" >/dev/null 2>"$tmp/log" ||
        fault "$name" "helm template fails: $(tail -1 "$tmp/log")"
    rm -rf "$tmp" "$conf"
}

# One folder of charts/
charts_check_dir() {
    local dir="$1" name re='^devzone-[a-z0-9-]+$'
    name="$(basename "$dir")"
    COUNT=$((COUNT + 1))
    [[ "$name" =~ $re ]] || fault "$name" "folder name must match devzone-[a-z0-9-]+"
    if [ ! -f "$dir/Chart.yaml" ]; then
        fault "$name" "Chart.yaml missing"
        return 0
    fi
    [ -f "$dir/values.yaml" ] || fault "$name" "values.yaml missing"
    charts_check_chart_yaml "$dir" "$name"
    if grep -q '^dependencies:' "$dir/Chart.yaml"; then
        charts_check_wrapper "$dir" "$name"
    else
        charts_check_templates "$dir" "$name"
        charts_check_values "$dir" "$name"
    fi
    charts_check_helm "$dir" "$name"
}

# Each charts/devzone-<x> named by the code must be a folder of CHARTS_DIR;
# $svc or $app (variables) are not names and do not match
charts_check_references() {
    local dir hits hit file name
    for dir in $CHARTS_CODE_DIRS; do
        [ -d "$dir" ] || continue
        hits="$(grep -rnoE 'charts/devzone-[a-z0-9-]+' "$dir" 2>/dev/null)" || hits=""
        while IFS= read -r hit; do
            [ -n "$hit" ] || continue
            file="${hit%%:*}"
            name="${hit##*charts/}"
            if [ ! -d "$CHARTS_DIR/$name" ]; then
                fault "$name" "named in $file but the folder is absent"
            fi
        done <<EOF
$hits
EOF
    done
}

if [ ! -d "$CHARTS_DIR" ]; then
    echo "✖ charts : folder not found: $CHARTS_DIR"
    exit 1
fi
for dir in "$CHARTS_DIR"/*/; do
    [ -d "$dir" ] || continue
    charts_check_dir "${dir%/}"
done
charts_check_references
if [ "$FAULTS" -ne 0 ]; then
    exit 1
fi
echo "✔ charts : $COUNT charts conformes"
