#!/usr/bin/env bash
# Argo CD of the Kubernetes workspace, driven from the workstation (#516).
# Sourced by manage/workspace.sh (drapeau_kubectl, drapeau_helm, RACINE: the
# package; $PWD: the devzone folder of the workstation, its .devzone.modules,
# workspace/.argocd and .password).
#   argocd_wanted        0 unless .devzone.modules says argocd=off (on by default)
#   argocd_installed     namespace devzone-argocd present
#   argocd_active        wanted and installed: Applications instead of helm direct
#   argocd_ensure        installs it when wanted and missing (workspace start)
#   argocd_install | argocd_uninstall | argocd_status
#   argocd_revision      Git revision of the devzone charts; empty on a dev clone
#   argocd_apply_application / argocd_delete_application
# Why: the pod has no administrator access (#430); the workstation has helm
# and kubectl. The admin password goes to workspace/.argocd/admin.env and
# .password of the workstation, never on screen. bash 3.2 (macOS).

ARGOCD_NS="devzone-argocd"
ARGOCD_CHART_VERSION="${ARGOCD_VERSION:-10.14.0}"
ARGOCD_LOCAL_PORT="${ARGOCD_PORT:-8443}"
ARGOCD_WAIT="${ARGOCD_ATTENTE:-600}"
ARGOCD_MIN_MEMORY_KI=1048576
DEVZONE_REPO_URL="${DEVZONE_REPO_URL:-https://github.com/SimBienvenueHoulBoumi/devzone.git}"

# Wrapper chart installed by the workstation and by the container (#538)
argocd_chart() { printf '%s/charts/devzone-argocd' "$RACINE"; }
argocd_generator() { printf '%s/.devcontainer/argocd/application.sh' "$RACINE"; }
argocd_secrets_dir() { printf '%s/workspace/.argocd' "$PWD"; }

# kubectl of the workstation, context devzone when it exists
ak() {
    # shellcheck disable=SC2046
    kubectl $(drapeau_kubectl) "$@"
}

# Last value of a key of .devzone.modules of the workstation (empty if none)
state_read() {
    grep "^$1=" .devzone.modules 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# key=value written in .devzone.modules of the workstation, other lines kept
state_note() {
    local f=".devzone.modules" tmp
    tmp="$f.tmp.$$"
    {
        if [ -f "$f" ]; then grep -v "^$1=" "$f" || true; fi
        echo "$1=$2"
    } >"$tmp" && mv "$tmp" "$f"
}

argocd_wanted() { [ "$(state_read argocd)" != off ]; }

argocd_installed() { ak get namespace "$ARGOCD_NS" >/dev/null 2>&1; }

argocd_active() { argocd_wanted && argocd_installed; }

# Git revision of the devzone charts: DEVZONE_ARGOCD_REVISION, else the tag of
# the package version; empty on a development clone (0.0.0: the local chart
# is not in Git)
argocd_revision() {
    local version
    if [ -n "${DEVZONE_ARGOCD_REVISION:-}" ]; then
        printf '%s' "$DEVZONE_ARGOCD_REVISION"
        return 0
    fi
    version="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$RACINE/package.json" | head -1)"
    case "$version" in
        '' | 0.0.0) ;;
        *) printf 'v%s' "$version" ;;
    esac
}

# Kubernetes memory quantity in Ki (Ki, Mi, Gi, Ti, K, M, G, bytes)
argocd_quantity_ki() {
    local q="${1:-}" n
    case "$q" in
        *Ki) n="${q%Ki}"; echo $((n)) ;;
        *Mi) n="${q%Mi}"; echo $((n * 1024)) ;;
        *Gi) n="${q%Gi}"; echo $((n * 1024 * 1024)) ;;
        *Ti) n="${q%Ti}"; echo $((n * 1024 * 1024 * 1024)) ;;
        *K | *k) n="${q%[Kk]}"; echo $((n * 1000 / 1024)) ;;
        *M) n="${q%M}"; echo $((n * 1000 * 1000 / 1024)) ;;
        *G) n="${q%G}"; echo $((n * 1000 * 1000 * 1000 / 1024)) ;;
        *)
            case "$q" in
                '' | *[!0-9]*) echo 0 ;;
                *) echo $((q / 1024)) ;;
            esac
            ;;
    esac
}

# Refuses under 1 Gi of allocatable memory in the cluster (sum of the nodes)
argocd_memory_ok() {
    local lines value total=0
    lines="$(ak get nodes -o jsonpath='{range .items[*]}{.status.allocatable.memory}{"\n"}{end}' 2>/dev/null)" || lines=""
    if [ -z "$lines" ]; then
        echo "✖ argocd: cluster unreachable or nodes unreadable (kubectl config get-contexts)" >&2
        return 2
    fi
    while IFS= read -r value; do
        [ -n "$value" ] || continue
        total=$((total + $(argocd_quantity_ki "$value")))
    done <<<"$lines"
    if [ "$total" -lt "$ARGOCD_MIN_MEMORY_KI" ]; then
        echo "✖ argocd: at least 1 Gi of allocatable memory is needed in the cluster (available: $((total / 1024)) Mi); enlarge the cluster (Docker Desktop → Settings → Resources), then: devzone workspace services enable argocd" >&2
        return 2
    fi
}

# Initial admin password, read with kubectl (go-template base64decode: no
# base64 of the workstation involved), written in workspace/.argocd/admin.env
# (600) and in .password; never printed
argocd_save_admin_password() {
    local dir password
    dir="$(argocd_secrets_dir)"
    password="$(ak -n "$ARGOCD_NS" get secret argocd-initial-admin-secret \
        -o go-template='{{.data.password | base64decode}}' 2>/dev/null)" || password=""
    if [ -z "$password" ]; then
        echo "⚠ argocd: admin password unreadable (secret argocd-initial-admin-secret); .password not updated" >&2
        return 0
    fi
    mkdir -p "$dir"
    chmod 700 "$dir"
    (
        umask 077
        printf 'ARGOCD_URL=https://localhost:%s\nARGOCD_USER=admin\nARGOCD_PASSWORD=%s\n' "$ARGOCD_LOCAL_PORT" "$password" >"$dir/admin.env"
    )
    chmod 600 "$dir/admin.env"
    argocd_passwords_refresh
}

# .password of the workstation regenerated from workspace/.*/ (password.sh of the package)
argocd_passwords_refresh() {
    DEVZONE_RACINE="$PWD" bash "$RACINE/.devcontainer/password.sh" regenerer 2>/dev/null ||
        echo "⚠ .password not updated (bash .devcontainer/password.sh regenerer)" >&2
}

# Installs Argo CD (pinned chart and values), idempotent (upgrade --install)
argocd_install() {
    argocd_memory_ok || return 2
    echo "▶ Argo CD $ARGOCD_CHART_VERSION in $ARGOCD_NS (helm, up to ${ARGOCD_WAIT}s)…"
    ak create namespace "$ARGOCD_NS" --dry-run=client -o yaml | ak apply -f - >/dev/null
    ak label namespace "$ARGOCD_NS" app.kubernetes.io/managed-by=devzone --overwrite >/dev/null
    # Wrapper chart: the dependency argo-cd (pinned in Chart.yaml) is built
    # first, then installed from the local chart (#538)
    helm dependency build "$(argocd_chart)" >/dev/null
    # shellcheck disable=SC2046
    helm $(drapeau_helm) upgrade --install argocd "$(argocd_chart)" \
        --namespace "$ARGOCD_NS" \
        --timeout "${ARGOCD_WAIT}s" --wait || return 1
    argocd_save_admin_password
    echo "✔ Argo CD ready: https://localhost:$ARGOCD_LOCAL_PORT once devzone workspace ports runs; user admin, password in .password"
}

# Installs it when wanted and missing (workspace start); a refusal (memory)
# is told and the start goes on with helm direct
argocd_ensure() {
    argocd_wanted || return 0
    argocd_installed && return 0
    argocd_install || echo "⚠ Argo CD not installed: the workspace is deployed with helm directly (devzone workspace services enable argocd to retry)" >&2
    return 0
}

# Applications removed without cascade (finalizer dropped first: the services
# stay, under helm direct; the GitOps repository keeps its files), then helm
# uninstall and the namespace
argocd_uninstall() {
    local app
    if argocd_installed; then
        echo "▶ Argo CD removal: Applications released (their resources stay), release and namespace deleted…"
        while IFS= read -r app; do
            [ -n "$app" ] || continue
            gitops_direct_delete_application "${app#*/}" keep
        done <<<"$(ak -n "$ARGOCD_NS" get applications.argoproj.io -o name 2>/dev/null || true)"
        # shellcheck disable=SC2046
        helm $(drapeau_helm) uninstall argocd --namespace "$ARGOCD_NS" >/dev/null 2>&1 || true
        ak delete namespace "$ARGOCD_NS" --wait=true --ignore-not-found >/dev/null
    fi
    rm -rf "$(argocd_secrets_dir)"
    argocd_passwords_refresh
    echo "✔ Argo CD removed; the services stay, under helm direct"
}

# Applies the Application <name> of <kind> to <namespace> from <repo> at
# <revision>, <path>; the other arguments are Helm parameters key=value.
# In the GitOps repository when one is designated (gitops.sh), else directly
argocd_apply_application() {
    gitops_apply_application "$@"
}

# Deletes an Application (and its file of the GitOps repository); keep:
# finalizer dropped first, its resources stay
argocd_delete_application() {
    gitops_delete_application "$@"
}

argocd_application_exists() {
    ak -n "$ARGOCD_NS" get application.argoproj.io "$1" >/dev/null 2>&1
}

# Installed or not, then the Applications with their sync and health status
argocd_status() {
    if ! argocd_installed; then
        echo "○ argocd not installed: devzone workspace services enable argocd"
        return 0
    fi
    if argocd_wanted; then
        echo "✔ argocd installed: https://localhost:$ARGOCD_LOCAL_PORT (devzone workspace ports), user admin, password in .password"
    else
        echo "⚠ argocd installed but argocd=off in .devzone.modules: devzone workspace services enable argocd, or disable to remove it"
    fi
    if gitops_enabled; then
        echo "  GitOps repository: $(gitops_repo) (apps/, root Application $GITOPS_ROOT_APP)"
    else
        echo "  no GitOps repository: Applications applied directly (devzone workspace argocd init)"
    fi
    ak -n "$ARGOCD_NS" get applications.argoproj.io \
        -o custom-columns='APPLICATION:.metadata.name,KIND:.metadata.labels.devzone\.io/kind,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.spec.source.targetRevision' \
        2>/dev/null | sed 's/^/  /'
    return 0
}
