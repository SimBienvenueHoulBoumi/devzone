#!/usr/bin/env bash
# Aide commune des tests de migration (#403, workspace-migration.bats et
# workspace-retour.bats) : faux docker et kubectl sous $BATS_TEST_TMPDIR/bin. Le
# « pod » est le dossier $T/pod, les « volumes Docker » sont les dossiers de
# $T/volumes, le poste est $T/poste. Aucun vrai volume, aucun cluster touche.

# Isole HOME, relais et kubeconfig, cree le poste, le pod et les faux outils.
migration_isole() {
    load commun
    relais_docker_isole
    kube_isole
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CLI="$RACINE/manage/devzone"
    T="$BATS_TEST_TMPDIR"
    mkdir -p "$T/bin" "$T/poste/workspace/alpha" "$T/poste/workspace/beta" "$T/pod/workspaces/projets" "$T/pod/home/vscode"
    export FAUX_POD="$T/pod"
    echo "a" >"$T/poste/workspace/alpha/a.txt"
    echo "b" >"$T/poste/workspace/beta/b.txt"
    echo "ia=on" >"$T/poste/.devzone.modules"
    echo "jq" >"$T/poste/.devzone.paquets"
    cat >"$T/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
# Faux kubectl : le pod est $FAUX_POD (/workspaces/projets et /home/vscode y sont reroutes).
T="$BATS_TEST_TMPDIR"
echo "kubectl $*" >>"$T/kubectl.log"
reroute() {
    local a="${1//\/workspaces\/projets/$FAUX_POD/workspaces/projets}"
    printf '%s' "${a//\/home\/vscode/$FAUX_POD/home/vscode}"
}
[ "${1:-}" = config ] && { [ "${2:-}" = get-contexts ] && echo "${FAUX_CONTEXTES:-docker-desktop}"; exit 0; }
args=("$@"); verbe=""; pos=(); i=0
while [ "$i" -lt "${#args[@]}" ]; do
    a="${args[$i]}"
    case "$a" in
        --context | --namespace | -c | -o) i=$((i + 1)) ;;
        --) break ;;
        -*) ;;
        *) if [ -z "$verbe" ]; then verbe="$a"; else pos+=("$a"); fi ;;
    esac
    i=$((i + 1))
done
case "$verbe" in
    get)
        [ -n "${FAUX_CLUSTER_KO:-}" ] && exit 1
        [ "${pos[0]}" = pod ] && echo "${FAUX_PHASE:-Running}"
        ;;
    cp)
        [ -n "${FAUX_CP_ECHEC:-}" ] && { echo "error: tar" >&2; exit 1; }
        if [[ "${pos[0]}" == devzone-workspace-0:* ]]; then
            src="$(reroute "${pos[0]#*:}")"; dest="${pos[1]}"
        else
            src="${pos[0]}"; dest="$(reroute "${pos[1]#*:}")"
        fi
        if [ -d "$src" ]; then
            mkdir -p "$dest" && cp -a "$src/." "$dest/"
            [ -n "${FAUX_CP_TRONQUE:-}" ] && find "$dest" -type f | head -1 | xargs rm -f
        else
            mkdir -p "$(dirname "$dest")" && cp -a "$src" "$dest"
        fi
        ;;
    exec)
        idx=0; for a in "$@"; do idx=$((idx + 1)); [ "$a" = "--" ] && break; done
        cmd=("${@:idx + 1}")
        if [ "${cmd[0]}" = df ] && [ -n "${FAUX_DF_KO:-}" ]; then
            printf 'Filesystem 1024-blocks Used Available Capacity Mounted\nx 10 9 1 90%% /\n'; exit 0
        fi
        for j in "${!cmd[@]}"; do cmd[j]="$(reroute "${cmd[j]}")"; done
        "${cmd[@]}"
        ;;
esac
exit 0
KUBE
    cat >"$T/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
# Faux docker : les volumes sont les dossiers de $BATS_TEST_TMPDIR/volumes.
T="$BATS_TEST_TMPDIR"
echo "docker $*" >>"$T/docker.log"
case "$1 ${2:-}" in
    "info "*) exit 0 ;;
    "volume inspect") [ -d "$T/volumes/$3" ] ;;
    "volume rm") rm -rf "$T/volumes/$3" ;;
    "run --rm")
        vol="${4%%:*}"
        [ -n "${FAUX_DOCKER_RUN_KO:-}" ] && exit 1
        tar cf - -C "$T/volumes/$vol" .
        ;;
esac
DOCKER
    chmod +x "$T/bin/kubectl" "$T/bin/docker"
    export PATH="$T/bin:$PATH"
    : >"$T/kubectl.log"
    : >"$T/docker.log"
}

# Cree des volumes Docker de test (gh, m2) avec un fichier chacun.
faux_volumes() {
    mkdir -p "$T/volumes/devzone-gh" "$T/volumes/devzone-m2"
    echo "token" >"$T/volumes/devzone-gh/hosts.yml"
    echo "jar" >"$T/volumes/devzone-m2/a.jar"
}

# Lance une sous-commande workspace depuis le dossier du poste de test.
ws() {
    cd "$T/poste" && run bash "$CLI" workspace "$@"
}
