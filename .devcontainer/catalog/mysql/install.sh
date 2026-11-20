#!/usr/bin/env bash
# MySQL installation (#440): secret, chart and reinstallation on a volume.
# shellcheck source=SCRIPTDIR/../../chart-direct.sh
# shellcheck disable=SC1091
. "$ICI/../../chart-direct.sh"

# Admin secret (mysql-admin): root.env or existing secret, never regenerated.
mysql_secret() {
    local password file="$SECRETS/admin-password"
    mkdir -p "$SECRETS"
    chmod 700 "$SECRETS"
    if k get secret mysql-admin >/dev/null 2>&1; then
        password="$(k get secret mysql-admin -o jsonpath='{.data.password}' | base64 -d | tr -d '\n')"
        (umask 077 && printf '%s' "$password" >"$file")
        return 0
    fi
    password="$(sed -n 's/^MYSQL_PASSWORD=//p' "$SECRETS/root.env" 2>/dev/null | tail -1 || true)"
    if [ -z "$password" ] && [ -s "$file" ]; then password="$(cat "$file")"; fi
    if [ -z "$password" ]; then
        (umask 077 && openssl rand -hex 24 | tr -d '\n' >"$file")
        k create secret generic mysql-admin --from-file=password="$file" >/dev/null
    elif [ ! -s "$file" ]; then
        (umask 077 && printf '%s' "$password" >"$file")
    fi
}

# Wait for the StatefulSet created by Argo CD (#538): the sync runs in the
# background, the rollout is polled up to MYSQL_ATTENTE
mysql_wait() {
    local end=$((SECONDS + MYSQL_ATTENTE))
    while [ "$SECONDS" -lt "$end" ]; do
        if k rollout status statefulset/mysql --timeout=10s >/dev/null 2>&1; then
            return 0
        fi
        sleep 5
    done
    echo "devzone : catalog mysql : not ready after ${MYSQL_ATTENTE}s: kubectl --context $1 -n $NS describe pod mysql-0" >&2
    return 1
}

# MySQL installation by Argo CD (#538): Application devzone-mysql (chart
# charts/devzone-mysql of the devzone repository), namespace and secret created
# apart; the claim follows the existing volumes, as the manifest path does
mysql_install_argocd() {
    local CTX="$1" claim extra=""
    mysql_secret
    claim="$(mysql_claim_choose "$NS")" || return 2
    [ "$claim" = donnees ] || extra="claim=$claim"
    catalogue_argocd_apply mysql "$NS" "$MYSQL_IMAGE" "$MYSQL_PORT" \
        "$MYSQL_MEMOIRE" "$MYSQL_TAILLE" "$extra" || return 1
    mysql_wait "$CTX" || return 1
    mysql_secret
    relay_start mysql "$CTX" "$NS" svc/mysql 3306:3306
    echo "✔ MySQL ready: 127.0.0.1:$MYSQL_PORT in the container"
    regenerer_identifiants
}

# Installs the chart charts/devzone-mysql with the chosen claim (#440, #559)
mysql_apply_chart() {
    local ns="$1" claim="$2"
    chart_install mysql "$ns" "image=$MYSQL_IMAGE" "port=$MYSQL_PORT" \
        "memory=$MYSQL_MEMOIRE" "size=$MYSQL_TAILLE" "claim=$claim"
}

# (Re)installs MySQL on the requested claim, PVC data kept (#440)
mysql_install_claim() {
    local ns="$1" claim="$2" CTX
    CTX="$(module_context)"
    if ! devzone_context_set "$CTX"; then
        echo "devzone : catalog mysql : cannot set the devzone context on $CTX" >&2
        return 1
    fi
    echo "▶ MySQL on cluster $CTX (namespace $ns, volume ${claim}-mysql-0)…"
    account_namespace "$CTX" "$ns"
    namespace_isolate "$ns" >/dev/null
    mysql_secret
    k delete statefulset mysql --ignore-not-found >/dev/null 2>&1 || true
    mysql_apply_chart "$ns" "$claim" || return 1
    if ! k rollout status statefulset/mysql --timeout="${MYSQL_ATTENTE}s" >/dev/null; then
        echo "devzone : catalog mysql : not ready after ${MYSQL_ATTENTE}s: kubectl --context $CTX -n $ns describe pod mysql-0" >&2
        return 1
    fi
    mysql_secret
    relay_start mysql "$CTX" "$ns" svc/mysql 3306:3306
    echo "✔ MySQL ready: 127.0.0.1:$MYSQL_PORT in the container"
    regenerer_identifiants
}
