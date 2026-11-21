#!/usr/bin/env bash
# Renamed names of the devzone CLI (#695): the French names of the commands,
# subcommands and options are no longer accepted, they are refused. Each old
# name prints « ✖ « old » was renamed: devzone new » on stderr, exits with
# code 1 and does nothing (no folder is created: « devzone stop » creates ./stop,
# « devzone mettre-a-jour » must not create ./mettre-a-jour).
#
# renamed_command <name>              : English name of a renamed command, or 1
# renamed_subcommand <command> <name> : English name of a renamed subcommand, or 1
# renamed_option <option>             : English name of a renamed option, or 1
# reject_renamed <command> <args...>  : refuses the first renamed name of a call
#                                       (command, first word that is not an
#                                       option, then each option); 0 if none
#
# bash 3.2 (macOS): case only, no associative array.

# English name of a renamed command, or return 1.
renamed_command() {
    case "${1:-}" in
        actif) echo is-enabled ;;
        activer) echo enable ;;
        desactiver) echo disable ;;
        ia) echo ai ;;
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
        *) return 1 ;;
    esac
}

# English name of a renamed subcommand of <command> (English name), or return 1.
renamed_subcommand() {
    local command="${1:-}" word="${2:-}"
    case "$command" in
        postgres | mysql)
            case "$word" in
                creer) echo create ;;
                liste) echo list ;;
                supprimer) echo delete ;;
                supprimer-donnees) echo delete-data ;;
                etat) echo status ;;
                installer) echo install ;;
                desinstaller) echo uninstall ;;
                relais-lancer) echo relay-start ;;
                relais-arreter) echo relay-stop ;;
                autoriser) echo authorize ;;
                interdire) echo forbid ;;
                *) return 1 ;;
            esac
            ;;
        gitlab)
            case "$word" in
                migrer) echo migrate ;;
                nouveau-mdp) echo new-password ;;
                etat) echo status ;;
                installer) echo install ;;
                desinstaller) echo uninstall ;;
                relais-lancer) echo relay-start ;;
                relais-arreter) echo relay-stop ;;
                relais-etat) echo relay-status ;;
                *) return 1 ;;
            esac
            ;;
        argocd)
            case "$word" in
                etat) echo status ;;
                installer) echo install ;;
                desinstaller) echo uninstall ;;
                relais-lancer) echo relay-start ;;
                relais-arreter) echo relay-stop ;;
                *) return 1 ;;
            esac
            ;;
        packages)
            case "$word" in
                ajouter) echo add ;;
                retirer) echo remove ;;
                appliquer) echo apply ;;
                lister) echo list ;;
                *) return 1 ;;
            esac
            ;;
        catalog)
            case "$word" in
                synchroniser) echo sync ;;
                appliquer) echo apply ;;
                lister) echo list ;;
                desinstaller) echo remove ;;
                *) return 1 ;;
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
                *) return 1 ;;
            esac
            ;;
        workspace)
            case "$word" in
                demarrer) echo start ;;
                mettre-a-jour) echo update ;;
                arreter) echo stop ;;
                etat) echo status ;;
                copier-vers) echo copy-to ;;
                copier-depuis) echo copy-from ;;
                aide) echo help ;;
                *) return 1 ;;
            esac
            ;;
        "workspace ports")
            case "$word" in
                demarrer) echo start ;;
                arreter) echo stop ;;
                etat) echo status ;;
                *) return 1 ;;
            esac
            ;;
        agent)
            case "$word" in
                etat) echo state ;;
                liberer) echo release ;;
                aide) echo help ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

# English name of a renamed option, or return 1.
renamed_option() {
    case "${1:-}" in
        --fermer) echo --close ;;
        --supprimer) echo --delete ;;
        --nouveau-mdp) echo --new-password ;;
        --oui) echo --yes ;;
        --confirmer) echo --confirm ;;
        --contexte) echo --context ;;
        --modele) echo --model ;;
        --tous) echo --all ;;
        *) return 1 ;;
    esac
}

# Names removed in 3.0 (#735): refused with the same exit code, with a notice
# that names no former feature and never creates a folder.
removed_notice() {
    echo "✖ this command or option was removed in devzone 3.0 (see manage/docs/migrating-to-3.md)" >&2
    return 1
}

# reject_renamed <command> <args...> : checks the command itself (top level),
# the first word of <args> that is not an option (subcommand), then every
# option. The first renamed name prints its message on stderr and returns 1;
# nothing is run. Returns 0 when no name is renamed.
reject_renamed() {
    local command="${1:-}" word new
    if [ "$#" -gt 0 ]; then shift; fi
    case "$command" in
        migrer | revenir | nettoyer-docker) removed_notice; return 1 ;;
    esac
    if new="$(renamed_command "$command")"; then
        # these commands only exist under « devzone workspace »
        case "$command" in
            copier-vers | copier-depuis) new="workspace $new" ;;
        esac
        printf '✖ « %s » was renamed: devzone %s\n' "$command" "$new" >&2
        return 1
    fi
    for word in "$@"; do
        case "$word" in
            -*) continue ;;
        esac
        if [ "$command" = workspace ]; then
            case "$word" in
                migrer | revenir | nettoyer-docker) removed_notice; return 1 ;;
            esac
        fi
        if new="$(renamed_subcommand "$command" "$word")"; then
            printf '✖ « %s » was renamed: devzone %s %s\n' "$word" "$command" "$new" >&2
            return 1
        fi
        break
    done
    for word in "$@"; do
        case "$word" in
            --rapatrier) removed_notice; return 1 ;;
            -*)
                if new="$(renamed_option "$word")"; then
                    printf '✖ « %s » was renamed: %s\n' "$word" "$new" >&2
                    return 1
                fi
                ;;
        esac
    done
    return 0
}
