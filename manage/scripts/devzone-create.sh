#!/usr/bin/env bash
# Creation of a devzone (devzone <folder>): asks for the GitOps repository,
# copies the package, writes .argocd.conf and the manifest, then starts the
# workspace (Kubernetes) or the container (Docker). Sourced by manage/devzone,
# which defines PAQUET, PACKAGE_ITEMS and version(); devzone-manifest.sh must
# be sourced first.
# shellcheck disable=SC2154 # PAQUET, PACKAGE_ITEMS: set by manage/devzone

# GitOps repository of Argo CD for the creation (#539): github, an existing
# URL, or none. Asked in a terminal (default: github when gh is connected),
# or none with a notice without one (the --gitops option names the choice).
ask_gitops() {
    local answer default=""
    if gh auth status >/dev/null 2>&1; then
        default="github"
    fi
    printf 'GitOps repository for Argo CD? [G]itHub (created under your gh account at first start) / a URL / [n]one : ' >&2
    read -r answer || answer=""
    answer="${answer:-$default}"
    case "$answer" in
        G | g | GitHub | github | Oui | oui | OUI) echo "github" ;;
        n | N | none | None | Non | non | NON | aucun | Aucun) echo "none" ;;
        *) echo "$answer" ;;
    esac
}

create_workstation() {
    local target="$1" gitops="" expect="" option="" arg value login name instance
    shift
    for arg in "$@"; do
        if [ "$expect" = gitops ]; then gitops="$arg"; expect=""; continue; fi
        case "$arg" in
            --gitops) expect=gitops ;;
            --gitops=*) gitops="${arg#--gitops=}" ;;
            --kubernetes | --docker)
                if [ -n "$option" ] && [ "$option" != "${arg#--}" ]; then
                    echo "✖ --kubernetes and --docker: choose one" >&2
                    exit 1
                fi
                option="${arg#--}"
                ;;
            *) echo "✖ option inconnue : $arg (devzone <dossier> [--gitops github|none|<url>] [--kubernetes|--docker])" >&2; exit 1 ;;
        esac
    done
    if [ -n "$expect" ]; then
        echo "✖ --gitops attend une valeur (github, none or a URL)" >&2
        exit 1
    fi

    if [ -e "$target" ] && [ -n "$(ls -A "$target" 2>/dev/null)" ]; then
        echo "✖ $target existe et n'est pas vide : rien n'est écrasé. Choisis un autre dossier." >&2
        exit 1
    fi

    # Mode before any copy: --kubernetes without a cluster creates nothing (#497)
    # shellcheck source=SCRIPTDIR/create-mode.sh
    . "$PAQUET/manage/scripts/create-mode.sh"
    create_mode_choose "$option" || exit 1

    if [ -z "$gitops" ]; then
        if [ -t 0 ]; then
            gitops="$(ask_gitops)"
        else
            echo "⚠ no GitOps repository for Argo CD: pass --gitops <github|none|https://github.com/<login>/<name>.git> to create a devzone without a terminal; using none" >&2
            gitops="none"
        fi
    fi
    mkdir -p "$target/workspace" "$target/manage"
    cp -R "${PACKAGE_ITEMS[@]/#/$PAQUET/}" "$target/"
    cp -R "$PAQUET/manage/scripts" "$target/manage/"
    touch "$target/workspace/.gitkeep"
    # npm never includes .gitignore: written here
    : >"$target/.gitignore"
    complete_gitignore "$target"
    chmod +x "$target/manage/scripts/desinstaller.sh" "$target/manage/scripts/lancer.sh"
    create_mode_write "$target" "$CREATE_MODE"
    # The GitOps repository of the new devzone (#539): github, an existing URL,
    # or none, written in the .argocd.conf of the new devzone (conf.sh writes
    # the header of the file when absent)
    . "$PAQUET/.devcontainer/argocd/conf.sh"
    # shellcheck disable=SC2034 # read by conf.sh
    ARGOCD_CONF="$target/.argocd.conf"
    if [ "$gitops" = github ]; then
        if ! gh auth status >/dev/null 2>&1; then
            echo "⚠ GitHub not connected (gh auth login): no GitOps repository, the Applications are applied directly; pass --gitops none" >&2
            value="none"
        else
            login="$(gh api user --jq .login 2>/dev/null)" || login=""
            if [ -z "$login" ]; then
                echo "⚠ GitHub login unreadable (gh api user): no GitOps repository, the Applications are applied directly; pass --gitops none" >&2
                value="none"
            else
                name="${DEVZONE_GITOPS_REPO_NAME:-devzone-argocd}"
                instance="${DEVZONE_VOLUMES:-devzone}"
                if [ "$instance" != "devzone" ]; then
                    name="$name-$instance"
                fi
                value="https://github.com/$login/$name.git"
            fi
        fi
    elif [ "$gitops" = none ]; then
        value="none"
    else
        value="$gitops"
    fi
    conf_set argocd "repo=$value"
    case "$value" in
        none) echo "✔ no GitOps repository: the Applications are applied directly (devzone workspace argocd init to change)" ;;
        *) echo "✔ GitOps repository: $value ($target/.argocd.conf)" ;;
    esac
    target="$(cd "$target" && pwd)"
    write_manifest "$target"
    echo "✔ devzone $(version) créé dans $target"
    # Kubernetes: the workspace goes to the cluster, no Docker check (Docker
    # Desktop hosts the cluster, but devzone does not need it directly)
    if [ "$CREATE_MODE" = kubernetes ]; then
        create_mode_start "$target" "$PAQUET/manage/workspace.sh"
        return
    fi
    if [ -n "${DEVZONE_SANS_DEMARRER:-}" ]; then
        echo "Pour le lancer : cd $target && make up"
        return 0
    fi
    # Docker first: the folder stays ready, to start once Docker is running
    # shellcheck source=SCRIPTDIR/docker.sh
    . "$PAQUET/manage/scripts/docker.sh"
    if ! docker_ready "cd $target && make shell"; then
        echo "  Le dossier est prêt : rien à refaire, sauf ce lancement." >&2
        exit 1
    fi
    echo "▶ Lancement (quelques minutes la première fois)…"
    if command -v make >/dev/null 2>&1; then
        make -C "$target" up
    else
        bash "$target/manage/scripts/lancer.sh" up "$target"
    fi
    echo "Ensuite : cd $target && make shell (ou ouvre le dossier dans VS Code : Reopen in Container)."
}
