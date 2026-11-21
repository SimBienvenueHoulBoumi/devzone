#!/usr/bin/env bash
# shellcheck shell=bash
# devzone, status summary of the modules.
# Sourced by .devcontainer/devzone (split of the 1 600 lines file, #722):
# functions only, shared variables are defined in devzone.

# État complet : ✔ prêt, ✖ nécessaire, ○ facultatif, ⚠ à corriger ; chaque
# point à faire avec sa commande (affiché à chaque démarrage)
etat() {
    local nom email statut m retards chemin ports_etat relais_marque ctx_travail ctx_hote paquets_marque paquets_noms argocd_repo
    echo "devzone: state (devzone to show it again)"
    ligne_version_disponible
    nom="$(git config --get user.name || true)"
    email="$(git config --get user.email || true)"
    if [ -n "$nom" ] && [ -n "$email" ]; then
        echo "  ✔ git identity    $nom <$email>"
    else
        echo "  ✖ git identity    needed to commit: gh auth login -s workflow (automatic),"
        echo "                    ou git config --file ~/.config/git/config user.name \"<nom>\" et user.email \"<email>\""
    fi
    if [ "$(plateforme_lue)" = gitlab ]; then
        # Plateforme gitlab : l'instance et glab, puis les lignes propres à
        # GitHub (contrôles gh) signalées comme non applicables ici, en
        # attendant le support GitLab de repowarden (#531)
        ligne_plateforme
        url="$(url_gitlab_lue)"
        if git config --global --get "credential.$url.helper" 2>/dev/null | grep -q 'glab auth git-credential'; then
            echo "  ✔ git via glab"
        else
            echo "  ⚠ git via glab    to set: devzone platform gitlab"
        fi
        echo "  ○ GitHub          inutile ici (plateforme gitlab choisie)"
        echo "  ⚠ repowarden      reste sur GitHub (bots et tickets) : support GitLab à venir (simdevWarden/repowarden#531)"
    else
        ligne_plateforme
        if ! statut="$(gh auth status 2>&1)"; then
            echo "  ○ GitHub          optional (push and PR, repowarden tickets) : gh auth login -s workflow"
        elif grep -q "Token scopes:" <<<"$statut" && ! grep -q "'workflow'" <<<"$statut"; then
            echo "  ⚠ GitHub          connecté, sans permission workflow (push de .github/workflows/ refusé) : gh auth refresh -h github.com -s workflow"
        else
            echo "  ✔ GitHub          connecté"
        fi
    fi
    if retards="$(outils_retard)"; then
        if [ -z "$retards" ]; then
            echo "  ✔ tools          pinned versions"
        else
            while read -r paquet figee installee; do
                [ -n "$paquet" ] || continue
                echo "  ⚠ tools          $paquet $installee installed, $figee pinned: devzone apply"
            done <<<"$retards"
        fi
    fi
    while IFS= read -r chemin; do
        [ -n "$chemin" ] || continue
        echo "  ⚠ worktree        $chemin absent ici (créé hors du conteneur ?) : le gérer de ce côté-là, jamais git worktree prune ici (manage/docs/reference.md, Worktrees git)"
    done < <(worktrees_absents)
    for m in "${MODULES[@]}"; do
        if dans_pod && service_module "$m"; then
            # Kubernetes workspace pod (#528): presence by the cluster DNS
            service_ligne_pod "$m"
        elif [ "$(valeur "$m")" = on ] && [ -f "$(fichier_echec "$m")" ]; then
            printf '  ✖ module %-10s failed: incomplete install (%s): devzone apply\n' "$m" "$(cat "$(fichier_echec "$m")")"
        elif [ "$(valeur "$m")" = on ] && [ "$m" = gitlab ]; then
            # GitLab actif : son état réel (prêt, runner, en échec)
            printf '  ✔ module %-10s %s\n' "$m" "$(bash "$ICI/gitlab/gitlab.sh" status)"
        elif [ "$(valeur "$m")" = on ] && [ "$m" = postgres ]; then
            printf '  ✔ module %-10s %s\n' "$m" "$(bash "$ICI/$m/$m.sh" status)"
        elif [ "$(valeur "$m")" = on ] && [ "$m" = argocd ]; then
            printf '  ✔ module %-10s %s\n' "$m" "$(bash "$ICI/argocd/argocd.sh" status)"
        elif [ "$(valeur "$m")" = on ] && [ "$m" = mysql ]; then
            printf '  ✔ module %-10s %s\n' "$m" "$(bash "$ICI/catalog/mysql/mysql.sh" status)"
        elif [ "$(valeur "$m")" = on ]; then
            printf '  ✔ module %-10s active: %s\n' "$m" "$(description "$m")"
        else
            printf '  ○ module %-10s optional, %s: devzone enable %s\n' "$m" "$(description "$m")" "$m"
        fi
    done
    # GitOps repository of the instance (#539): the designation of .argocd.conf
    argocd_repo="$(conf_get argocd repo)"
    if [ -n "$argocd_repo" ] && [ "$argocd_repo" != none ]; then
        printf '  ○ argocd          GitOps repository: %s\n' "$argocd_repo"
    elif dans_pod; then
        gitops_state_line
    else
        printf '  ○ argocd          no GitOps repository: devzone argocd init\n'
    fi
    # Socket Docker de l'hôte (#432) : l'avertissement montre l'état réel,
    # le socket monté (même variable que docker-relay.sh), pas l'option :
    # le montage ne change qu'au make rebuild (faux rassurant en attendant)
    # In the Kubernetes workspace (DEVZONE_WORKSPACE=kubernetes), the pod has
    # no Docker host socket: no alert, the service account is the cluster access
    if [ "${DEVZONE_WORKSPACE:-}" = kubernetes ]; then
        printf '  ✔ workspace       Kubernetes pod, service account access only (no Docker socket)\n'
    else
        relais_source="${DEVZONE_RELAIS_SOURCE:-/var/run/docker-host.sock}"
        if [ -e "$relais_source" ] && [ "$(valeur docker-hote)" = on ]; then
            printf '  ⚠ socket Docker de l hôte partagé (agents compris)\n'
        elif [ -e "$relais_source" ]; then
            printf '  ⚠ socket Docker de l hôte encore partagé : make rebuild sur le poste\n'
        elif [ "$(valeur docker-hote)" = on ]; then
            printf '  ⚠ socket Docker de l hôte absent : make rebuild sur le poste\n'
        fi
    fi
    # Applications du catalogue (#414)
    if [ -d "$ICI/catalog" ]; then
        bash "$ICI/catalog.sh" resume
    fi
    # Secret Rails GitLab (#347) : avertissement si les secrets ont été perdus
    if [ "$(valeur gitlab)" = on ] && [ ! -f "$RACINE/workspace/.gitlab/rails-secret.yaml" ]; then
        echo "  ⚠ gitlab          GitLab réinstallé : si le navigateur affiche 422, supprimez les données de site de gitlab.localhost"
    fi
    # Cluster de devzone distant : avertissement dans le récapitulatif
    cluster_actuel="$(cluster_saved)"
    if [ -n "$cluster_actuel" ] && ! cluster_is_local "$cluster_actuel"; then
        printf '  ⚠ cluster        remote: %s — services on a remote cluster\n' "$cluster_actuel"
    fi
    # Ancien cluster kind-gitlab encore présent : inviter à migrer (#396)
    if kind get clusters 2>/dev/null | grep -qx "gitlab${INSTANCE_SUFFIX}"; then
        printf '  ⚠ old kind-gitlab cluster%s: devzone gitlab migrate\n' "$INSTANCE_SUFFIX"
    fi
    # Cluster de travail interne (kind) : avertissement dans le recapitulatif
    ctx_travail="$(kubectl config current-context 2>/dev/null || true)"
    case "$ctx_travail" in
        kind-gitlab* | kind-devzone*)
            ctx_hote="$(KUBECONFIG="${DEVZONE_KUBE_HOTE:-$HOME/.kube/hote.config}" kubectl config current-context 2>/dev/null || true)"
            if [ -n "$ctx_hote" ] && cluster_reachable "$ctx_hote"; then
                printf '  ⚠ cluster de travail : %s (cluster interne de devzone) ; revenir : devzone use %s\n' "$ctx_travail" "$ctx_hote"
            fi
            ;;
    esac
    # Contrôle RBAC : vérification d'accès aux secrets PostgreSQL
    ctx_rbac="$(kubectl auth can-i --as=system:serviceaccount:default:default get secrets -n devzone-postgres 2>/dev/null || true)"
    if [ "$ctx_rbac" = "yes" ]; then
        printf '  ⚠ rbac          : accès aux secrets devzone-postgres non restreint\n'
    fi
    ports_etat="$(bash "$ICI/ports.sh" resume 2>/dev/null || true)"
    case "$ports_etat" in
        none*) printf '  ○ ports to the workstation %s\n' "$ports_etat" ;;
        *) printf '  ✔ ports to the workstation %s\n' "$ports_etat" ;;
    esac
    # Identifiants regroupés (#332) : le chemin seulement, jamais le contenu
    if [ -f "$RACINE/.password" ]; then
        printf '  ○ credentials: %s\n' "$RACINE/.password"
    fi
    # Marque posée par docker-relay.sh au démarrage (#293) : docker exec
    # longs coupés, kind et modules en échec
    relais_marque="${DEVZONE_RELAIS_MARQUE:-/tmp/devzone-relais-docker.echec}"
    if [ -f "$relais_marque" ]; then
        printf '  ⚠ Docker relay     %s: devzone repair\n' "$(head -1 "$relais_marque")"
    fi
    # Marque posee par packages.sh a l echec de reapplication (351) : noms des paquets non installes
    paquets_marque="${DEVZONE_PAQUETS_MARQUE:-/tmp/devzone-paquets.echec}"
    if [ -f "$paquets_marque" ]; then
        paquets_noms=""
        while IFS= read -r n; do
            if [ -n "$n" ]; then
                paquets_noms="${paquets_noms:+$paquets_noms, }$n"
            fi
        done < "$paquets_marque"
        echo "  ⚠ packages         $paquets_noms: devzone packages"
    fi
}
