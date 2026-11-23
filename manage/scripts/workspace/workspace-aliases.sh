#!/usr/bin/env bash
# Compatibility aliases of the workspace functions renamed during the English
# migration (#502, lot 3), sourced by manage/workspace.sh. The old French names
# of the subcommands are refused by reject_renamed (.devcontainer/command-aliases.sh, #695).
# bash 3.2 (macOS).

# compatibility aliases, removed with lot 4 (#509); RACINE and ICI are still
# read by the scripts of the lot 5 files (argocd-*.sh, services-workspace.sh)
# shellcheck disable=SC2034
RACINE="$ROOT"
# shellcheck disable=SC2034
ICI="$HERE"
drapeau_kubectl() { kubectl_flag "$@"; }
drapeau_helm() { helm_flag "$@"; }
chemin_chart() { chart_path "$@"; }
image_par_defaut() { default_image_tag "$@"; }
demarrer() { start_workspace "$@"; }
arreter() { stop_workspace "$@"; }
etat() { status_workspace "$@"; }
