#!/usr/bin/env bash
# Installation MySQL (#440) : secret, manifeste et réinstallation sur un volume.

# Secret admin (mysql-admin) : root.env ou secret existant, jamais régénéré.
mysql_secret() {
    local mdp fichier="$SECRETS/admin-password"
    mkdir -p "$SECRETS"
    chmod 700 "$SECRETS"
    if k get secret mysql-admin >/dev/null 2>&1; then
        mdp="$(k get secret mysql-admin -o jsonpath='{.data.password}' | base64 -d | tr -d '\n')"
        (umask 077 && printf '%s' "$mdp" >"$fichier")
        return 0
    fi
    mdp="$(sed -n 's/^MYSQL_PASSWORD=//p' "$SECRETS/root.env" 2>/dev/null | tail -1 || true)"
    if [ -z "$mdp" ] && [ -s "$fichier" ]; then mdp="$(cat "$fichier")"; fi
    if [ -z "$mdp" ]; then
        (umask 077 && openssl rand -hex 24 | tr -d '\n' >"$fichier")
        k create secret generic mysql-admin --from-file=password="$fichier" >/dev/null
    elif [ ! -s "$fichier" ]; then
        (umask 077 && printf '%s' "$mdp" >"$fichier")
    fi
}

# Applique le manifeste avec le préfixe de claim choisi (#440)
mysql_appliquer_manifeste() {
    local ns="$1" claim="$2"
    sed -e "s|__APP__|mysql|g" -e "s|__NS__|$ns|g" -e "s|__IMAGE__|$MYSQL_IMAGE|g" \
        -e "s|__PORT__|$MYSQL_PORT|g" -e "s|__MEMOIRE__|$MYSQL_MEMOIRE|g" \
        -e "s|__TAILLE__|$MYSQL_TAILLE|g" -e "s|__CLAIM__|$claim|g" \
        "$ICI/manifeste.yaml" | kubectl --context devzone -n "$ns" apply -f - >/dev/null
}

# (Ré)installe MySQL sur le claim demandé, données du PVC gardées (#440)
mysql_installer_claim() {
    local ns="$1" claim="$2" CTX
    CTX="$(contexte)"
    if ! contexte_devzone_poser "$CTX"; then
        echo "devzone : catalogue mysql : impossible de poser le contexte devzone sur $CTX" >&2
        return 1
    fi
    echo "▶ MySQL sur le cluster $CTX (namespace $ns, volume ${claim}-mysql-0)…"
    compte_namespace "$CTX" "$ns"
    namespace_isoler "$ns" >/dev/null
    mysql_secret
    k delete statefulset mysql --ignore-not-found >/dev/null 2>&1 || true
    mysql_appliquer_manifeste "$ns" "$claim"
    if ! k rollout status statefulset/mysql --timeout="${MYSQL_ATTENTE}s" >/dev/null; then
        echo "devzone : catalogue mysql : pas prêt après ${MYSQL_ATTENTE}s : kubectl --context $CTX -n $ns describe pod mysql-0" >&2
        return 1
    fi
    mysql_secret
    relais_lancer mysql "$CTX" "$ns" svc/mysql 3306:3306
    echo "✔ MySQL prêt : 127.0.0.1:$MYSQL_PORT dans le conteneur"
    regenerer_identifiants
}
