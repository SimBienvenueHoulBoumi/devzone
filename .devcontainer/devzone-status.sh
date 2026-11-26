#!/usr/bin/env bash
# shellcheck shell=bash
# devzone, status summary of the modules.
# Sourced by .devcontainer/devzone (split of the 1 600 lines file, #722):
# functions only, shared variables are defined in devzone.

# Full state: ✔ ready, ✖ required, ○ optional, ⚠ to fix; each point to do with
# its command (shown at each startup)
show_state() {
    local name email status m late path ports_state ctx_work ctx_host packages_mark packages_names argocd_repo
    echo "devzone: state (devzone to show it again)"
    version_available_line
    name="$(git config --get user.name || true)"
    email="$(git config --get user.email || true)"
    if [ -n "$name" ] && [ -n "$email" ]; then
        echo "  ✔ git identity    $name <$email>"
    else
        echo "  ✖ git identity    needed to commit: gh auth login -s workflow (automatic),"
        echo "                    or git config --file ~/.config/git/config user.name \"<name>\" and user.email \"<email>\""
    fi
    if [ "$(platform_read)" = gitlab ]; then
        # gitlab platform: the instance and glab, then the lines specific to
        # GitHub (gh checks) reported as not applicable here, pending the GitLab
        # support of repowarden (#531)
        platform_line
        url="$(gitlab_url_read)"
        if git config --global --get "credential.$url.helper" 2>/dev/null | grep -q 'glab auth git-credential'; then
            echo "  ✔ git via glab"
        else
            echo "  ⚠ git via glab    to set: devzone platform gitlab"
        fi
        echo "  ○ GitHub          not needed here (gitlab platform chosen)"
        echo "  ⚠ repowarden      stays on GitHub (bots and tickets): GitLab support coming (simdevWarden/repowarden#531)"
    else
        platform_line
        if ! status="$(gh auth status 2>&1)"; then
            echo "  ○ GitHub          optional (push and PR, repowarden tickets) : gh auth login -s workflow"
        elif grep -q "Token scopes:" <<<"$status" && ! grep -q "'workflow'" <<<"$status"; then
            echo "  ⚠ GitHub          connected, without workflow permission (push of .github/workflows/ refused): gh auth refresh -h github.com -s workflow"
        else
            echo "  ✔ GitHub          connected"
        fi
    fi
    if late="$(outdated_tools)"; then
        if [ -z "$late" ]; then
            echo "  ✔ tools          pinned versions"
        else
            while read -r package pinned installed; do
                [ -n "$package" ] || continue
                echo "  ⚠ tools          $package $installed installed, $pinned pinned: devzone apply"
            done <<<"$late"
        fi
    fi
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        echo "  ⚠ worktree        $path absent here (created outside the container?): manage it on that side, never git worktree prune here (manage/docs/reference.md, Git worktrees)"
    done < <(missing_worktrees)
    for m in "${MODULES[@]}"; do
        if in_pod && service_module "$m"; then
            # Kubernetes workspace pod (#528): presence by the cluster DNS
            service_pod_line "$m"
        elif [ "$(value_of "$m")" = on ] && [ -f "$(failure_marker_file "$m")" ]; then
            printf '  ✖ module %-10s failed: incomplete install (%s): devzone apply\n' "$m" "$(cat "$(failure_marker_file "$m")")"
        elif [ "$(value_of "$m")" = on ] && [ "$m" = gitlab ]; then
            # gitlab active: its real state (ready, runner, failed)
            printf '  ✔ module %-10s %s\n' "$m" "$(devzone gitlab status)"
        elif [ "$(value_of "$m")" = on ] && [ "$m" = postgres ]; then
            printf '  ✔ module %-10s %s\n' "$m" "$(devzone postgres status)"
        elif [ "$(value_of "$m")" = on ] && [ "$m" = argocd ]; then
            printf '  ✔ module %-10s %s\n' "$m" "$("$ICI/devzone" argocd status)"
        elif [ "$(value_of "$m")" = on ] && [ "$m" = mysql ]; then
            printf '  ✔ module %-10s %s\n' "$m" "$(devzone mysql status)"
        elif [ "$(value_of "$m")" = on ]; then
            printf '  ✔ module %-10s active: %s\n' "$m" "$(description "$m")"
        else
            printf '  ○ module %-10s optional, %s: devzone enable %s\n' "$m" "$(description "$m")" "$m"
        fi
        # Service held by an Argo CD Application (#916): the line is printed by devzone state held
        held="$(DEVZONE_STATE="$ETAT" bash "$ICI/devzone" state held "$m" 2>/dev/null || true)"
        [ -z "$held" ] || printf '                    %s\n' "$held"
    done
    # GitOps repository of the instance (#539): the designation of .argocd.conf
    argocd_repo="$(conf_get argocd repo)"
    if [ -n "$argocd_repo" ] && [ "$argocd_repo" != none ]; then
        printf '  ○ argocd          GitOps repository: %s\n' "$argocd_repo"
    elif in_pod; then
        DEVZONE_STATE="$ETAT" bash "$ICI/devzone" state gitops-line
    else
        printf '  ○ argocd          no GitOps repository: devzone argocd init\n'
    fi
    # Catalog applications (#414)
    if [ -d "$ICI/catalog" ]; then
        DEVZONE_STATE="$ETAT" devzone catalog resume
    fi
    # GitLab Rails secret (#347): warning if the secrets were lost
    if [ "$(value_of gitlab)" = on ] && [ ! -f "$RACINE/workspace/.gitlab/rails-secret.yaml" ]; then
        echo "  ⚠ gitlab          GitLab reinstalled: if the browser shows 422, delete the site data of gitlab.localhost"
    fi
    # Remote devzone cluster: warning in the summary
    current_cluster="$(cluster_saved)"
    if [ -n "$current_cluster" ] && ! cluster_is_local "$current_cluster"; then
        printf '  ⚠ cluster        remote: %s — services on a remote cluster\n' "$current_cluster"
    fi
    devzone cluster clean --quiet || true
    # Old kind-gitlab cluster still present: invite to migrate (#396)
    if kind get clusters 2>/dev/null | grep -qx "gitlab${INSTANCE_SUFFIX}"; then
        printf '  ⚠ old kind-gitlab cluster%s: devzone gitlab migrate\n' "$INSTANCE_SUFFIX"
    fi
    # Internal working cluster (kind): warning in the summary
    ctx_work="$(kubectl config current-context 2>/dev/null || true)"
    case "$ctx_work" in
        kind-gitlab* | kind-devzone*)
            ctx_host="$(KUBECONFIG="${DEVZONE_KUBE_HOST:-$HOME/.kube/hote.config}" kubectl config current-context 2>/dev/null || true)"
            if [ -n "$ctx_host" ] && cluster_reachable "$ctx_host"; then
                printf '  ⚠ working cluster: %s (devzone internal cluster); go back: devzone use %s\n' "$ctx_work" "$ctx_host"
            fi
            ;;
    esac
    # RBAC check: access check to the PostgreSQL secrets
    ctx_rbac="$(kubectl auth can-i --as=system:serviceaccount:default:default get secrets -n devzone-postgres 2>/dev/null || true)"
    if [ "$ctx_rbac" = "yes" ]; then
        printf '  ⚠ rbac          : access to devzone-postgres secrets not restricted\n'
    fi
    ports_state="$(DEVZONE_STATE="$ETAT" devzone port resume 2>/dev/null || echo none)"
    case "$ports_state" in
        none*) printf '  ○ ports to the workstation %s\n' "$ports_state" ;;
        *) printf '  ✔ ports to the workstation %s\n' "$ports_state" ;;
    esac
    # Grouped credentials (#332): the path only, never the content
    if [ -f "$RACINE/.password" ]; then
        printf '  ○ credentials: %s\n' "$RACINE/.password"
    fi
    # Mark set by packages.sh at the failed reapplication (351): names of the packages not installed
    packages_mark="${DEVZONE_PACKAGES_MARKER:-/tmp/devzone-packages.failed}"
    if [ -f "$packages_mark" ]; then
        packages_names=""
        while IFS= read -r n; do
            if [ -n "$n" ]; then
                packages_names="${packages_names:+$packages_names, }$n"
            fi
        done < "$packages_mark"
        echo "  ⚠ packages         $packages_names: devzone packages"
    fi
}
