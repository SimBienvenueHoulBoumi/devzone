#!/usr/bin/env bash
# Installation et migration de GitLab dans le cluster des services (#396).
# Sourcé par gitlab.sh : namespace devzone-gitlab (suffixé par instance),
# vérification de la mémoire allouable, Helm avec le contexte devzone,
# relais port-forward, runner et migration depuis l'ancien cluster kind.
# Le chart enveloppe charts/devzone-gitlab (#538) porte les dépendances et les
# valeurs ; chart.sh (helm direct) et argocd.sh (Application) l'installent.

# Shared memory check of the services cluster (#608): quantity_ki,
# memory_cluster_ki and check_module_memory.
# shellcheck source=SCRIPTDIR/../memory.sh
# shellcheck disable=SC1091
. "$ICI/../memory.sh"

# Namespace isolé du module : un par instance, comme postgres
GITLAB_NS="devzone-gitlab${INSTANCE_SUFFIX}"
# Ancien cluster kind de GitLab, supprimé par « devzone gitlab migrate »
GITLAB_ANCIEN_CLUSTER="gitlab${INSTANCE_SUFFIX}"
GITLAB_ANCIEN_CONTEXTE="kind-gitlab${INSTANCE_SUFFIX}"

# Namespace présent dans le cluster des services : GitLab est installé.
# Lecture des namespaces réservée à l'administrateur (#430).
gitlab_installe() {
    account_admin "$(account_context)" get namespace "$GITLAB_NS" >/dev/null 2>&1
}

# Crée le namespace, étiquette et autorise le compte limité (#430), pose l'isolation.
gitlab_namespace_preparer() {
    local ctx
    ctx="$(account_context)"
    account_namespace "$ctx" "$GITLAB_NS"
    namespace_isolate "$GITLAB_NS"
}

# Installe GitLab et son runner dans le cluster des services, puis prépare
# l'accès (relais web/SSH, /etc/hosts) et le seed des données de test.
gitlab_installer() {
    echo "▶ Vérification de la mémoire allouable du cluster des services…"
    check_module_memory gitlab 8 || return 2

    mkdir -p "$GITLAB_SECRETS_DIR"
    gitlab_namespace_preparer

    # Secret Rails (#347) : réinstallation -> réappliquer le secret conservé avant
    # l'installation (le chart le réutilise, sessions navigateur valides)
    gitlab_secrets_appliquer
    gitlab_runner_ancien_retirer

    # Argo CD holds the chart when the module is on (#538): the Application
    # syncs it and the seed runs once GitLab answers. Otherwise the wrapper chart
    # is installed by helm, the runner held back until the seed wrote its Secret
    local par_argocd=0
    if gitlab_argocd_active; then
        par_argocd=1
        gitlab_release_adopter
        gitlab_application_apply || return 1
    else
        echo "▶ Installation du chart GitLab dans ${GITLAB_NS}…"
        gitlab_chart_depend
        gitlab_helm_pass 0 || return 1
    fi

    # Relais avant l'attente : curl et git en HTTP résolvent *.localhost vers
    # la boucle locale et n'atteignent GitLab que par ces port-forward (#320)
    gitlab_relais_lancer || return 1

    # Nom gitlab.localhost dans /etc/hosts avant l'attente : ssh, glab et
    # getent en ont besoin dès que le service monte (curl, lui, résout seul)
    gitlab_hote_poser || true

    gitlab_attendre_pret
    gitlab_seed
    if [ ! -f "$GITLAB_RAILS_FICHIER" ]; then
        gitlab_secrets_copier
    fi
    if [ "$par_argocd" = 0 ]; then
        echo "▶ Exécuteur GitLab Runner…"
        gitlab_helm_pass 1 || return 1
    fi

    gitlab_secrets_avertir

    echo "▶ Installation terminée."
    echo "  URL : http://gitlab.localhost:8929"
    echo "  Utilisateur : root"
    echo "  Mot de passe root : $GITLAB_SECRETS_DIR/root-password (chmod 600)"
}

# Retire GitLab : relais, releases Helm et namespace de l'instance seulement.
# Le secret Rails est gardé (sessions du navigateur valides à la réinstallation),
# sauf désinstallation complète voulue (--yes) : il part alors avec les données.
gitlab_desinstaller() {
    local supprimer_secret="" arg
    for arg in "$@"; do
        case "$arg" in
            --yes) supprimer_secret=1 ;;
            *) echo "devzone : gitlab uninstall : argument inconnu : $arg" >&2; return 2 ;;
        esac
    done
    echo "▶ Désinstallation de GitLab…"
    gitlab_relais_arreter
    rm -rf "$(relay_dir gitlab-web)" "$(relay_dir gitlab-ssh)" \
        "$(relay_dir gitlab-8929)" "$(relay_dir gitlab-2224)"
    # Application tenue par Argo CD (#538) : ses ressources partent avec elle
    gitlab_application_retirer || true
    account_helm "$(account_context)" uninstall gitlab --namespace "$GITLAB_NS" >/dev/null 2>&1 || true
    gitlab_runner_ancien_retirer
    # RoleBinding retiré puis namespace supprimé par l'administrateur (#430)
    account_remove "$(account_context)" "$GITLAB_NS" >/dev/null 2>&1 || true
    account_admin "$(account_context)" delete namespace "$GITLAB_NS" --ignore-not-found >/dev/null 2>&1 || true
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
# l'ancien cluster kind-gitlab après confirmation (ou --yes).
gitlab_migrer() {
    local oui="" arg reponse
    for arg in "$@"; do
        case "$arg" in
            --yes) oui=1 ;;
            *) echo "devzone : gitlab migrate : argument inconnu : $arg (devzone gitlab migrate [--yes])" >&2; return 2 ;;
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
        if ! cluster_interactive; then
            echo "devzone : gitlab : confirmation impossible sans terminal : devzone gitlab migrate --yes (ancien cluster $GITLAB_ANCIEN_CONTEXTE conservé)" >&2
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
    relay_start gitlab-web devzone "$GITLAB_NS" svc/gitlab-webservice-default 8929:8181
    relay_start gitlab-ssh devzone "$GITLAB_NS" svc/gitlab-gitlab-shell 2224:22
}

# Arrête les deux relais du module.
gitlab_relais_arreter() {
    relay_stop gitlab-web
    relay_stop gitlab-ssh
}

# État des relais : code 0 seulement si les deux tournent.
gitlab_relais_etat() {
    local manquants=""
    relay_active gitlab-web || manquants="$manquants 8929"
    relay_active gitlab-ssh || manquants="$manquants 2224"
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
