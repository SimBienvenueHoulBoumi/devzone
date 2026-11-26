#!/usr/bin/env bash
# Install operations of the catalog (#414): sourced by catalog.sh.
# With the argocd module on, the installed application is an Argo CD Application
# devzone-<app> (chart charts/devzone-<app> of the devzone repository, #538) instead
# of the manifest of the direct helm path.

WAIT_SECONDS="${DEVZONE_CATALOG_WAIT:-300}"

# shellcheck source=SCRIPTDIR/chart-direct.sh
# shellcheck disable=SC1091
. "$ICI/chart-direct.sh"

# Waits for the StatefulSet to be ready: a single rollout command on the manifest
# path, polled on the Argo CD path (the sync runs in the background)
app_wait() {
    local app="$1" ns="$2" argo="$3" end=$((SECONDS + WAIT_SECONDS))
    if [ "$argo" = 1 ]; then
        while [ "$SECONDS" -lt "$end" ]; do
            kubectl --context devzone -n "$ns" rollout status "statefulset/$app" --timeout=10s >/dev/null 2>&1 && return 0
            sleep 5
        done
        echo "devzone : catalog : $app not ready after ${WAIT_SECONDS}s" >&2
        return 1
    fi
    if ! kubectl --context devzone -n "$ns" rollout status "statefulset/$app" \
        --timeout="${WAIT_SECONDS}s" >/dev/null; then
        echo "devzone : catalog : $app not ready after ${WAIT_SECONDS}s" >&2
        return 1
    fi
}

# Application secret: password generated once, local mirror
# (workspace/.$app/admin-password, 600, never shown). Re-run: a password already
# there (cluster secret or root.env) is kept, never regenerated.
app_secret() {
    local app="$1" ns="$2" password file
    file="$RACINE/workspace/.$app/admin-password"
    mkdir -p "$(dirname "$file")"
    chmod 700 "$(dirname "$file")"
    if kubectl --context devzone -n "$ns" get secret "$app-admin" >/dev/null 2>&1; then
        password="$(kubectl --context devzone -n "$ns" get secret "$app-admin" \
            -o jsonpath='{.data.password}' | tr -d '\n')"
        (umask 077 && printf '%s' "$password" >"$file")
        return 0
    fi
    password="$(sed -n 's/^\(MYSQL_\|\)PASSWORD=//p' "$RACINE/workspace/.$app/root.env" 2>/dev/null | tail -1 || true)"
    if [ -z "$password" ] && [ -s "$file" ]; then password="$(cat "$file")"; fi
    if [ -z "$password" ]; then
        (umask 077 && openssl rand -hex 24 | tr -d '\n' >"$file")
    elif [ ! -s "$file" ]; then
        (umask 077 && printf '%s' "$password" >"$file")
    fi
    kubectl --context devzone -n "$ns" create secret generic "$app-admin" \
        --from-file=password="$file" >/dev/null
}

# Grouped view of the credentials: a failure never blocks the operation
regenerer_identifiants() {
    password_regenerate ||
        echo "devzone : catalog : grouped credentials not updated (devzone passwords)" >&2
}

# Installs an application: devzone context set (#396), namespace created and
# isolated (#396), secret generated, then the Argo CD Application (argocd module
# on, #538) or the manifest, wait until ready, relay started to 127.0.0.1:<port>
# of the container; returns non-zero on failure
app_install() {
    local app="$1" ns port image CTX extra="" argo=0
    ns="$(app_namespace "$app")"
    port="$(app_read "$app" port)"
    image="$(app_read "$app" image)"
    CTX="$(cluster_saved)"
    [ -n "$CTX" ] || refuse "no cluster chosen: devzone enable $app"
    if ! devzone_context_set "$CTX"; then
        echo "devzone : catalog : cannot set the devzone context on $CTX" >&2
        return 1
    fi
    echo "▶ Application $app on cluster $CTX (namespace $ns)…"
    # Namespace created and labelled by the administrator (#430), then the limited
    # account allowed in the namespace
    account_admin "$CTX" create namespace "$ns" --dry-run=client -o yaml |
        account_admin "$CTX" apply -f - >/dev/null
    account_admin "$CTX" label namespace "$ns" "$CLUSTER_LABEL" --overwrite >/dev/null
    account_allow "$CTX" "$ns"
    namespace_isolate "$ns" >/dev/null
    app_secret "$app" "$ns"
    local claim=donnees
    if [ "$app" = mysql ]; then
        claim="$(devzone mysql claim "$ns")" || return 2
        [ "$claim" = donnees ] || extra="claim=$claim"
    fi
    if "$ICI/devzone" argocd catalogue-active "$app"; then
        argo=1
        echo "▶ Application $app through Argo CD (chart charts/devzone-$app)…"
        "$ICI/devzone" argocd catalogue-apply "$app" "$ns" "$image" "$port" "$(app_read "$app" memoire)" "$(app_read "$app" taille)" "$extra" || return 1
    else
        # Direct helm: the chart charts/devzone-<app>, the one definition (#559)
        chart_install "$app" "$ns" "image=$image" "port=$port" \
            "memory=$(app_read "$app" memoire)" "size=$(app_read "$app" taille)" "claim=$claim" || return 1
    fi
    app_wait "$app" "$ns" "$argo" || return 1
    relay_start "$app" "$CTX" "$ns" "svc/$app" "$port:$port"
    echo "✔ $app ready: 127.0.0.1:$port in the container"
    regenerer_identifiants
}

# Uninstalls an application: relay stopped, Argo CD Application removed (argocd
# module on, #538) or the manifest, failure marker forgotten. The volume (PVC) and
# the data stay (#441): deleting the data is confirmed apart (devzone mysql delete-data)
app_remove() {
    local app="$1" ns claim pvc CTX
    ns="$(app_namespace "$app")"
    relay_stop "$app"
    rm -f "$(failure_file "$app")"
    # RoleBinding removed by the administrator (#430): the namespace and the volume
    # stay, the account authorization must not linger
    CTX="$(cluster_saved)" || true
    if [ -n "$CTX" ]; then
        account_remove "$CTX" "$ns" >/dev/null 2>&1 || true
    fi
    claim="$(kubectl --context devzone -n "$ns" get statefulset "$app" \
        -o jsonpath='{.spec.volumeClaimTemplates[0].metadata.name}' 2>/dev/null || true)"
    if "$ICI/devzone" argocd catalogue-application-exists "$app"; then
        "$ICI/devzone" argocd catalogue-delete "$app" >/dev/null 2>&1 || true
        kubectl --context devzone -n "$ns" delete "secret/$app-admin" >/dev/null 2>&1 || true
        pvc="${claim:-donnees}-$app-0"
        echo "✔ $app removed: Application deleted; volume $pvc and databases kept: devzone $app volume"
        regenerer_identifiants
        return 0
    fi
    kubectl --context devzone -n "$ns" delete "statefulset/$app" "service/$app" \
        "secret/$app-admin" >/dev/null 2>&1 || true
    pvc="${claim:-donnees}-$app-0"
    echo "✔ $app removed from the cluster; volume $pvc and databases kept: devzone $app volume"
    regenerer_identifiants
}

# Failure marker of an attempt: last line of the message kept and shown
app_failure() {
    printf '%s\n' "$2" | tail -1 >"$(failure_file "$1")"
    printf '%s\n' "$2" >&2
}

# Warns about the mysql PVCs not mounted by the StatefulSet (#440). Reading the
# namespaces is reserved to the administrator (#430).
app_unused_mysql_volumes() {
    local ctx ns mounted pvc list
    ctx="$(cluster_saved)"
    [ -n "$ctx" ] || return 0
    ns="$(app_namespace mysql)"
    account_admin "$ctx" get namespace "$ns" >/dev/null 2>&1 || return 0
    mounted="$(kubectl --context devzone -n "$ns" get statefulset mysql -o jsonpath='{.spec.volumeClaimTemplates[0].metadata.name}' 2>/dev/null || true)"
    [ -n "$mounted" ] || return 0
    list="$(kubectl --context devzone -n "$ns" get pvc -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -E '\-mysql-0$' || true)"
    while IFS= read -r pvc; do
        [ -n "$pvc" ] || continue
        [ "$pvc" != "${mounted}-mysql-0" ] || continue
        printf '  ⚠ volume %s not used : devzone mysql volume\n' "$pvc"
    done <<<"$list"
}

# Closes the gap between wanted and actual: installs, removes, restarts the
# permanent relay; marks the first failure then moves on
catalog_apply() {
    local app output code=0 port CTX ns
    while IFS= read -r app; do
        [ -n "$app" ] || continue
        port="$(app_read "$app" port)"
        if [ "$(wanted "$app")" != on ] && present "$app"; then
            if ! output="$(app_remove "$app" 2>&1)"; then
                code=1; app_failure "$app" "$output"
            else
                printf '%s\n' "$output"
            fi
        elif [ "$(wanted "$app")" = on ] && present "$app"; then
            if ! app_ready "$app"; then
                code=1
                echo "devzone : catalog : $app installed but not ready: devzone apply" >&2
                echo "not ready" >"$(failure_file "$app")"
            else
                rm -f "$(failure_file "$app")"
            fi
            # Permanent relay: restarted if stopped
            CTX="$(cluster_saved)" || true
            ns="$(app_namespace "$app")"
            if [ -n "$CTX" ]; then
                if ! output="$(relay_start "$app" "$CTX" "$ns" "svc/$app" "$port:$port" 2>&1)"; then
                    code=1; app_failure "$app" "$output"
                else
                    [ -n "$output" ] && printf '%s\n' "$output"
                fi
            fi
        elif [ "$(wanted "$app")" = on ]; then
            if ! output="$(app_install "$app" 2>&1)"; then
                code=1; app_failure "$app" "$output"
            else
                printf '%s\n' "$output"
            fi
        fi
    done <<<"$(catalog_apps)"
    return "$code"
}
