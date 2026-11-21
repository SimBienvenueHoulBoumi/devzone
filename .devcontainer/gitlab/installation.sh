#!/usr/bin/env bash
# Installation and migration of GitLab in the services cluster (#396).
# Sourced by gitlab.sh: devzone-gitlab namespace (suffixed per instance),
# check of the allocatable memory, Helm with the devzone context, port-forward
# relay, runner and migration from the old kind cluster.
# The wrapper chart charts/devzone-gitlab (#538) holds the dependencies and the
# values; chart.sh (direct helm) and argocd.sh (Application) install it.

# Shared memory check of the services cluster (#608): quantity_ki,
# memory_cluster_ki and check_module_memory.
# shellcheck source=SCRIPTDIR/../memory.sh
# shellcheck disable=SC1091
. "$ICI/../memory.sh"

# Namespace isolated from the module: one per instance, like postgres
GITLAB_NS="devzone-gitlab${INSTANCE_SUFFIX}"
# Old kind cluster of GitLab, deleted by "devzone gitlab migrate"
GITLAB_OLD_CLUSTER="gitlab${INSTANCE_SUFFIX}"
GITLAB_OLD_CONTEXT="kind-gitlab${INSTANCE_SUFFIX}"

# Namespace present in the services cluster: GitLab is installed.
# Reading the namespaces is reserved to the administrator (#430).
gitlab_installed() {
    account_admin "$(account_context)" get namespace "$GITLAB_NS" >/dev/null 2>&1
}

# Creates the namespace, labels it and allows the limited account (#430), sets the isolation.
gitlab_namespace_prepare() {
    local ctx
    ctx="$(account_context)"
    account_namespace "$ctx" "$GITLAB_NS"
    namespace_isolate "$GITLAB_NS"
}

# Installs GitLab and its runner in the services cluster, then prepares the
# access (web/SSH relay, /etc/hosts) and the seed of the test data.
gitlab_install() {
    echo "▶ Checking the allocatable memory of the services cluster…"
    check_module_memory gitlab 8 || return 2

    mkdir -p "$GITLAB_SECRETS_DIR"
    gitlab_namespace_prepare

    # Rails secret (#347): reinstallation -> apply the kept secret again before
    # the installation (the chart reuses it, browser sessions stay valid)
    gitlab_secrets_apply
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
        echo "▶ Installing the GitLab chart in ${GITLAB_NS}…"
        gitlab_chart_depend
        gitlab_helm_pass 0 || return 1
    fi

    # Relay before the wait: curl and git in HTTP resolve *.localhost to the
    # loopback and reach GitLab only through these port-forwards (#320)
    gitlab_relay_start || return 1

    # gitlab.localhost name in /etc/hosts before the wait: ssh, glab and
    # getent need it as soon as the service is up (curl resolves it itself)
    gitlab_host_set || true

    gitlab_wait_ready
    gitlab_seed
    if [ ! -f "$GITLAB_RAILS_FILE" ]; then
        gitlab_secrets_copy
    fi
    if [ "$par_argocd" = 0 ]; then
        echo "▶ GitLab Runner executor…"
        gitlab_helm_pass 1 || return 1
    fi

    gitlab_secrets_warn

    echo "▶ Installation complete."
    echo "  URL: http://gitlab.localhost:8929"
    echo "  User: root"
    echo "  Root password: $GITLAB_SECRETS_DIR/root-password (chmod 600)"
}

# Removes GitLab: relays, Helm releases and the namespace of the instance only.
# The Rails secret is kept (browser sessions valid at the reinstallation),
# unless a complete uninstall is wanted (--yes): it then goes with the data.
gitlab_uninstall() {
    local delete_secret="" arg
    for arg in "$@"; do
        case "$arg" in
            --yes) delete_secret=1 ;;
            *) echo "devzone : gitlab uninstall : unknown argument : $arg" >&2; return 2 ;;
        esac
    done
    echo "▶ Uninstalling GitLab…"
    gitlab_relay_stop
    rm -rf "$(relay_dir gitlab-web)" "$(relay_dir gitlab-ssh)" \
        "$(relay_dir gitlab-8929)" "$(relay_dir gitlab-2224)"
    # Application held by Argo CD (#538): its resources go with it
    gitlab_application_retirer || true
    account_helm "$(account_context)" uninstall gitlab --namespace "$GITLAB_NS" >/dev/null 2>&1 || true
    gitlab_runner_ancien_retirer
    # RoleBinding removed, then the namespace deleted by the administrator (#430)
    account_remove "$(account_context)" "$GITLAB_NS" >/dev/null 2>&1 || true
    account_admin "$(account_context)" delete namespace "$GITLAB_NS" --ignore-not-found >/dev/null 2>&1 || true
    if [ -n "$delete_secret" ]; then
        rm -rf "$GITLAB_SECRETS_DIR"
        echo "Rails secret deleted with the GitLab data."
    elif [ -d "$GITLAB_SECRETS_DIR" ]; then
        find "$GITLAB_SECRETS_DIR" -mindepth 1 ! -name rails-secret.yaml -exec rm -rf {} + 2>/dev/null || true
        if [ -f "$GITLAB_RAILS_FILE" ]; then
            echo "Rails secret kept in workspace/.gitlab/rails-secret.yaml (browser sessions valid at reinstallation)"
        fi
    fi
    gitlab_host_remove
    echo "✔ GitLab uninstalled."
    regenerer_identifiants
}

# Migration: installs and seeds in the services cluster, then deletes the old
# kind-gitlab cluster after confirmation (or --yes).
gitlab_migrate() {
    local yes_flag="" arg answer
    for arg in "$@"; do
        case "$arg" in
            --yes) yes_flag=1 ;;
            *) echo "devzone : gitlab migrate : unknown argument : $arg (devzone gitlab migrate [--yes])" >&2; return 2 ;;
        esac
    done

    echo "▶ Migrating GitLab from the old kind cluster…"
    echo "  This is a test GitLab: the demo project and the runner are recreated, the rest is lost."
    gitlab_install || return $?

    if ! kind get clusters 2>/dev/null | grep -qx "$GITLAB_OLD_CLUSTER"; then
        echo "✔ No old cluster $GITLAB_OLD_CONTEXT to delete."
        return 0
    fi

    if [ -z "$yes_flag" ]; then
        if ! cluster_interactive; then
            echo "devzone : gitlab : confirmation impossible without a terminal: devzone gitlab migrate --yes (old cluster $GITLAB_OLD_CONTEXT kept)" >&2
            return 2
        fi
        printf "Delete the old cluster %s and its data? [o/N] " "$GITLAB_OLD_CONTEXT" >&2
        read -r answer || answer=""
        case "$answer" in
            o | O | oui) ;;
            *) echo "Aborted: old cluster $GITLAB_OLD_CONTEXT kept."; return 0 ;;
        esac
    fi

    kind delete cluster --name "$GITLAB_OLD_CLUSTER"
    kubectl config delete-context "$GITLAB_OLD_CONTEXT" >/dev/null 2>&1 || true
    kubectl config delete-cluster "$GITLAB_OLD_CONTEXT" >/dev/null 2>&1 || true
    kubectl config delete-user "$GITLAB_OLD_CONTEXT" >/dev/null 2>&1 || true
    echo "✔ Old cluster $GITLAB_OLD_CONTEXT deleted."
}

# Web and SSH access: port-forward to the ClusterIP services of the namespace.
gitlab_relay_start() {
    relay_start gitlab-web devzone "$GITLAB_NS" svc/gitlab-webservice-default 8929:8181
    relay_start gitlab-ssh devzone "$GITLAB_NS" svc/gitlab-gitlab-shell 2224:22
}

# Stops the two relays of the module.
gitlab_relay_stop() {
    relay_stop gitlab-web
    relay_stop gitlab-ssh
}

# State of the relays: code 0 only if both are running.
gitlab_relay_status() {
    local missing=""
    relay_active gitlab-web || missing="$missing 8929"
    relay_active gitlab-ssh || missing="$missing 2224"
    if [ -n "$missing" ]; then
        echo "gitlab relay stopped on${missing}"
        return 1
    fi
    return 0
}

# True if an old kind-gitlab cluster still exists (warning of the summary,
# as long as the migration has not been done).
gitlab_old_cluster_exists() {
    kind get clusters 2>/dev/null | grep -qx "$GITLAB_OLD_CLUSTER"
}
