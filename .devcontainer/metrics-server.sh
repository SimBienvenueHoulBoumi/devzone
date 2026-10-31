#!/usr/bin/env bash
# Installe metrics-server (CPU/RAM dans k9s, kubectl top) sur les clusters qui
# n'ont pas d'API Metrics. Docker Desktop et kind ne l'ont pas d'office.
# Usage : metrics-server.sh [contexte...] | metrics-server.sh retirer [contexte...]
#        (défaut : clusters locaux joignables ; retirer : ceux où devzone a installé)
# --kubelet-insecure-tls : le kubelet de Docker Desktop et de kind a un
# certificat auto-signé, sans cette option le pod ne devient jamais Ready.
# Sortie en erreur si un contexte demandé est inconnu ou injoignable, ou si
# une installation échoue (kube-config.sh l'appelle avec || true).
set -euo pipefail

VERSION=v0.9.0
MANIFESTE="https://github.com/kubernetes-sigs/metrics-server/releases/download/${VERSION}/components.yaml"

mapfile -t connus < <(kubectl config get-contexts -o name 2>/dev/null || true)

if [ "${1:-}" = retirer ]; then
    shift
    # Retrait (désactivation de kubernetes) : ne retirer que les contextes dont
    # devzone a installé metrics-server (marqueur devzone=installe)
    demandes=$#
    if [ "$demandes" -eq 0 ]; then
        # Clusters locaux seulement : un retrait sur un cluster distant n'a rien
        # à retirer (devzone n'y installe jamais)
        mapfile -t contextes < <(printf '%s\n' ${connus[@]+"${connus[@]}"} |
            grep -E "^(kind-.*|docker-desktop|rancher-desktop|orbstack|minikube)$" || true)
        set -- ${contextes[@]+"${contextes[@]}"}
    fi
    code=0
    for contexte in "$@"; do
        if kubectl --context "$contexte" -n kube-system get deployment metrics-server -l devzone=installe >/dev/null 2>&1; then
            if kubectl --context "$contexte" delete -f "$MANIFESTE" --ignore-not-found >/dev/null 2>&1; then
                echo "metrics-server retiré ($VERSION) : $contexte"
            else
                echo "metrics-server : échec de retrait : $contexte" >&2
                code=1
            fi
        elif kubectl --context "$contexte" -n kube-system get deployment metrics-server >/dev/null 2>&1; then
            # Installé par quelqu'un d'autre : pas à devzone de le retirer
            echo "metrics-server présent sans repère devzone, laissé : $contexte" >&2
        fi
    done
    exit "$code"
fi

demandes=$#
if [ "$demandes" -eq 0 ]; then
    # Clusters locaux seulement : jamais d'install automatique sur un cluster
    # distant de l'hôte (prod, staging…) ; pour un autre, le nommer en argument
    mapfile -t contextes < <(printf '%s\n' ${connus[@]+"${connus[@]}"} |
        grep -E '^(kind-.*|docker-desktop|rancher-desktop|orbstack|minikube)$' || true)
    set -- ${contextes[@]+"${contextes[@]}"}
fi

code=0
joignables=0
for contexte in "$@"; do
    if [ "$demandes" -gt 0 ] && ! printf '%s\n' ${connus[@]+"${connus[@]}"} | grep -qxF -- "$contexte"; then
        echo "metrics-server : contexte inconnu : $contexte (voir kubectl config get-contexts)" >&2
        code=1
        continue
    fi
    k=(kubectl --context "$contexte" --request-timeout=5s)
    if ! "${k[@]}" get --raw /readyz >/dev/null 2>&1; then
        # Sans argument : kind peut être en cours de démarrage, ignoré
        if [ "$demandes" -gt 0 ]; then
            echo "metrics-server : cluster injoignable : $contexte" >&2
            code=1
        fi
        continue
    fi
    joignables=$((joignables + 1))
    if "${k[@]}" get apiservice v1beta1.metrics.k8s.io >/dev/null 2>&1; then
        echo "metrics-server : déjà présent : $contexte"
        continue
    fi
    if "${k[@]}" apply -f "$MANIFESTE" >/dev/null &&
        "${k[@]}" -n kube-system patch deployment metrics-server --type=json \
            -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' >/dev/null &&
        # Marque : make desinstaller ne retire que ce que devzone a installé
        "${k[@]}" -n kube-system label deployment metrics-server devzone=installe app.kubernetes.io/managed-by=devzone --overwrite >/dev/null; then
        echo "metrics-server : installé ($VERSION) : $contexte (métriques dans ~1 min)"
    else
        echo "metrics-server : échec de l'installation : $contexte" >&2
        code=1
    fi
done

if [ "$demandes" -eq 0 ] && [ "$joignables" -eq 0 ]; then
    echo "metrics-server : aucun cluster local joignable ; après kind create cluster : bash .devcontainer/metrics-server.sh"
fi
exit "$code"
