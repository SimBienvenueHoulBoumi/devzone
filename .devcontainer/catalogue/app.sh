#!/usr/bin/env bash
# Opérations d'installation du catalogue (#414) : sourcé par catalogue.sh.

# Secret de l'application : mot de passe généré une fois, miroir local
# (workspace/.$app/admin-password, 600, jamais affiché). Reprise : le mot de
# passe déjà là (secret cluster ou root.env) est conservé, jamais régénéré.
app_secret() {
    local app="$1" ns="$2" mdp fichier
    fichier="$RACINE/workspace/.$app/admin-password"
    mkdir -p "$(dirname "$fichier")"
    chmod 700 "$(dirname "$fichier")"
    if kubectl --context devzone -n "$ns" get secret "$app-admin" >/dev/null 2>&1; then
        mdp="$(kubectl --context devzone -n "$ns" get secret "$app-admin" \
            -o jsonpath='{.data.password}' | tr -d '\n')"
        (umask 077 && printf '%s' "$mdp" >"$fichier")
        return 0
    fi
    mdp="$(sed -n 's/^\(MYSQL_\|\)PASSWORD=//p' "$RACINE/workspace/.$app/root.env" 2>/dev/null | tail -1 || true)"
    if [ -z "$mdp" ] && [ -s "$fichier" ]; then mdp="$(cat "$fichier")"; fi
    if [ -z "$mdp" ]; then
        (umask 077 && openssl rand -hex 24 | tr -d '\n' >"$fichier")
    elif [ ! -s "$fichier" ]; then
        (umask 077 && printf '%s' "$mdp" >"$fichier")
    fi
    kubectl --context devzone -n "$ns" create secret generic "$app-admin" \
        --from-file=password="$fichier" >/dev/null
}

# Vue regroupée des identifiants : un échec n'empêche jamais l'opération
regenerer_identifiants() {
    password_regenerer ||
        echo "devzone : catalogue : identifiants regroupés non mis à jour (devzone mots-de-passe)" >&2
}

# Installe une application : contexte devzone posé (#396), namespace créé et
# isolé (#396), secret généré, manifeste appliqué, attente prête, relais lancé
# vers 127.0.0.1:<port> du conteneur ; rend non nul en échec
app_installer() {
    local app="$1" ns port image CTX man
    ns="$(app_ns "$app")"
    port="$(app_lire "$app" port)"
    image="$(app_lire "$app" image)"
    CTX="$(cluster_lu)"
    [ -n "$CTX" ] || refuse "aucun cluster choisi : devzone activer $app"
    if ! contexte_devzone_poser "$CTX"; then
        echo "devzone : catalogue : impossible de poser le contexte devzone sur $CTX" >&2
        return 1
    fi
    echo "▶ Application $app sur le cluster $CTX (namespace $ns)…"
    kubectl --context devzone create namespace "$ns" --dry-run=client -o yaml |
        kubectl --context devzone apply -f - >/dev/null
    kubectl --context devzone label namespace "$ns" "$CLUSTER_ETIQUETTE" --overwrite >/dev/null
    namespace_isoler "$ns" >/dev/null
    app_secret "$app" "$ns"
    man="$(mktemp)"
    sed -e "s|__APP__|$app|g" -e "s|__NS__|$ns|g" -e "s|__IMAGE__|$image|g" \
        -e "s|__PORT__|$port|g" -e "s|__MEMOIRE__|$(app_lire "$app" memoire)|g" \
        -e "s|__TAILLE__|$(app_lire "$app" taille)|g" \
        "$(dossier_catalogue)/$app/manifeste.yaml" >"$man" &&
        kubectl --context devzone -n "$ns" apply -f "$man" >/dev/null
    rm -f "$man"
    if ! kubectl --context devzone -n "$ns" rollout status "statefulset/$app" \
        --timeout="${ATTENTE}s" >/dev/null; then
        echo "devzone : catalogue : $app pas prêt après ${ATTENTE}s" >&2
        return 1
    fi
    relais_lancer "$app" "$CTX" "$ns" "svc/$app" "$port:$port"
    echo "✔ $app prêt : 127.0.0.1:$port dans le conteneur"
    regenerer_identifiants
}

# Désinstalle une application : relais coupé, manifeste retiré, marque oubliée ;
# en terminal, confirmation avant de supprimer les données (PVC), sinon gardées
app_desinstaller() {
    local app="$1" ns reponse
    ns="$(app_ns "$app")"
    relais_arreter "$app"
    rm -f "$(fichier_echec "$app")"
    kubectl --context devzone -n "$ns" delete "statefulset/$app" "service/$app" \
        "secret/$app-admin" >/dev/null 2>&1 || true
    if cluster_interactif; then
        printf 'Supprimer les données de %s (namespace %s) ? [o/N] ' "$app" "$ns" >&2
        read -r reponse || reponse=""
        case "$reponse" in
            o | O | oui)
                kubectl --context devzone delete namespace "$ns" >/dev/null 2>&1 || true
                rm -rf "$RACINE/workspace/.$app"
                ;;
            *) echo "Données de $app gardées (namespace $ns) ; pour les supprimer : devzone desactiver $app" ;;
        esac
    else
        echo "Sans terminal : données de $app gardées (namespace $ns) ; pour les supprimer, dans un terminal : devzone desactiver $app"
    fi
    echo "✔ $app retiré du cluster"
    regenerer_identifiants
}

# Marque d'échec d'une tentative : dernière ligne du message gardée et montrée
app_echec() {
    printf '%s\n' "$2" | tail -1 >"$(fichier_echec "$1")"
    printf '%s\n' "$2" >&2
}

# Comble l'écart entre le voulu et le réel : installe, retire, relance le
# relais permanent ; marque l'échec au premier problème puis passe à la suite
catalogue_appliquer() {
    local app sortie code=0 port CTX ns
    while IFS= read -r app; do
        [ -n "$app" ] || continue
        port="$(app_lire "$app" port)"
        if [ "$(voulu "$app")" != on ] && presente "$app"; then
            if ! sortie="$(app_desinstaller "$app" 2>&1)"; then
                code=1; app_echec "$app" "$sortie"
            else
                printf '%s\n' "$sortie"
            fi
        elif [ "$(voulu "$app")" = on ] && presente "$app"; then
            if ! app_prete "$app"; then
                code=1
                echo "devzone : catalogue : $app installé mais pas prêt : devzone appliquer" >&2
                echo "pas prêt" >"$(fichier_echec "$app")"
            else
                rm -f "$(fichier_echec "$app")"
            fi
            # Relais permanent : relancé s'il est arrêté
            CTX="$(cluster_lu)" || true
            ns="$(app_ns "$app")"
            if [ -n "$CTX" ]; then
                if ! sortie="$(relais_lancer "$app" "$CTX" "$ns" "svc/$app" "$port:$port" 2>&1)"; then
                    code=1; app_echec "$app" "$sortie"
                else
                    [ -n "$sortie" ] && printf '%s\n' "$sortie"
                fi
            fi
        elif [ "$(voulu "$app")" = on ]; then
            if ! sortie="$(app_installer "$app" 2>&1)"; then
                code=1; app_echec "$app" "$sortie"
            else
                printf '%s\n' "$sortie"
            fi
        fi
    done <<<"$(catalogue_apps)"
    return "$code"
}
