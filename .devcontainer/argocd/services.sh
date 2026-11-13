#!/usr/bin/env bash
# The services of devzone held by Argo CD (#538): postgres, mysql, gitlab,
# declared in the [services] section of .argocd.conf (conf.sh):
#   [services]
#       postgres = on
#       mysql = off
# One Application devzone-<svc> per service on: the chart charts/devzone-<svc>
# of the devzone repository at the revision (gitops.sh). Before it, the
# namespace devzone-<svc> (labelled, isolated by a NetworkPolicy) and the
# secret of the service (superuser password generated or re-read, mirrored in
# workspace/.<svc>/ and .password) are created apart, out of Git.
# A service off: the Application leaves with its resources, the namespace and
# the volumes stay; the data removal stays the explicit command
#   devzone workspace services disable <svc> --yes
# The lines <svc>=on|off of .devzone.modules are read in compatibility when
# the [services] section does not hold the service yet.
#   services_reconcile                 every service applied or released
#   services_state_of <svc>            on | off | empty (not declared)
#   services_note <svc> on|off         writes the [services] section
# Sourced after conf.sh and gitops.sh by the workstation
# (manage/scripts/argocd-services.sh) and by the container (argocd.sh). The
# includer defines argocd_kubectl, APPS_GENERATOR, ARGOCD_CONF and
# ARGOCD_CONF_DIR (the devzone folder: relative paths there), DEVZONE_REPO_URL
# and argocd_revision, the secret hook of each service
#   services_secret_<svc>   secret created apart, mirrored, never printed
# and may extend SERVICES_LIST (default: postgres) and define the parameters
# hook services_chart_<svc> (helm parameters on stdout). bash 3.2 (macOS).

: "${SERVICES_LIST:=postgres}"

# Names of the Application and of the namespace of a service
services_app_of() { printf 'devzone-%s' "$1"; }
services_ns_of() { printf 'devzone-%s' "$1"; }

# State of a service: [services] of .argocd.conf first, then the line
# <svc>=on|off of .devzone.modules (compatibility, #538); empty when neither
# holds the service
services_state_of() {
    local svc="$1" v line
    v="$(conf_get services "$svc")"
    case "$v" in on | off) printf '%s' "$v"; return 0 ;; esac
    [ -f "$ARGOCD_CONF_DIR/.devzone.modules" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        line="$(conf_trim "$line")"
        case "$line" in
            "$svc=on" | "$svc=off") printf '%s' "${line#*=}"; return 0 ;;
        esac
    done <"$ARGOCD_CONF_DIR/.devzone.modules"
    return 0
}

# The [services] section rewritten with the new state of <svc>, the keys of
# the other services kept
services_note() {
    local svc="$1" state="$2" s k v
    set --
    while IFS="$(printf '\t')" read -r s k v; do
        [ "$s" = services ] || continue
        [ "$k" = "$svc" ] && continue
        set -- "$@" "$k=$v"
    done <<<"$(conf_entries)"
    set -- "$@" "$svc=$state"
    conf_set services "$@"
}

# Namespace devzone-<svc>: labelled and isolated like the other devzone-*
# namespaces (same rule as the helm-direct installers)
services_namespace_prepare() {
    local ns
    ns="$(services_ns_of "$1")"
    argocd_kubectl create namespace "$ns" --dry-run=client -o yaml | argocd_kubectl apply -f - >/dev/null
    argocd_kubectl label namespace "$ns" app.kubernetes.io/managed-by=devzone --overwrite >/dev/null
    argocd_kubectl -n "$ns" apply -f - >/dev/null <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: devzone-meme-namespace
  labels:
    app.kubernetes.io/managed-by: devzone
spec:
  podSelector: {}
  ingress:
  - from:
    - podSelector: {}
EOF
}

# The Application devzone-<svc>: chart charts/devzone-<svc> of the devzone
# repository at the revision; the parameters hook adds helm parameters
services_application_apply() {
    local svc="$1"
    set -- "$(services_app_of "$svc")" service "$(services_ns_of "$svc")" \
        "$DEVZONE_REPO_URL" "$(argocd_revision)" "charts/devzone-$svc"
    if command -v "services_chart_$svc" >/dev/null 2>&1; then
        # shellcheck disable=SC2046
        set -- "$@" $("services_chart_$svc")
    fi
    gitops_apply_application "$@"
}

# A service off: the Application leaves with its resources, the namespace and
# the volumes stay (--yes of the disable command removes the data)
services_application_delete() {
    gitops_delete_application "$(services_app_of "$1")"
}

# Every service of the list applied or released: on → namespace, secret and
# Application; off → Application removed (namespace and volumes kept); not
# declared: untouched. One failing service does not stop the others
services_reconcile() {
    local svc state code=0
    for svc in $SERVICES_LIST; do
        state="$(services_state_of "$svc")"
        case "$state" in
            on)
                services_namespace_prepare "$svc" || code=1
                if command -v "services_secret_$svc" >/dev/null 2>&1; then
                    "services_secret_$svc" || code=1
                else
                    echo "✖ no secret hook for $svc (services_secret_$svc): the sync will fail" >&2
                    code=1
                fi
                services_application_apply "$svc" || code=1
                echo "✔ Application $(services_app_of "$svc") declared (chart charts/devzone-$svc)"
                ;;
            off)
                services_application_delete "$svc" || code=1
                echo "✔ Application $(services_app_of "$svc") removed (namespace and volumes kept)"
                ;;
        esac
    done
    return "$code"
}
