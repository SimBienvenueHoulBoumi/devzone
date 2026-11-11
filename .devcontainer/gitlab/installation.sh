#!/usr/bin/env bash
# Installation et migration de GitLab dans le cluster des services (#396).
# Sourcé par gitlab.sh : namespace devzone-gitlab (suffixé par instance),
# vérification de la mémoire allouable, Helm avec le contexte devzone,
# relais port-forward, runner et migration depuis l'ancien cluster kind.
# Les valeurs Helm (values.yaml, runner-values.yaml) restent à côté.

# Namespace isolé du module : un par instance, comme postgres
GITLAB_NS="devzone-gitlab${INSTANCE_SUFFIX}"
# Ancien cluster kind de GitLab, supprimé par « devzone gitlab migrer »
GITLAB_ANCIEN_CLUSTER="gitlab${INSTANCE_SUFFIX}"
GITLAB_ANCIEN_CONTEXTE="kind-gitlab${INSTANCE_SUFFIX}"

# Convertit une quantité de mémoire Kubernetes (Ki, Mi, Gi, K, M, G, octets)
# en Kio, pour additionner la mémoire allouable des nœuds.
quantite_ki() {
    local q="${1:-}" nombre
    case "$q" in
        *Ki) nombre="${q%Ki}"; echo $((nombre)) ;;
        *Mi) nombre="${q%Mi}"; echo $((nombre * 1024)) ;;
        *Gi) nombre="${q%Gi}"; echo $((nombre * 1024 * 1024)) ;;
        *Ti) nombre="${q%Ti}"; echo $((nombre * 1024 * 1024 * 1024)) ;;
        *K | *k) nombre="${q%[Kk]}"; echo $((nombre * 1000 / 1024)) ;;
        *M) nombre="${q%M}"; echo $((nombre * 1000 * 1000 / 1024)) ;;
        *G) nombre="${q%G}"; echo $((nombre * 1000 * 1000 * 1000 / 1024)) ;;
        *)
            case "$q" in
                '' | *[!0-9]*) echo 0 ;;
                *) echo $((q / 1024)) ;;
            esac
            ;;
    esac
}

# Somme des mémoires allouables des nœuds du cluster des services, en Kio.
# Échoue si le contexte devzone ne répond pas (cluster injoignable).
gitlab_memoire_cluster_ki() {
    local sortie valeur total=0
    sortie="$(kubectl --context devzone get nodes \
        -o jsonpath='{range .items[*]}{.status.allocatable.memory}{"\n"}{end}' 2>/dev/null)" || return 1
    [ -n "$sortie" ] || return 1
    while IFS= read -r valeur; do
        [ -n "$valeur" ] || continue
        total=$((total + $(quantite_ki "$valeur")))
    done <<<"$sortie"
    echo "$total"
}

# Refuse l'installation sous 8 Go de mémoire allouable dans le cluster.
# Le message indique où agrandir le cluster (Docker Desktop) et la commande.
gitlab_verifier_memoire_cluster() {
    local memoire
    if ! memoire="$(gitlab_memoire_cluster_ki)"; then
        echo "devzone : gitlab : cluster des services injoignable (contexte devzone) : devzone cluster" >&2
        return 2
    fi
    if [ "$memoire" -lt 8388608 ]; then
        echo "devzone : gitlab : il faut au moins 8 Go de mémoire allouable dans le cluster (disponible : $((memoire / 1048576)) Go) ; agrandir le cluster (Docker Desktop → Settings → Resources) puis relancer : devzone activer gitlab" >&2
        return 2
    fi
    return 0
}

# Namespace présent dans le cluster des services : GitLab est installé.
gitlab_installe() {
    kubectl --context devzone get namespace "$GITLAB_NS" >/dev/null 2>&1
}

# Crée le namespace, l'étiquette et la NetworkPolicy isolante (étape A).
gitlab_namespace_preparer() {
    kubectl --context devzone create namespace "$GITLAB_NS" --dry-run=client -o yaml |
        kubectl --context devzone apply -f - >/dev/null
    kubectl --context devzone label namespace "$GITLAB_NS" "$CLUSTER_ETIQUETTE" --overwrite >/dev/null
    namespace_isoler "$GITLAB_NS"
}

# Installe GitLab et son runner dans le cluster des services, puis prépare
# l'accès (relais web/SSH, /etc/hosts) et le seed des données de test.
gitlab_installer() {
    echo "▶ Vérification de la mémoire allouable du cluster des services…"
    gitlab_verifier_memoire_cluster || return 2

    mkdir -p "$GITLAB_SECRETS_DIR"
    gitlab_namespace_preparer

    # Dépôt Helm GitLab (idempotent)
    echo "▶ Ajout du dépôt Helm GitLab…"
    helm repo add gitlab https://charts.gitlab.io 2>/dev/null || true
    helm repo update >/dev/null 2>&1 || true

    # Installation des services en ClusterIP, sans exposition directe :
    # l'accès passe uniquement par le relais port-forward du conteneur
    echo "▶ Installation du chart GitLab dans $GITLAB_NS…"
    # Secret Rails (#347) : réinstallation -> réappliquer le secret conservé avant
    # le helm upgrade --install (le chart le réutilise, sessions navigateur valides)
    gitlab_secrets_appliquer
    helm --kube-context devzone upgrade --install gitlab gitlab/gitlab \
        --version 9.11.16 \
        --namespace "$GITLAB_NS" \
        --create-namespace \
        -f "$ICI/values.yaml" \
        --timeout "${GITLAB_ATTENTE}s" \
        --wait
    if [ ! -f "$GITLAB_RAILS_FICHIER" ]; then
        gitlab_secrets_copier
    fi

    # Relais avant l'attente : curl et git en HTTP résolvent *.localhost vers
    # la boucle locale et n'atteignent GitLab que par ces port-forward (#320)
    gitlab_relais_lancer || return 1

    # Nom gitlab.localhost dans /etc/hosts avant l'attente : ssh, glab et
    # getent en ont besoin dès que le service monte (curl, lui, résout seul)
    gitlab_hote_poser || true

    gitlab_attendre_pret
    gitlab_seed

    # Runner : son URL interne et le clone des jobs pointent vers le namespace
    # de l'instance (jamais le namespace fixe « gitlab » d'avant #396)
    echo "▶ Installation de l'exécuteur GitLab Runner…"
    local runner_token="" valeurs_runner
    if [ -f "$GITLAB_SECRETS_DIR/runner-token" ]; then
        runner_token="$(cat "$GITLAB_SECRETS_DIR/runner-token")"
    fi
    if [ -z "$runner_token" ]; then
        echo "devzone : seed GitLab : jeton de runner introuvable (seed incomplet), arrêt du seed." >&2
        return 1
    fi
    valeurs_runner="$(mktemp)"
    sed "s/__NAMESPACE__/$GITLAB_NS/g" "$ICI/runner-values.yaml" >"$valeurs_runner"
    helm --kube-context devzone upgrade --install gitlab-runner gitlab/gitlab-runner \
        --version 0.88.2 \
        --namespace "$GITLAB_NS" \
        -f "$valeurs_runner" \
        --set "runnerToken=${runner_token}"
    rm -f "$valeurs_runner"

    gitlab_secrets_avertir

    echo "▶ Installation terminée."
    echo "  URL : http://gitlab.localhost:8929"
    echo "  Utilisateur : root"
    echo "  Mot de passe root : $GITLAB_SECRETS_DIR/root-password (chmod 600)"
}

# Retire GitLab : relais, releases Helm et namespace de l'instance seulement.
# Le secret Rails est gardé (sessions du navigateur valides à la réinstallation),
# sauf désinstallation complète voulue (--oui) : il part alors avec les données.
gitlab_desinstaller() {
    local supprimer_secret="" arg
    for arg in "$@"; do
        case "$arg" in
            --oui) supprimer_secret=1 ;;
            *) echo "devzone : gitlab desinstaller : argument inconnu : $arg" >&2; return 2 ;;
        esac
    done
    echo "▶ Désinstallation de GitLab…"
    gitlab_relais_arreter
    rm -rf "$(relais_dossier gitlab-web)" "$(relais_dossier gitlab-ssh)" \
        "$(relais_dossier gitlab-8929)" "$(relais_dossier gitlab-2224)"
    helm --kube-context devzone uninstall gitlab --namespace "$GITLAB_NS" >/dev/null 2>&1 || true
    helm --kube-context devzone uninstall gitlab-runner --namespace "$GITLAB_NS" >/dev/null 2>&1 || true
    kubectl --context devzone delete namespace "$GITLAB_NS" --ignore-not-found >/dev/null 2>&1 || true
    if [ -n "$supprimer_secret" ]; then
        rm -rf "$GITLAB_SECRETS_DIR"
        echo "secret Rails supprimé avec les données de GitLab."
    elif [ -d "$GITLAB_SECRETS_DIR" ]; then
        find "$GITLAB_SECRETS_DIR" -mindepth 1 ! -name rails-secret.yaml -exec rm -rf {} + 2>/dev/null || true
        if [ -f "$GITLAB_RAILS_FICHIER" ]; then
            echo "secret Rails gardé dans workspace/.gitlab/rails-secret.yaml (sessions du navigateur valides à la réinstallation)"
        fi
    fi
    gitlab_hote_retirer
    echo "✔ GitLab désinstallé."
    regenerer_identifiants
}

# Migration : installe et seed dans le cluster des services, puis supprime
# l'ancien cluster kind-gitlab après confirmation (ou --oui).
gitlab_migrer() {
    local oui="" arg reponse
    for arg in "$@"; do
        case "$arg" in
            --oui) oui=1 ;;
            *) echo "devzone : gitlab migrer : argument inconnu : $arg (devzone gitlab migrer [--oui])" >&2; return 2 ;;
        esac
    done

    echo "▶ Migration de GitLab depuis l'ancien cluster kind…"
    echo "  C'est un GitLab de test : le projet de démo et le runner sont recréés, le reste est perdu."
    gitlab_installer || return $?

    if ! kind get clusters 2>/dev/null | grep -qx "$GITLAB_ANCIEN_CLUSTER"; then
        echo "✔ Aucun ancien cluster $GITLAB_ANCIEN_CONTEXTE à supprimer."
        return 0
    fi

    if [ -z "$oui" ]; then
        if ! cluster_interactif; then
            echo "devzone : gitlab : confirmation impossible sans terminal : devzone gitlab migrer --oui (ancien cluster $GITLAB_ANCIEN_CONTEXTE conservé)" >&2
            return 2
        fi
        printf "Supprimer l'ancien cluster %s et ses données ? [o/N] " "$GITLAB_ANCIEN_CONTEXTE" >&2
        read -r reponse || reponse=""
        case "$reponse" in
            o | O | oui) ;;
            *) echo "Abandon : ancien cluster $GITLAB_ANCIEN_CONTEXTE conservé."; return 0 ;;
        esac
    fi

    kind delete cluster --name "$GITLAB_ANCIEN_CLUSTER"
    kubectl config delete-context "$GITLAB_ANCIEN_CONTEXTE" >/dev/null 2>&1 || true
    kubectl config delete-cluster "$GITLAB_ANCIEN_CONTEXTE" >/dev/null 2>&1 || true
    kubectl config delete-user "$GITLAB_ANCIEN_CONTEXTE" >/dev/null 2>&1 || true
    echo "✔ Ancien cluster $GITLAB_ANCIEN_CONTEXTE supprimé."
}

# Accès web et SSH : port-forward vers les services ClusterIP du namespace.
gitlab_relais_lancer() {
    relais_lancer gitlab-web devzone "$GITLAB_NS" svc/gitlab-webservice-default 8929:8181
    relais_lancer gitlab-ssh devzone "$GITLAB_NS" svc/gitlab-gitlab-shell 2224:22
}

# Arrête les deux relais du module.
gitlab_relais_arreter() {
    relais_arreter gitlab-web
    relais_arreter gitlab-ssh
}

# État des relais : code 0 seulement si les deux tournent.
gitlab_relais_etat() {
    local manquants=""
    relais_actif gitlab-web || manquants="$manquants 8929"
    relais_actif gitlab-ssh || manquants="$manquants 2224"
    if [ -n "$manquants" ]; then
        echo "relais gitlab arrêté sur${manquants}"
        return 1
    fi
    return 0
}

# Vrai si un ancien cluster kind-gitlab existe encore (avertissement du
# récapitulatif, tant que la migration n'a pas été faite).
gitlab_ancien_cluster_existe() {
    kind get clusters 2>/dev/null | grep -qx "$GITLAB_ANCIEN_CLUSTER"
}
