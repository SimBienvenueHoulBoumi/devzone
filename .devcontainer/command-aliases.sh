#!/usr/bin/env bash
# English command names for the devzone CLI (#502).
#
# Why: English command names are accepted now; the French names stay valid
# and warn on use (#532).
#
# command_canonical <name>: prints the current internal (French) name for an
# English name; otherwise the name unchanged (empty stays empty).
#
# Subcommands and options follow the same rule (#557): the table below gives
# the canonical English name of each French subcommand, per command, and the
# canonical English name of each French option.

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

# subcommand_canonical <command> <word> : the canonical English name of a
# subcommand of a command (#557). The French names are accepted and warn on
# use; an unknown word is printed unchanged.
subcommand_canonical() {
    local command="${1:-}" word="${2:-}"
    case "$command" in
        postgres | mysql)
            case "$word" in
                creer) echo create ;;
                liste) echo list ;;
                supprimer) echo delete ;;
                supprimer-donnees) echo delete-data ;;
                etat) echo status ;;
                relais-lancer) echo relay-start ;;
                relais-arreter) echo relay-stop ;;
                *) echo "$word" ;;
            esac
            ;;
        gitlab)
            case "$word" in
                migrer) echo migrate ;;
                nouveau-mdp) echo new-password ;;
                etat) echo status ;;
                relais-lancer) echo relay-start ;;
                relais-arreter) echo relay-stop ;;
                relais-etat) echo relay-status ;;
                *) echo "$word" ;;
            esac
            ;;
        argocd)
            case "$word" in
                etat) echo status ;;
                relais-lancer) echo relay-start ;;
                relais-arreter) echo relay-stop ;;
                *) echo "$word" ;;
            esac
            ;;
        packages)
            case "$word" in
                ajouter) echo add ;;
                retirer) echo remove ;;
                appliquer) echo apply ;;
                lister) echo list ;;
                *) echo "$word" ;;
            esac
            ;;
        catalog)
            case "$word" in
                synchroniser) echo sync ;;
                appliquer) echo apply ;;
                lister) echo list ;;
                desinstaller) echo remove ;;
                *) echo "$word" ;;
            esac
            ;;
        port)
            case "$word" in
                ouvrir) echo open ;;
                fermer) echo close ;;
                liste) echo list ;;
                relancer) echo restart ;;
                exclure) echo exclude ;;
                inclure) echo include ;;
                *) echo "$word" ;;
            esac
            ;;
        *) echo "$word" ;;
    esac
}

# option_canonical <word> : the canonical English name of an option (#557);
# an unknown option is printed unchanged.
option_canonical() {
    case "${1:-}" in
        --fermer) echo --close ;;
        --nouveau-mdp) echo --new-password ;;
        --oui) echo --yes ;;
        --confirmer) echo --confirm ;;
        --contexte) echo --context ;;
        *) echo "${1:-}" ;;
    esac
}

# Deprecation warning for the old French subcommands (#557): same format and
# same DEVZONE_NO_DEPRECATION as command_deprecated_warning.
subcommand_deprecated_warning() {
    local command="${1:-}" word="${2:-}" english
    [ -n "$word" ] || return 0
    english="$(subcommand_canonical "$command" "$word")"
    [ "$english" != "$word" ] || return 0
    if [ "${DEVZONE_NO_DEPRECATION:-}" != 1 ]; then
        echo "devzone: \"$word\" is deprecated, use \"$english\"" >&2
    fi
    return 0
}

# Deprecation warning for the old French options (#557): same format and same
# DEVZONE_NO_DEPRECATION as command_deprecated_warning.
option_deprecated_warning() {
    local word="${1:-}" english
    [ -n "$word" ] || return 0
    english="$(option_canonical "$word")"
    [ "$english" != "$word" ] || return 0
    if [ "${DEVZONE_NO_DEPRECATION:-}" != 1 ]; then
        echo "devzone: \"$word\" is deprecated, use \"$english\"" >&2
    fi
    return 0
}

# canonical_args <command> <args...> : fills the global array ARGS_CANONICAL
# with the canonical English names of the arguments: the first word that is
# not an option is the subcommand, every option keeps its canonical English
# name. The old French names warn on use (#557).
canonical_args() {
    local command="${1:-}" word canon premier=1
    shift || true
    ARGS_CANONICAL=()
    for word in "$@"; do
        case "$word" in
            --*)
                option_deprecated_warning "$word"
                ARGS_CANONICAL+=("$(option_canonical "$word")")
                ;;
            *)
                if [ "$premier" = 1 ]; then
                    premier=0
                    canon="$(subcommand_canonical "$command" "$word")"
                    subcommand_deprecated_warning "$command" "$word"
                    word="$canon"
                fi
                ARGS_CANONICAL+=("$word")
                ;;
        esac
    done
    return 0
}
