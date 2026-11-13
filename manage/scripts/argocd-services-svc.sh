#!/usr/bin/env bash
# Service hooks of the workstation for services.sh (#538): secrets created
# apart (postgres-admin, mysql-admin, mirrored and never printed), Helm
# parameters of the mysql chart (existing volume claim), and the
# devzone workspace services enable|disable switch when Argo CD holds the
# charts. Sourced by manage/scripts/argocd-services.sh. bash 3.2 (macOS).

# Namespace of the service: labelled, isolated like the other devzone-*
# (services.sh: services_namespace_prepare)

# Superuser secret postgres-admin, created apart: an existing secret is kept
# and mirrored; otherwise a password generated on the workstation. Mirror
# workspace/.postgres/admin-password (600) and .password; never printed
services_secret_postgres() {
    local dir="$PWD/workspace/.postgres" file password
    file="$dir/admin-password"
    mkdir -p "$dir"
    chmod 700 "$dir"
    password="$(ak -n "$POSTGRES_NS" get secret postgres-admin \
        -o go-template='{{.data.password | base64decode}}' 2>/dev/null)" || password=""
    if [ -n "$password" ]; then
        (umask 077 && printf '%s' "$password" >"$file")
    else
        if [ ! -s "$file" ]; then
            (umask 077 && openssl rand -hex 24 | tr -d '\n' >"$file")
        fi
        ak -n "$POSTGRES_NS" create secret generic postgres-admin --from-file=password="$file" >/dev/null
    fi
    chmod 600 "$file"
    argocd_passwords_refresh
}

# Superuser secret mysql-admin, created apart, the same way; the mirror
# workspace/.mysql/admin-password feeds the mysql entry of .password
services_secret_mysql() {
    local dir="$PWD/workspace/.mysql" file password
    file="$dir/admin-password"
    mkdir -p "$dir"
    chmod 700 "$dir"
    password="$(ak -n "$MYSQL_NS" get secret mysql-admin \
        -o go-template='{{.data.password | base64decode}}' 2>/dev/null)" || password=""
    if [ -n "$password" ]; then
        (umask 077 && printf '%s' "$password" >"$file")
    else
        if [ ! -s "$file" ]; then
            (umask 077 && openssl rand -hex 24 | tr -d '\n' >"$file")
        fi
        ak -n "$MYSQL_NS" create secret generic mysql-admin --from-file=password="$file" >/dev/null
    fi
    chmod 600 "$file"
    argocd_passwords_refresh
}

# Values of the MySQL chart: image, port, memory and size (catalogue defaults),
# and the claim to mount chosen among the existing volumes (one PVC *-mysql-0:
# its prefix; none: the chart default donnees; several: refused)
services_chart_mysql() {
    local liste claim=""
    liste="$(ak -n "$MYSQL_NS" get pvc -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -E '\-mysql-0$' || true)"
    if [ -n "$liste" ]; then
        if [ "$(printf '%s\n' "$liste" | grep -c .)" -gt 1 ]; then
            echo "✖ several MySQL volumes in $MYSQL_NS: devzone mysql volume <name> picks the mounted one" >&2
            return 2
        fi
        claim=" claim=${liste%-mysql-0}"
    fi
    printf 'image=mysql:8.4 port=3306 memory=1Gi size=5Gi%s' "$claim"
}

# devzone workspace services enable|disable postgres|mysql when Argo CD holds
# the charts: the [services] section written, then reconciled (services.sh).
# disable keeps the namespace, the volumes and the data; --yes is the explicit
# data removal (namespace deleted; the mirror workspace/.mysql stays, like
# supprimer-donnees of the module, the one of .postgres goes)
services_argocd_toggle() {
    local svc="$1" action="$2" yes
    shift 2
    case "$action" in
        enable)
            if [ "$#" -ne 0 ]; then
                echo "✖ $svc through Argo CD takes no option (got: $*)" >&2
                return 1
            fi
            echo "▶ $svc as an Argo CD Application (charts/devzone-$svc at $(argocd_revision))…"
            services_note "$svc" on
            services_reconcile
            echo "✔ Application devzone-$svc declared ([services] $svc = on in $ARGOCD_CONF); status: devzone workspace argocd status; local access: devzone workspace ports"
            ;;
        disable)
            yes="$(yes_flag "services disable $svc [--yes]" "$@")" || return 1
            services_note "$svc" off
            services_reconcile
            if [ "$yes" = 1 ]; then
                ak delete namespace "devzone-$svc" --wait=true --ignore-not-found >/dev/null
                case "$svc" in
                    postgres) rm -rf "$PWD/workspace/.$svc" ;;
                esac
                argocd_passwords_refresh
                echo "✔ $svc removed: Application, namespace devzone-$svc and data ([services] $svc = off)"
            else
                echo "✔ $svc stopped: Application removed, the namespace devzone-$svc, the volumes and the data stay (devzone workspace services disable $svc --yes to remove the data)"
            fi
            ;;
    esac
}

postgres_argocd() { services_argocd_toggle postgres "$@"; }

