#!/usr/bin/env bash
# English command names for the devzone CLI (#502).
#
# Why: English command names are accepted now; the French names stay valid.
# Deprecation warnings come with the documentation lot (#502).
#
# command_canonical <name>: prints the current internal (French) name for an
# English name; otherwise the name unchanged (empty stays empty).

command_canonical() {
    case "${1:-}" in
        is-enabled) echo actif ;;
        enable) echo activer ;;
        disable) echo desactiver ;;
        help) echo aide ;;
        apply) echo appliquer ;;
        catalog) echo catalogue ;;
        start) echo demarrer ;;
        stop) echo arreter ;;
        status) echo etat ;;
        passwords) echo mots-de-passe ;;
        packages) echo paquets ;;
        platform) echo plateforme ;;
        repair) echo reparer ;;
        use) echo utiliser ;;
        update) echo mettre-a-jour ;;
        uninstall) echo desinstaller ;;
        copy-to) echo copier-vers ;;
        copy-from) echo copier-depuis ;;
        migrate) echo migrer ;;
        revert) echo revenir ;;
        clean-docker) echo nettoyer-docker ;;
        *) echo "${1:-}" ;;
    esac
}
