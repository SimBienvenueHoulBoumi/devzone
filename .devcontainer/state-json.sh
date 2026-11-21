#!/usr/bin/env bash
# Machine output of devzone status (--json): stable, versioned JSON object.
# Sourced by devzone: reuses its functions (value_of, description, …), does not
# rewrite etat(). Built only with jq. JSON keys are a contract: French names kept.

# Adds an entry to $errors: the section that failed and why.
add_error() {
    errors="$(jq -c --arg k "$1" --arg v "$2" '. + {($k): $v}' <<<"$errors")"
}

# Adds an alert (code, message, devzone command to run) to $alerts_json.
append_alert() {
    local code="$1" message="$2" command="${3:-}"
    alerts_json="$(jq -c \
        --arg code "$code" \
        --arg message "$message" \
        --arg command "$command" \
        '. + [{code:$code,message:$message,commande:(if $command=="" then null else $command end)}]' \
        <<<"$alerts_json")"
}

# Full state of the machine in JSON: repeats each section of etat() with the
# same commands, isolating each computation (failure → null value and errors).
state_json() {
    local errors='{}'
    local alerts_json='[]'
    local dv_raw="" dvp_raw=""
    local id_name="" id_email="" id_ok=false id_command=""
    local platform_name platform_url="" github_json="null"
    local tools_late_json='[]' tools_command=""
    local modules_json='[]' m active desc failure_file content state_value failure_value command_value out argocd_repo=""
    local docker_host=false docker_host_active=false relay_source
    local services_cluster="" services_remote=false
    local work_ctx="" work_internal=false host_ctx=""
    local clusters_services_raw="" clusters_work_raw="" clusters_command=""
    local ports_json='[]' ports_out
    local applications_json='[]'
    local credentials_raw=""
    local late_out package frozen installed count
    local relay_marker packages_marker packages_names n path wt_out
    local gh_status gh_code

    if v="$(folder_version 2>/dev/null)"; then
        dv_raw="$v"
    else
        add_error devzone "folder_version unavailable"
    fi
    dvp_raw="$(published_version 2>/dev/null || true)"

    id_name="$(git config --get user.name 2>/dev/null || true)"
    id_email="$(git config --get user.email 2>/dev/null || true)"
    if [ -n "$id_name" ] && [ -n "$id_email" ]; then
        id_ok=true
    else
        id_command='gh auth login -s workflow (automatic), or git config --file ~/.config/git/config user.name "<name>" and user.email "<email>"'
    fi

    platform_name="$(platform_read)"
    if [ "$platform_name" = gitlab ]; then
        platform_url="$(gitlab_url_read)"
    else
        platform_url=""
    fi
    if [ "$platform_name" = github ]; then
        gh_status="$(gh auth status 2>&1)" && gh_code=0 || gh_code=$?
        if [ "$gh_code" -ne 0 ]; then
            github_json="null"
            add_error github "gh auth status failed"
        else
            if printf '%s\n' "$gh_status" | grep -q "Token scopes:" && ! printf '%s\n' "$gh_status" | grep -q "'workflow'"; then
                github_json="$(jq -cn '{connecte:true,workflow:false,commande:"gh auth refresh -h github.com -s workflow"}')"
            else
                github_json="$(jq -cn '{connecte:true,workflow:true,commande:null}')"
            fi
        fi
    else
        github_json="null"
    fi

    if late_out="$(outdated_tools 2>/dev/null)"; then
        tools_late_json='[]'
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            # shellcheck disable=SC2086
            set -- $line
            package="${1:-}"; frozen="${2:-}"; installed="${3:-}"
            [ -n "$package" ] || continue
            tools_late_json="$(jq -c \
                --arg p "$package" --arg f "$frozen" --arg i "$installed" \
                '. + [{paquet:$p,figee:$f,installee:$i}]' <<<"$tools_late_json")"
        done <<<"$late_out"
        count="$(jq 'length' <<<"$tools_late_json" 2>/dev/null || echo 0)"
        if [ "$count" -gt 0 ]; then
            tools_command="devzone apply"
        fi
    else
        tools_late_json="null"
        add_error outils "outdated_tools unavailable"
    fi

    modules_json='[]'
    for m in "${MODULES[@]}"; do
        active=false
        [ "$(value_of "$m")" = on ] && active=true
        desc="$(description "$m")"
        failure_value=""
        state_value=""
        command_value=""
        if in_pod && service_module "$m"; then
            # Kubernetes workspace pod (#528): presence by the cluster DNS,
            # installation from the workstation; no failure marker read here
            if service_present "$m"; then
                state_value="active: $(service_dns "$m")"
            elif [ "$active" = true ]; then
                state_value="not in the cluster"
                command_value="devzone workspace services enable $m"
            else
                state_value="optional"
                command_value="devzone workspace services enable $m"
            fi
        elif [ "$active" = true ]; then
            failure_file="$(failure_marker_file "$m")"
            if [ -f "$failure_file" ]; then
                content="$(cat "$failure_file" 2>/dev/null || true)"
                failure_value="$content"
                state_value="failed"
                command_value="devzone apply"
            elif [ "$m" = gitlab ]; then
                if out="$(bash "$ICI/gitlab/gitlab.sh" status 2>/dev/null)"; then
                    state_value="$out"
                else
                    state_value=""
                    add_error modules "gitlab.sh status unavailable"
                fi
            elif [ "$m" = postgres ] || [ "$m" = llm ]; then
                if out="$(bash "$ICI/$m/$m.sh" status 2>/dev/null)"; then
                    state_value="$out"
                else
                    state_value=""
                    add_error modules "$m.sh state unavailable"
                fi
            elif [ "$m" = argocd ]; then
                if out="$(bash "$ICI/argocd/argocd.sh" status 2>/dev/null)"; then
                    state_value="$out"
                else
                    state_value=""
                    add_error modules "argocd.sh status unavailable"
                fi
            elif [ "$m" = mysql ]; then
                if out="$(bash "$ICI/catalog/mysql/mysql.sh" status 2>/dev/null)"; then
                    state_value="$out"
                else
                    state_value=""
                    add_error modules "mysql.sh status unavailable"
                fi
            else
                state_value="active"
            fi
        else
            state_value="optional"
            command_value="devzone enable $m"
        fi
        modules_json="$(jq -c \
            --arg name "$m" \
            --argjson active "$active" \
            --arg description "$desc" \
            --arg state "$state_value" \
            --arg failure "$failure_value" \
            --arg command "$command_value" \
            '. + [{nom:$name,actif:$active,description:$description,etat:(if $state=="" then null else $state end),echec:(if $failure=="" then null else $failure end),commande:(if $command=="" then null else $command end)}]' \
            <<<"$modules_json")"
    done

    # docker-hote option (#432): absent = on; socket really mounted (same
    # source as docker-relay.sh), may differ until make rebuild
    # In the Kubernetes workspace (DEVZONE_WORKSPACE=kubernetes), the pod has
    # no Docker host socket: the socket is absent (#515)
    if [ "${DEVZONE_WORKSPACE:-}" = kubernetes ]; then
        docker_host=false
        docker_host_active=false
    else
        if [ "$(value_of docker-hote)" = on ]; then
            docker_host=true
        fi
        relay_source="${DEVZONE_RELAIS_SOURCE:-/var/run/docker-host.sock}"
        if [ -e "$relay_source" ]; then
            docker_host_active=true
        fi
    fi

    services_cluster="$(cluster_saved)"
    if [ -n "$services_cluster" ] && ! cluster_is_local "$services_cluster"; then
        services_remote=true
    fi
    clusters_services_raw="$services_cluster"
    work_ctx="$(kubectl config current-context 2>/dev/null || true)"
    case "$work_ctx" in
        kind-gitlab* | kind-devzone*)
            host_ctx="$(KUBECONFIG="${DEVZONE_KUBE_HOTE:-$HOME/.kube/hote.config}" kubectl config current-context 2>/dev/null || true)"
            if [ -n "$host_ctx" ] && cluster_reachable "$host_ctx" 2>/dev/null; then
                work_internal=true
            fi
            ;;
    esac
    clusters_work_raw="$work_ctx"
    if [ "$work_internal" = true ]; then
        clusters_command="devzone use $host_ctx"
    fi

    if ports_out="$(bash "$ICI/ports.sh" list --json 2>/dev/null)"; then
        if printf '%s' "$ports_out" | jq -e . >/dev/null 2>&1; then
            ports_json="$ports_out"
        else
            ports_json="null"
            add_error ports "ports output unreadable"
        fi
    else
        ports_json="null"
        add_error ports "ports.sh unavailable"
    fi

    applications_json="$(bash "$ICI/catalog.sh" json 2>/dev/null || echo '[]')"
    if ! printf '%s' "$applications_json" | jq -e . >/dev/null 2>&1; then
        applications_json='[]'
        add_error modules "catalog.sh json unavailable"
    fi

    if [ -f "$RACINE/.password" ]; then
        credentials_raw="$RACINE/.password"
    fi

    relay_marker="${DEVZONE_RELAIS_MARQUE:-/tmp/devzone-relais-docker.echec}"
    if [ -f "$relay_marker" ]; then
        msg="$(head -1 "$relay_marker" 2>/dev/null || true)"
        append_alert relais_docker "$msg" "devzone repair"
    fi
    packages_marker="${DEVZONE_PAQUETS_MARQUE:-/tmp/devzone-paquets.echec}"
    if [ -f "$packages_marker" ]; then
        packages_names=""
        while IFS= read -r n; do
            [ -n "$n" ] || continue
            packages_names="${packages_names:+$packages_names, }$n"
        done < "$packages_marker"
        append_alert paquets "$packages_names" "devzone packages"
    fi
    wt_out="$(missing_worktrees 2>/dev/null || true)"
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        append_alert worktree "$path missing here (created outside the container?)" ""
    done <<<"$wt_out"
    if [ -n "$services_cluster" ] && ! cluster_is_local "$services_cluster"; then
        append_alert cluster_distant "remote cluster: $services_cluster — services on a remote cluster" ""
    fi
    if [ "$work_internal" = true ]; then
        append_alert cluster_interne "work cluster: $work_ctx (devzone internal cluster)" "devzone use $host_ctx"
    fi

    argocd_repo="$(conf_get argocd repo)"

    jq -n \
        --argjson schema 1 \
        --arg dv "$dv_raw" \
        --arg dvp "$dvp_raw" \
        --argjson id_ok "$id_ok" \
        --arg id_name "$id_name" \
        --arg id_email "$id_email" \
        --arg id_command "$id_command" \
        --arg platform_name "$platform_name" \
        --arg platform_url "$platform_url" \
        --argjson github "$github_json" \
        --argjson tools_late "$tools_late_json" \
        --arg tools_command "$tools_command" \
        --argjson modules "$modules_json" \
        --arg argocd_repo "$argocd_repo" \
        --argjson docker_host "$docker_host" \
        --argjson docker_host_active "$docker_host_active" \
        --arg clusters_services "$clusters_services_raw" \
        --argjson services_remote "$services_remote" \
        --arg clusters_work "$clusters_work_raw" \
        --argjson work_internal "$work_internal" \
        --arg clusters_command "$clusters_command" \
        --argjson ports "$ports_json" \
        --argjson applications "$applications_json" \
        --arg credentials "$credentials_raw" \
        --argjson alerts "$alerts_json" \
        --argjson errors "$errors" \
        '{
            schema: $schema,
            devzone: { version: (if $dv=="" then null else $dv end), disponible: (if $dvp=="" then null else $dvp end) },
            identite_git: { ok: $id_ok, nom: (if $id_name=="" then null else $id_name end), email: (if $id_email=="" then null else $id_email end), commande: (if $id_command=="" then null else $id_command end) },
            plateforme: { nom: $platform_name, url: (if $platform_url=="" then null else $platform_url end), github: $github },
            argocd_repo: (if $argocd_repo == "" then null else $argocd_repo end),
            outils: { retards: $tools_late, commande: (if $tools_command=="" then null else $tools_command end) },
            modules: $modules,
            docker_hote: $docker_host,
            docker_hote_actif: $docker_host_active,
            clusters: { services: (if $clusters_services=="" then null else $clusters_services end), services_distant: $services_remote, travail: (if $clusters_work=="" then null else $clusters_work end), travail_interne: $work_internal, commande: (if $clusters_command=="" then null else $clusters_command end) },
            ports: $ports,
            applications: (if $applications=="" then null else $applications end),
            identifiants: (if $credentials=="" then null else $credentials end),
            alertes: $alerts,
            erreurs: $errors
        }'
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    state_json
fi
