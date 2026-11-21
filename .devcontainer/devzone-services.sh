#!/usr/bin/env bash
# shellcheck shell=bash
# devzone, services of the cluster and their apply functions.
# Sourced by .devcontainer/devzone (split of the 1 600 lines file, #722):
# functions only, shared variables are defined in devzone.

# Lance une commande longue en écrivant « toujours en cours » toutes les
# DEVZONE_PROGRESSION s sur stderr : une installation muette semble bloquée (#195)
avec_progression() {
    local pas="${DEVZONE_PROGRESSION:-30}" ecoule=0 pid code=0
    "$@" &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
        ecoule=$((ecoule + 1))
        if [ $((ecoule % pas)) -eq 0 ] && kill -0 "$pid" 2>/dev/null; then
            echo "devzone : … toujours en cours (${ecoule} s)" >&2
        fi
    done
    wait "$pid" || code=$?
    return "$code"
}

# Fichier qui marque un module actif en échec (contenu : où regarder) ; à côté
# de l'état, dans son volume : l'état l'affiche à chaque démarrage
fichier_echec() {
    echo "$ETAT-echec-$1"
}

# Services in the Kubernetes workspace pod (#528): gitlab, postgres and argocd
# live in the cluster, installed from the workstation (devzone workspace
# services). The pod has no kubeconfig and a limited account (#430): their
# presence is the cluster DNS (like #515), never an installer failure marker.
dans_pod() {
    [ "${DEVZONE_WORKSPACE:-}" = kubernetes ]
}

service_module() {
    case "$1" in
        gitlab | postgres | argocd) return 0 ;;
    esac
    return 1
}

# DNS name of the service of a module: <service>.<namespace>.svc
service_dns() {
    case "$1" in
        gitlab) echo "gitlab-webservice-default.devzone-gitlab${INSTANCE_SUFFIX}.svc" ;;
        postgres) echo "postgres.devzone-postgres.svc" ;;
        argocd) echo "argocd-server.devzone-argocd.svc" ;;
    esac
}

service_present() {
    getent hosts "$(service_dns "$1")" >/dev/null 2>&1
}

# Status line of a service module in the pod: present → active; absent → the
# workstation command that installs it
service_ligne_pod() {
    local m="$1"
    if service_present "$m"; then
        printf '  ✔ module %-10s active: %s (%s)\n' "$m" "$(description "$m")" "$(service_dns "$m")"
    elif [ "$(valeur "$m")" = on ]; then
        printf '  ⚠ module %-10s not in the cluster: on the workstation, devzone workspace services enable %s\n' "$m" "$m"
    else
        printf '  ○ module %-10s optional, %s: on the workstation, devzone workspace services enable %s\n' "$m" "$(description "$m")" "$m"
    fi
}

# devzone apply of a service module: in the Kubernetes workspace pod nothing
# is installed (the workstation does it, #528) and the failure marker of an
# earlier start is cleared; elsewhere, the installer of the module
appliquer_service() {
    if dans_pod; then
        rm -f "$(fichier_echec "$1")"
        echo "devzone: $1 is installed from the workstation (devzone workspace services enable $1): nothing to do in the pod"
        return 0
    fi
    "appliquer_$1" on
}

appliquer_kubernetes() {
    if [ "$1" = on ]; then
        bash "$ICI/kube-config.sh"
    else
        rm -f "$HOME/.kube/hote.config"
        # metrics-server retiré des clusters où devzone l'a installé (marqueur
        # devzone=installe posé par metrics-server.sh) ; via sa sous-commande
        bash "$ICI/metrics-server.sh" retirer || true
        echo "devzone : kubernetes désactivé"
    fi
}

appliquer_gitlab() {
    local etat_courant
    if [ "$1" = on ]; then
        # Saut si l'état est prêt et le runner en ligne ; sinon installer reprend
        etat_courant="$(bash "$ICI/gitlab/gitlab.sh" status)"
        if [[ "$etat_courant" == *"prêt"* && "$etat_courant" == *"runner en ligne"* ]]; then
            echo "devzone : gitlab déjà actif, rien à faire."
            # /etc/hosts régénéré par Docker : gitlab.localhost re-pose ici aussi
            bash "$ICI/gitlab/gitlab.sh" hote-poser
            # Échec d'un ancien passage effacé : gitlab est prêt (#366)
            rm -f "$(fichier_echec gitlab)"
        else
            echo "devzone : gitlab activation via installer…"
            if ! bash "$ICI/gitlab/gitlab.sh" install; then
                echo "gitlab" > "$(fichier_echec gitlab)"
                return 1
            fi
            rm -f "$(fichier_echec gitlab)"
        fi
    else
        # Désactiver gitlab seulement si son namespace existe encore
        if bash "$ICI/gitlab/gitlab.sh" installe; then
            echo "devzone : gitlab désactivation…"
            if [ -n "${SUPPRIMER_DONNEES:-}" ]; then
                bash "$ICI/gitlab/gitlab.sh" uninstall --yes
            else
                bash "$ICI/gitlab/gitlab.sh" uninstall
            fi
        else
            echo "devzone : gitlab déjà désactivé (aucun namespace devzone-gitlab)."
        fi
    fi
}

# PostgreSQL partagé (#280) : installé sur le cluster de devzone, choisi à la
# première activation (--context, menu en terminal, kind dédié sinon)
appliquer_postgres() {
    local voulu="" confirmer="" attendre="" arg ctx actuel etat_courant
    if [ "$1" = on ]; then
        for arg in "${@:2}"; do
            if [ -n "$attendre" ]; then
                case "$attendre" in
                    contexte) voulu="$arg" ;;
                    confirmer) confirmer="$arg" ;;
                esac
                attendre=""
                continue
            fi
            case "$arg" in
                --context) attendre=contexte ;;
                --confirm) attendre=confirmer ;;
                *) echo "devzone : argument inconnu : $arg (devzone enable postgres --context CTX [--confirm CTX])" >&2; ecrire postgres off; return 2 ;;
            esac
        done
        if [ -n "$attendre" ]; then
            echo "devzone : $attendre attend un contexte" >&2
            ecrire postgres off
            return 2
        fi
        actuel="$(cluster_saved)"
        if [ -n "$voulu" ] && [ -n "$actuel" ] && [ "$voulu" != "$actuel" ]; then
            echo "devzone : les services de devzone sont sur $actuel ; pour en changer : devzone cluster $voulu" >&2
            ecrire postgres off
            return 2
        fi
        if [ -n "$confirmer" ]; then
            ctx="$(cluster_choose "$voulu" --confirm "$confirmer")" || { ecrire postgres off; return 2; }
        else
            ctx="$(cluster_choose "$voulu")" || { ecrire postgres off; return 2; }
        fi
        # Choix gardé avant l'installation : une reprise vise le même cluster
        cluster_save "$ctx"
        etat_courant="$(bash "$ICI/postgres/postgres.sh" status)"
        # « relais arrêté » d'abord : cette ligne commence aussi par « prêt sur »
        if [[ "$etat_courant" == *"relais arrêté"* ]]; then
            bash "$ICI/postgres/postgres.sh" relay-start
            echo "devzone : postgres : relais relancé"
        elif [[ "$etat_courant" == "prêt sur"* ]]; then
            echo "devzone : postgres déjà actif, rien à faire."
        elif ! bash "$ICI/postgres/postgres.sh" install; then
            echo "postgres" >"$(fichier_echec postgres)"
            return 1
        fi
        rm -f "$(fichier_echec postgres)"
    else
        bash "$ICI/postgres/postgres.sh" uninstall
        rm -f "$(fichier_echec postgres)"
    fi
}

# Argo CD (#411) : installé dans le cluster des services, accès par le relais
# 127.0.0.1:8443 ; un échec est marqué dans l'état et repris par devzone apply
appliquer_argocd() {
    local etat_courant
    if [ "$1" = on ]; then
        etat_courant="$(bash "$ICI/argocd/argocd.sh" status)"
        # « relais arrêté » d'abord : cette ligne commence aussi par « prêt »
        if [[ "$etat_courant" == *"relais arrêté"* ]]; then
            bash "$ICI/argocd/argocd.sh" relay-start
            echo "devzone : argocd : relais relancé"
        elif [[ "$etat_courant" == "prêt"* ]]; then
            echo "devzone : argocd déjà actif, rien à faire."
        elif ! bash "$ICI/argocd/argocd.sh" install; then
            echo "argocd" >"$(fichier_echec argocd)"
            return 1
        fi
        rm -f "$(fichier_echec argocd)"
    else
        bash "$ICI/argocd/argocd.sh" uninstall
        rm -f "$(fichier_echec argocd)"
    fi
}

# MySQL du catalogue (#414) : même logique que postgres (relais relancé s'il
# est arrêté), installation déléguée à mysql.sh
appliquer_mysql() {
    local etat_courant ctx
    if [ "$1" = on ]; then
        ctx="$(cluster_saved)"
        if [ -z "$ctx" ]; then
            echo "devzone : mysql : aucun cluster choisi : devzone enable mysql" >&2
            ecrire mysql off
            echo mysql >"$(fichier_echec mysql)"
            return 2
        fi
        etat_courant="$(bash "$ICI/catalog/mysql/mysql.sh" status)"
        # « relais arrêté » d'abord : cette ligne commence aussi par « prêt sur »
        if [[ "$etat_courant" == *"relais arrêté"* ]]; then
            bash "$ICI/catalog/mysql/mysql.sh" relay-start
            echo "devzone : mysql : relais relancé"
        elif [[ "$etat_courant" == "prêt sur"* ]]; then
            echo "devzone : mysql déjà actif, rien à faire."
        elif ! bash "$ICI/catalog/mysql/mysql.sh" install; then
            echo mysql >"$(fichier_echec mysql)"
            return 1
        fi
        rm -f "$(fichier_echec mysql)"
    else
        # Retrait sans suppression des données : volume gardé (#441) ; les
        # bases ne partent qu'avec un oui (confirmer_suppression)
        bash "$ICI/catalog.sh" remove mysql
        if [ -n "${SUPPRIMER_DONNEES:-}" ]; then
            bash "$ICI/catalog/mysql/mysql.sh" delete-data --yes
        fi
        rm -f "$(fichier_echec mysql)"
    fi
}
