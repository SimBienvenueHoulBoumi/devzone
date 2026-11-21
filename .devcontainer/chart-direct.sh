#!/usr/bin/env bash
# Helm-direct installation of a devzone service (#559, step 7): the chart
# charts/devzone-<svc> of the code tree is the only definition, installed with
# helm on the devzone context as the release <svc> in <ns>. Objects already
# there (kubectl apply of an earlier version, or left by Argo CD when its module
# went away) are adopted first: the annotations and the label helm requires, so
# that the release takes them over without recreating them.
#   chart_install <svc> <ns> [key=value ...]   adoption, then helm upgrade --install
# bash 3.2 (macOS).

# The charts are code: read from the code tree (this file is in .devcontainer/),
# whatever the devzone folder (RACINE, the state) is
CHART_CODE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Adopts the objects of the rendered chart that already exist in <ns>: helm
# refuses an object it does not own, so the release annotations and the
# managed-by label are written on them (no object is recreated)
chart_adopt() {
    local svc="$1" ns="$2" rendu="$3" objets o
    objets="$(kubectl --context devzone -n "$ns" get -f "$rendu" -o name --ignore-not-found 2>/dev/null || true)"
    for o in $objets; do
        kubectl --context devzone -n "$ns" annotate "$o" \
            "meta.helm.sh/release-name=$svc" "meta.helm.sh/release-namespace=$ns" --overwrite >/dev/null
        kubectl --context devzone -n "$ns" label "$o" app.kubernetes.io/managed-by=Helm --overwrite >/dev/null
    done
}

# Installs or upgrades the release <svc> from charts/devzone-<svc>; the
# key=value arguments become --set options (image, port, memory, size, claim)
chart_install() {
    local svc="$1" ns="$2" chart rendu arg
    local -a sets
    shift 2
    chart="$CHART_CODE/charts/devzone-$svc"
    if [ ! -f "$chart/Chart.yaml" ]; then
        echo "✖ $svc : chart charts/devzone-$svc missing (manage/docs/reference.md#devzone-charts)" >&2
        return 2
    fi
    sets=()
    for arg in "$@"; do sets+=(--set "$arg"); done
    rendu="$(mktemp)"
    if ! helm template "$svc" "$chart" -n "$ns" ${sets[@]+"${sets[@]}"} >"$rendu"; then
        rm -f "$rendu"
        return 1
    fi
    chart_adopt "$svc" "$ns" "$rendu"
    rm -f "$rendu"
    helm --kube-context devzone upgrade --install "$svc" "$chart" -n "$ns" ${sets[@]+"${sets[@]}"} >/dev/null
}
