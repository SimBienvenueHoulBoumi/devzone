#!/usr/bin/env bash
# Names of the workspace command during the English migration (#502, lot 3),
# sourced by manage/workspace.sh:
#   workspace_command <name>        French subcommand name turned into the English one
#   workspace_ports_command <name>  same for the ports subcommand
#   compatibility aliases of the renamed functions, kept until lot 4 (#509)
# Why: command_canonical (.devcontainer/command-aliases.sh) still gives the
# French name; workspace.sh switches on the English ones. bash 3.2 (macOS).

workspace_command() {
    case "${1:-}" in
        demarrer) echo start ;;
        arreter) echo stop ;;
        etat) echo status ;;
        copier-vers) echo copy-to ;;
        copier-depuis) echo copy-from ;;
        migrer) echo migrate ;;
        revenir) echo revert ;;
        nettoyer-docker) echo clean-docker ;;
        *) echo "${1:-}" ;;
    esac
}

workspace_ports_command() {
    case "${1:-}" in
        demarrer) echo start ;;
        arreter) echo stop ;;
        etat) echo status ;;
        *) echo "${1:-}" ;;
    esac
}

# compatibility aliases, removed with lot 4 (#509)
drapeau_kubectl() { kubectl_flag "$@"; }
drapeau_helm() { helm_flag "$@"; }
chemin_chart() { chart_path "$@"; }
image_par_defaut() { default_image_tag "$@"; }
demarrer() { start_workspace "$@"; }
arreter() { stop_workspace "$@"; }
etat() { status_workspace "$@"; }
copier_vers() { copy_to "$@"; }
copier_depuis() { copy_from "$@"; }
