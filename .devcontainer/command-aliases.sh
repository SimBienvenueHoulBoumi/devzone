#!/usr/bin/env bash
# English command names for the devzone CLI (#502).
#
# Why: English command names are accepted now; the French names stay valid
# and warn on use (#532).
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

# English name of a French (internal) name; any other name unchanged.
# Mirror of command_canonical, used by the deprecation warning (#532).
command_english() {
    case "${1:-}" in
        actif) echo is-enabled ;;
        activer) echo enable ;;
        desactiver) echo disable ;;
        aide) echo help ;;
        appliquer) echo apply ;;
        catalogue) echo catalog ;;
        demarrer) echo start ;;
        arreter) echo stop ;;
        etat) echo status ;;
        mots-de-passe) echo passwords ;;
        paquets) echo packages ;;
        plateforme) echo platform ;;
        reparer) echo repair ;;
        utiliser) echo use ;;
        mettre-a-jour) echo update ;;
        desinstaller) echo uninstall ;;
        copier-vers) echo copy-to ;;
        copier-depuis) echo copy-from ;;
        migrer) echo migrate ;;
        revenir) echo revert ;;
        nettoyer-docker) echo clean-docker ;;
        *) echo "${1:-}" ;;
    esac
}

# Deprecation warning for the old French names (#532): called at the
# normalization points, with the word as typed. Writes one line on stderr
# for a French name of the table; silent for an English name, an unknown
# name and DEVZONE_NO_DEPRECATION=1. The exit code is always 0.
command_deprecated_warning() {
    local word="${1:-}" english
    [ -n "$word" ] || return 0
    english="$(command_english "$word")"
    [ "$english" != "$word" ] || return 0
    if [ "${DEVZONE_NO_DEPRECATION:-}" != 1 ]; then
        echo "devzone: \"$word\" is deprecated, use \"$english\"" >&2
    fi
    return 0
}
