#!/usr/bin/env bash
# Common helpers for migration tests (#403, workspace-migration.bats and
# workspace-retour.bats): fake docker and kubectl under $BATS_TEST_TMPDIR/bin.
# The "pod" is $T/pod, "Docker volumes" are folders under $T/volumes, the
# workstation is $T/workstation. No real volume or cluster is touched.

# Isolate HOME, relay and kubeconfig, create workstation, pod and fake tools.
migration_isolate() {
    load commun
    relais_docker_isole
    kube_isole
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CLI="$RACINE/manage/devzone"
    T="$BATS_TEST_TMPDIR"
    mkdir -p "$T/bin" "$T/workstation/workspace/alpha" "$T/workstation/workspace/beta" "$T/pod/workspaces/projets" "$T/pod/home/vscode"
    export FAKE_POD="$T/pod"
    echo "a" >"$T/workstation/workspace/alpha/a.txt"
    echo "b" >"$T/workstation/workspace/beta/b.txt"
    echo "ia=on" >"$T/workstation/.devzone.modules"
    echo "jq" >"$T/workstation/.devzone.paquets"
    cat >"$T/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
# Fake kubectl: pod is $FAKE_POD (/workspaces/projets and /home/vscode rerouted).
T="$BATS_TEST_TMPDIR"
echo "kubectl $*" >>"$T/kubectl.log"
reroute() {
    local a="${1//\/workspaces\/projets/$FAKE_POD/workspaces/projets}"
    printf '%s' "${a//\/home\/vscode/$FAKE_POD/home/vscode}"
}
[ "${1:-}" = config ] && { [ "${2:-}" = get-contexts ] && echo "${FAKE_CONTEXTS:-docker-desktop}"; exit 0; }
args=("$@"); verb=""; pos=(); i=0
while [ "$i" -lt "${#args[@]}" ]; do
    a="${args[$i]}"
    case "$a" in
        --context | --namespace | -c | -o) i=$((i + 1)) ;;
        --) break ;;
        -*) ;;
        *) if [ -z "$verb" ]; then verb="$a"; else pos+=("$a"); fi ;;
    esac
    i=$((i + 1))
done
case "$verb" in
    get)
        [ -n "${FAKE_CLUSTER_KO:-}" ] && exit 1
        [ "${pos[0]}" = pod ] && echo "${FAKE_PHASE:-Running}"
        ;;
    cp)
        [ -n "${FAKE_CP_FAIL:-}" ] && { echo "error: tar" >&2; exit 1; }
        if [[ "${pos[0]}" == devzone-workspace-0:* ]]; then
            src="$(reroute "${pos[0]#*:}")"; dest="${pos[1]}"
        else
            src="${pos[0]}"; dest="$(reroute "${pos[1]#*:}")"
        fi
        if [ -d "$src" ]; then
            mkdir -p "$dest" && cp -a "$src/." "$dest/"
            [ -n "${FAKE_CP_TRUNCATE:-}" ] && find "$dest" -type f | head -1 | xargs rm -f
        else
            mkdir -p "$(dirname "$dest")" && cp -a "$src" "$dest"
        fi
        ;;
    exec)
        idx=0; for a in "$@"; do idx=$((idx + 1)); [ "$a" = "--" ] && break; done
        cmd=("${@:idx + 1}")
        if [ "${cmd[0]}" = df ] && [ -n "${FAKE_DF_KO:-}" ]; then
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
# Fake docker: volumes are folders under $BATS_TEST_TMPDIR/volumes.
T="$BATS_TEST_TMPDIR"
echo "docker $*" >>"$T/docker.log"
case "$1 ${2:-}" in
    "info "*) exit 0 ;;
    "volume inspect") [ -d "$T/volumes/$3" ] ;;
    "volume rm") rm -rf "$T/volumes/$3" ;;
    "run --rm")
        vol="${4%%:*}"
        [ -n "${FAKE_DOCKER_RUN_KO:-}" ] && exit 1
        tar cf - -C "$T/volumes/$vol" .
        ;;
esac
DOCKER
    chmod +x "$T/bin/kubectl" "$T/bin/docker"
    export PATH="$T/bin:$PATH"
    : >"$T/kubectl.log"
    : >"$T/docker.log"
}

# Create test Docker volumes (gh, m2) with one file each.
fake_volumes() {
    mkdir -p "$T/volumes/devzone-gh" "$T/volumes/devzone-m2"
    echo "token" >"$T/volumes/devzone-gh/hosts.yml"
    echo "jar" >"$T/volumes/devzone-m2/a.jar"
}

# Run a workspace subcommand from the test workstation folder.
ws() {
    cd "$T/workstation" && run bash "$CLI" workspace "$@"
}
