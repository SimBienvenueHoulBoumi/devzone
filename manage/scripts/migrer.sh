#!/usr/bin/env bash
# Migration from Docker workstation to Kubernetes workspace, and rollback (#403).
# Sourced by manage/workspace.sh: uses POD, NAMESPACE, PROJECTS_DIR,
# kubectl_flag, copy_to and copy_from. Nothing is ever deleted except by
# clean-docker, after confirmation. Run from the devzone workstation folder.

# vscode home in the pod and image used to copy Docker volumes.
POD_HOME="/home/vscode"
COPY_IMAGE="${DEVZONE_IMAGE_COPIE:-busybox:1.36}"
# Docker workstation volumes: devzone-<x>, or $DEVZONE_VOLUMES-<x> (functional tests).
DOCKER_VOLUMES=(gh git claude opencode-config opencode-data agent config m2 gradle pnpm)
# Folder size measurement ($1): "file count bytes".
# shellcheck disable=SC2016
MEASURE='n=$(find "$1" -type f | wc -l | tr -d " "); o=$(find "$1" -type f -exec wc -c {} + 2>/dev/null | awk '\''$2!="total"{s+=$1} END{print s+0}'\''); echo "$n $o"'

# Workstation kubectl, devzone context if it exists, workspace namespace.
kc() {
    local flag
    flag="$(kubectl_flag)"
    # shellcheck disable=SC2086
    kubectl $flag --namespace "$NAMESPACE" "$@"
}

# Clear error on stderr (exit code 1 returned by caller).
fail() {
    echo "✖ $*" >&2
}

# Reads the single accepted flag ($1) from following args ($3…): prints 1 if
# present, 0 otherwise; any other flag: error with usage ($2), exit code 1.
read_flag() {
    local flag="$1" usage="$2" a found=0 legacy=""
    shift 2
    case "$flag" in
        --yes) legacy="--oui" ;;
        --bring-back) legacy="--rapatrier" ;;
    esac
    for a in "$@"; do
        if [ "$a" = "$flag" ] || { [ -n "$legacy" ] && [ "$a" = "$legacy" ]; }; then found=1; continue; fi
        fail "unknown option: $a (devzone workspace $usage)"
        return 1
    done
    echo "$found"
}

# State volume path (relative to vscode home) for a devzone-<x> Docker volume;
# empty if the chart mounts none (persistence.state.paths).
state_path() {
    case "$1" in
        gh) echo .config/gh ;;
        git) echo .config/git ;;
        claude) echo .claude ;;
        opencode-config) echo .config/opencode ;;
        opencode-data) echo .local/share/opencode ;;
        agent) echo .local/state/oc-lancer ;;
        m2) echo .m2 ;;
        gradle) echo .gradle ;;
        pnpm) echo .local/share/pnpm ;;
    esac
}

# Docker volume name for <x>.
docker_volume() {
    printf '%s-%s' "${DEVZONE_VOLUMES:-devzone}" "$1"
}

# Asks [y/N] ($1: question, $2: 1 if --yes). Without terminal and without --yes: refuse.
confirm() {
    local reply=""
    [ "${2:-0}" = 1 ] && return 0
    if [ ! -t 0 ]; then
        echo "✖ no terminal: cannot confirm, run again with --yes" >&2
        return 1
    fi
    read -r -p "$1 [y/N] " reply || true
    case "$reply" in y | Y | yes | YES | Yes | o | O | oui | OUI | Oui) return 0 ;; esac
    echo "✖ canceled, nothing changed" >&2
    return 1
}

# Compares workstation folder ($1) with pod folder ($2): same files, same size.
verify_copy() {
    local local_state pod_state
    local_state="$(sh -c "$MEASURE" _ "$1")"
    pod_state="$(kc exec "$POD" -c workspace -- sh -c "$MEASURE" _ "$2")" || pod_state="unreadable"
    if [ "$local_state" != "$pod_state" ]; then
        fail "different copy for $2: workstation \"$local_state\", pod \"$pod_state\" (files bytes)"
        return 1
    fi
    echo "  ✔ $2: ${local_state% *} file(s), ${local_state#* } byte(s)"
}

# Step 1: cluster reachable, pod started, enough space for projects.
step_checks() {
    local phase needed free
    echo "▶ [1/5] checks: cluster, workspace, space"
    kc get --raw /readyz >/dev/null 2>&1 || {
        fail "unreachable cluster: check kubectl context (kubectl config get-contexts)"
        return 1
    }
    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        fail "Docker does not respond: devzone-* workstation volumes must be readable"
        return 1
    fi
    phase="$(kc get pod "$POD" -o 'jsonpath={.status.phase}' 2>/dev/null || true)"
    [ "$phase" = "Running" ] || { fail "workspace not started (pod $POD: ${phase:-missing}): devzone workspace start"; return 1; }
    needed=0
    [ -d workspace ] && needed="$(du -sk workspace | cut -f1)"
    free="$(kc exec "$POD" -c workspace -- df -Pk "$PROJECTS_DIR" | awk 'NR==2{print $4}')" || free=0
    if [ "${free:-0}" -lt "$needed" ]; then
        fail "not enough space on $PROJECTS_DIR: ${free:-0} KB free, $needed KB of projects"
        return 1
    fi
    echo "  ✔ cluster reachable, pod $POD ready, $free KB free for $needed KB of projects"
}

# Step 2: each project in ./workspace copied to the pod, then verified.
step_projects() {
    local d name
    echo "▶ [2/5] projects: ./workspace/<project> to $PROJECTS_DIR (.git included)"
    for d in workspace/*/; do
        [ -d "$d" ] || continue
        name="$(basename "$d")"
        echo "  … $name"
        (copy_to "$d") || { fail "project $name copy failed"; return 1; }
        verify_copy "$d" "$PROJECTS_DIR/$name" || return 1
    done
}

# Copies Docker volume <x> ($1) to $2 under pod home, through a read-only container.
copy_volume() {
    local v target="$POD_HOME/$2" tmp status=0
    v="$(docker_volume "$1")"
    tmp="$(mktemp -d)"
    if ! docker run --rm -v "$v:/src:ro" "$COPY_IMAGE" tar cf - -C /src . | tar xf - -C "$tmp"; then
        fail "volume $v read failed"
        status=1
    elif ! kc cp "$tmp/." "$POD:$target" -c workspace; then
        fail "volume $v copy to $target failed"
        status=1
    else
        verify_copy "$tmp" "$target" || status=1
    fi
    rm -rf "$tmp"
    return "$status"
}

# Step 3: identities and caches, Docker volumes to state volume paths.
step_identities() {
    local x path v
    echo "▶ [3/5] identities and caches: Docker volumes to state volume"
    for x in "${DOCKER_VOLUMES[@]}"; do
        path="$(state_path "$x")"
        v="$(docker_volume "$x")"
        if [ -z "$path" ]; then
            echo "  – $v: no path in chart, skipped"
        elif ! docker volume inspect "$v" >/dev/null 2>&1; then
            echo "  – $v: missing, ignored"
        else
            echo "  … $v → $POD_HOME/$path"
            copy_volume "$x" "$path" || return 1
        fi
    done
}

# Step 4: workstation .devzone.modules and .devzone.paquets copied to the pod.
step_state() {
    local f
    echo "▶ [4/5] state: .devzone.modules and .devzone.paquets to $PROJECTS_DIR"
    for f in .devzone.modules .devzone.paquets; do
        if [ ! -f "$f" ]; then
            echo "  – $f: missing on workstation, skipped"
            continue
        fi
        if ! kc cp "$PWD/$f" "$POD:$PROJECTS_DIR/$f" -c workspace \
            || ! kc exec "$POD" -c workspace -- test -f "$PROJECTS_DIR/$f"; then
            fail "failed to copy $f or missing from pod"
            return 1
        fi
        echo "  ✔ $f"
    done
}

# Writes workspace=$1 in workstation .devzone.modules (line replaced, rest kept).
record_workspace() {
    local f=".devzone.modules" tmp
    tmp="$f.tmp.$$"
    {
        if [ -f "$f" ]; then grep -v '^workspace=' "$f" || true; fi
        echo "workspace=$1"
    } >"$tmp" && mv "$tmp" "$f"
}

# Step 5: switch, workspace=kubernetes recorded on workstation; nothing is deleted.
step_switch() {
    echo "▶ [5/5] switch: workspace=kubernetes in .devzone.modules"
    record_workspace kubernetes || { fail "cannot write .devzone.modules"; return 1; }
    echo "  ✔ done; Docker workstation and its volumes are intact (rollback: devzone workspace revert)"
}

# devzone workspace migrate [--yes]: the five steps, stop at first error.
migrate_workspace() {
    local yes
    yes="$(read_flag --yes "migrate [--yes]" "$@")" || return 1
    confirm "Migrate this Docker workstation to the Kubernetes workspace (copy, nothing is deleted)?" "$yes" || return 1
    step_checks || return 1
    step_projects || return 1
    step_identities || return 1
    step_state || return 1
    step_switch || return 1
    echo "✔ migration complete"
}

# devzone workspace clean-docker [--yes]: removes devzone-* Docker volumes, after confirmation.
clean_docker() {
    local yes x v present=()
    yes="$(read_flag --yes "clean-docker [--yes]" "$@")" || return 1
    for x in "${DOCKER_VOLUMES[@]}"; do
        v="$(docker_volume "$x")"
        ! docker volume inspect "$v" >/dev/null 2>&1 || present+=("$v")
    done
    if [ "${#present[@]}" -eq 0 ]; then
        echo "No devzone Docker volume to remove."
        return 0
    fi
    echo "Docker volumes to remove (irreversible, \"revert\" will not find them again):"
    printf '  %s\n' "${present[@]}"
    confirm "Remove these ${#present[@]} volume(s)?" "$yes" || return 1
    for v in "${present[@]}"; do
        docker volume rm "$v" >/dev/null || { fail "failed to remove $v"; return 1; }
        echo "  ✔ $v removed"
    done
}

# compatibility aliases, removed with lot 4 (#509)
lire_option() { read_flag "$@"; }
confirmer() { confirm "$@"; }
noter_workspace() { record_workspace "$@"; }
migrer() { migrate_workspace "$@"; }
nettoyer_docker() { clean_docker "$@"; }
echec() { fail "$@"; }
