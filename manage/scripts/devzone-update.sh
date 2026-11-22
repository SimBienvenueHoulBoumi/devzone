#!/usr/bin/env bash
# Update of a devzone (devzone update [--yes] [--no-rebuild]): replaces
# the files of the package, backs up the replaced or removed ones, removes the
# old layout, then offers the rebuild. Sourced by manage/devzone, after
# devzone-manifest.sh, which provides the manifest helpers.
# shellcheck disable=SC2154 # PAQUET: set by manage/devzone

# Starts the port watcher again when the legacy names migration stopped it: it
# leaves the file restart in the watcher folder, which a start or a stop by the
# user removes, so a watcher the user stopped is never started here. Called once
# the new files are in place. DEVZONE_PORTS_RESTART replaces the command (tests).
restart_ports_watcher() {
    local folder="$1" marker="$1/.devzone.workspace-ports/restart"
    [ -f "$marker" ] || return 0
    rm -f "$marker"
    if [ -n "${DEVZONE_PORTS_RESTART:-}" ]; then
        (cd "$folder" && sh -c "$DEVZONE_PORTS_RESTART")
    else
        (cd "$folder" && bash manage/workspace.sh ports start)
    fi || echo "devzone : port watcher not restarted: devzone workspace ports start" >&2
}

# Six steps of the update design (#349)
update_workstation() {
    local assume_yes="" no_rebuild="" arg folder package installed package_list old_list
    local missing rel current expected answer backup base n old f
    for arg in "$@"; do
        case "$arg" in
            --yes) assume_yes=1 ;;
            --no-rebuild) no_rebuild=1 ;;
            *)
                echo "✖ unknown option: $arg (devzone update [--yes] [--no-rebuild])" >&2
                exit 1
                ;;
        esac
    done
    if [ ! -d .devcontainer ]; then
        echo "✖ À lancer dans un dossier devzone (.devcontainer introuvable ici)." >&2
        exit 1
    fi

    folder="$(pwd)"
    package="$(version)"
    installed="$(folder_version "$folder")"
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    package_list="$work/package-files"
    old_list="$work/old-files"
    relative_package_files >"$package_list"
    manifest_files "$folder" | LC_ALL=C sort >"$old_list"

    # 1. Versions and package files present
    missing=""
    while IFS= read -r rel; do
        [ -f "$folder/$rel" ] || missing=1
    done <"$package_list"
    if [ "$installed" = "$package" ] && [ -z "$missing" ]; then
        echo "✔ devzone $installed : déjà à jour."
        echo "Pour la dernière version publiée : npx devzone@latest update"
        return 0
    fi
    echo "devzone : dossier $installed, paquet $package"

    # 2. Files modified locally (checksum different from the manifest; without
    # a manifest, different from the one of the package)
    : >"$work/modified"
    : >"$work/to_save"
    : >"$work/to_remove"
    : >"$work/old_trees"
    while IFS= read -r rel; do
        [ -f "$folder/$rel" ] || continue
        printf '%s\n' "$rel" >>"$work/to_save"
        current="$(checksum "$folder/$rel")"
        if expected="$(manifest_checksum "$folder" "$rel")"; then
            :
        else
            expected="$(checksum "$PAQUET/$rel")"
        fi
        [ "$current" = "$expected" ] || printf '%s\n' "$rel" >>"$work/modified"
    done <"$package_list"
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        if ! path_allowed "$rel"; then
            echo "devzone : manifeste : chemin refusé : $rel" >&2
            continue
        fi
        in_list "$package_list" "$rel" && continue
        is_protected "$rel" && continue
        if ! inside_folder "$folder" "$rel"; then
            echo "devzone : manifeste : chemin refusé : $rel" >&2
            continue
        fi
        printf '%s\n' "$rel" >>"$work/to_remove"
        [ -f "$folder/$rel" ] || continue
        printf '%s\n' "$rel" >>"$work/to_save"
        if expected="$(manifest_checksum "$folder" "$rel")"; then
            [ "$(checksum "$folder/$rel")" = "$expected" ] || printf '%s\n' "$rel" >>"$work/modified"
        else
            printf '%s\n' "$rel" >>"$work/modified"
        fi
    done <"$old_list"
    for old in core scripts; do
        [ -d "$folder/$old" ] || continue
        old_tree "$folder" "$old" || continue
        printf '%s\n' "$old" >>"$work/old_trees"
        while IFS= read -r f; do
            rel="${f#"$folder"/}"
            if ! path_allowed "$rel"; then
                echo "devzone : manifeste : chemin refusé : $rel" >&2
                continue
            fi
            is_protected "$rel" && continue
            # A file unknown to the old package belongs to the user
            known_old_file "$rel" || continue
            printf '%s\n' "$rel" >>"$work/to_remove"
            printf '%s\n' "$rel" >>"$work/to_save"
            # Always confirmed: removing a file of the old package is a change,
            # even with a manifest
            printf '%s\n' "$rel" >>"$work/modified"
        done < <(find "$folder/$old" -type f -print)
    done
    LC_ALL=C sort -u "$work/modified" >"$work/modified.sorted"
    mv "$work/modified.sorted" "$work/modified"
    LC_ALL=C sort -u "$work/to_save" >"$work/to_save.sorted"
    mv "$work/to_save.sorted" "$work/to_save"

    if [ -s "$work/modified" ]; then
        echo "Fichiers modifiés localement :"
        while IFS= read -r rel; do
            printf '  %s\n' "$rel"
        done <"$work/modified"
        if [ -z "$assume_yes" ]; then
            if [ ! -t 0 ]; then
                echo "✖ Fichiers modifiés localement : relance avec --yes pour les remplacer (sauvegarde dans .devzone.backup/)." >&2
                exit 1
            fi
            printf 'Replace these files (backup in .devzone.backup/)? [y/N] ' >&2
            read -r answer || answer=""
            case "$answer" in
                y | Y | yes) ;;
                *)
                    echo "Abandon : rien n'a été modifié."
                    return 1
                    ;;
            esac
        fi
    fi

    # Former French names renamed before the backup (#733): the backup folder is
    # .devzone.backup. The script comes from the package, the folder may be old
    DEVZONE_ROOT="$folder" bash "$PAQUET/.devcontainer/rename-legacy-files.sh" || true

    # 3. Backup of every file replaced or removed
    if [ -s "$work/to_save" ]; then
        base="$folder/.devzone.backup/$(date +%Y%m%d-%H%M%S)"
        backup="$base"
        n=1
        while [ -e "$backup" ]; do
            n=$((n + 1))
            backup="$base-$n"
        done
        while IFS= read -r rel; do
            [ -f "$folder/$rel" ] || continue
            if ! inside_folder "$folder" "$rel"; then
                echo "devzone : manifeste : chemin refusé : $rel" >&2
                continue
            fi
            mkdir -p "$backup/$(dirname "$rel")"
            # -P: a link is backed up as it is, never its target
            cp -P -p "$folder/$rel" "$backup/$rel"
        done <"$work/to_save"
        echo "Sauvegarde : $backup"
    fi

    # 4. Replacement, removal of the old package and of the old layout,
    # .gitignore completed without being overwritten
    complete_gitignore "$folder"
    while IFS= read -r rel; do
        mkdir -p "$folder/$(dirname "$rel")"
        if ! inside_folder "$folder" "$rel"; then
            echo "devzone : manifeste : chemin refusé : $rel" >&2
            continue
        fi
        # Never write through a link: the link (not its target) is removed
        if [ -L "$folder/$rel" ]; then
            rm -f -- "$folder/$rel"
            echo "devzone : manifeste : lien remplacé : $rel" >&2
        fi
        cp -p "$PAQUET/$rel" "$folder/$rel"
        if [ -x "$PAQUET/$rel" ]; then
            chmod +x "$folder/$rel"
        fi
    done <"$package_list"
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        [ -f "$folder/$rel" ] || continue
        if ! inside_folder "$folder" "$rel"; then
            echo "devzone : manifeste : chemin refusé : $rel" >&2
            continue
        fi
        # rm does not follow links: only the link is removed, never its target
        rm -f -- "$folder/$rel"
    done <"$work/to_remove"
    while IFS= read -r old; do
        [ -n "$old" ] || continue
        [ -d "$folder/$old" ] || continue
        # Only the folders that became empty are removed, never their content
        find "$folder/$old" -depth -type d -empty -delete
    done <"$work/old_trees"

    # 6. New manifest, then rebuild offered
    write_manifest "$folder"
    echo "✔ devzone $package : mis à jour."
    restart_ports_watcher "$folder"
    bash "$PAQUET/manage/scripts/poste.sh" conseil "$folder" || true
    # the update never changes the workstation mode (#472)
    if [ "$(grep -E '^workspace=' "$folder/.devzone.modules" 2>/dev/null | tail -1)" = "workspace=kubernetes" ]; then
        return 0
    fi
    if [ -n "$no_rebuild" ]; then
        echo "Reconstruction non lancée (--no-rebuild)."
        return 0
    fi
    if [ ! -t 0 ]; then
        echo "Reconstruction : make -C $folder rebuild (à lancer dans un terminal)"
        return 0
    fi
    printf 'Rebuild the container now (make rebuild)? [y/N] ' >&2
    read -r answer || answer=""
    case "$answer" in
        y | Y | yes) ;;
        *)
            echo "Reconstruction non lancée : make -C $folder rebuild"
            return 0
            ;;
    esac
    if [ -n "${DEVZONE_REBUILD:-}" ]; then
        sh -c "$DEVZONE_REBUILD"
    else
        make -C "$folder" rebuild
    fi
}
