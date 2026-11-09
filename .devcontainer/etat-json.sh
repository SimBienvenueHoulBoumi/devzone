#!/usr/bin/env bash
# Sortie machine de devzone etat (--json) : objet JSON stable et versionné.
# Sourcé par devzone : réutilise ses fonctions (valeur, description, …), ne
# réécrit pas etat(). Construit uniquement avec jq (échappement garanti).

# Ajoute une entrée à $erreurs : la rubrique qui a échoué et pourquoi.
ajouter_erreur() {
    erreurs="$(jq -c --arg k "$1" --arg v "$2" '. + {($k): $v}' <<<"$erreurs")"
}

# Ajoute une alerte (code, message, commande devzone à lancer) à $alertes_json.
append_alerte() {
    local code="$1" message="$2" commande="${3:-}"
    alertes_json="$(jq -c \
        --arg code "$code" \
        --arg message "$message" \
        --arg commande "$commande" \
        '. + [{code:$code,message:$message,commande:(if $commande=="" then null else $commande end)}]' \
        <<<"$alertes_json")"
}

# État complet du poste en JSON : reprend chaque rubrique de etat() avec les
# mêmes commandes, en isolant chaque calcul (échec → valeur null et erreurs).
etat_json() {
    local erreurs='{}'
    local alertes_json='[]'
    local dv_raw="" dvp_raw=""
    local id_nom="" id_email="" id_ok=false id_commande=""
    local plat_nom plat_url="" github_json="null"
    local outils_retards_json='[]' outils_commande=""
    local modules_json='[]' m actif desc ef content etat_val echec_val commande_val s
    local services_cluster="" services_distant=false
    local travail_ctx="" travail_interne=false ctx_hote=""
    local clusters_services_raw="" clusters_travail_raw="" clusters_commande=""
    local ports_json='[]' ports_out
    local identifiants_raw=""
    local retards_out paquet figee installee count
    local relais_marque paquets_marque paquets_noms n chemin wt_out
    local gh_statut gh_code

    if v="$(version_du_dossier 2>/dev/null)"; then
        dv_raw="$v"
    else
        ajouter_erreur devzone "version_du_dossier indisponible"
    fi
    dvp_raw="$(version_publiee 2>/dev/null || true)"

    id_nom="$(git config --get user.name 2>/dev/null || true)"
    id_email="$(git config --get user.email 2>/dev/null || true)"
    if [ -n "$id_nom" ] && [ -n "$id_email" ]; then
        id_ok=true
    else
        id_commande='gh auth login -s workflow (automatique), ou git config --file ~/.config/git/config user.name "<nom>" et user.email "<email>"'
    fi

    plat_nom="$(plateforme_lue)"
    if [ "$plat_nom" = gitlab ]; then
        plat_url="$(url_gitlab_lue)"
    else
        plat_url=""
    fi
    if [ "$plat_nom" = github ]; then
        gh_statut="$(gh auth status 2>&1)" && gh_code=0 || gh_code=$?
        if [ "$gh_code" -ne 0 ]; then
            github_json="null"
            ajouter_erreur github "gh auth status a échoué"
        else
            if printf '%s\n' "$gh_statut" | grep -q "Token scopes:" && ! printf '%s\n' "$gh_statut" | grep -q "'workflow'"; then
                github_json="$(jq -cn '{connecte:true,workflow:false,commande:"gh auth refresh -h github.com -s workflow"}')"
            else
                github_json="$(jq -cn '{connecte:true,workflow:true,commande:null}')"
            fi
        fi
    else
        github_json="null"
    fi

    if retards_out="$(outils_retard 2>/dev/null)"; then
        outils_retards_json='[]'
        while IFS= read -r ligne; do
            [ -n "$ligne" ] || continue
            # shellcheck disable=SC2086
            set -- $ligne
            paquet="${1:-}"; figee="${2:-}"; installee="${3:-}"
            [ -n "$paquet" ] || continue
            outils_retards_json="$(jq -c \
                --arg p "$paquet" --arg f "$figee" --arg i "$installee" \
                '. + [{paquet:$p,figee:$f,installee:$i}]' <<<"$outils_retards_json")"
        done <<<"$retards_out"
        count="$(jq 'length' <<<"$outils_retards_json" 2>/dev/null || echo 0)"
        if [ "$count" -gt 0 ]; then
            outils_commande="devzone appliquer"
        fi
    else
        outils_retards_json="null"
        ajouter_erreur outils "outils_retard indisponible"
    fi

    modules_json='[]'
    for m in "${MODULES[@]}"; do
        actif=false
        [ "$(valeur "$m")" = on ] && actif=true
        desc="$(description "$m")"
        echec_val=""
        etat_val=""
        commande_val=""
        if [ "$actif" = true ]; then
            ef="$(fichier_echec "$m")"
            if [ -f "$ef" ]; then
                content="$(cat "$ef" 2>/dev/null || true)"
                echec_val="$content"
                etat_val="en échec"
                commande_val="devzone appliquer"
            elif [ "$m" = gitlab ]; then
                if s="$(bash "$ICI/gitlab/gitlab.sh" etat 2>/dev/null)"; then
                    etat_val="$s"
                else
                    etat_val=""
                    ajouter_erreur modules "gitlab.sh etat indisponible"
                fi
            elif [ "$m" = postgres ]; then
                if s="$(bash "$ICI/postgres/postgres.sh" etat 2>/dev/null)"; then
                    etat_val="$s"
                else
                    etat_val=""
                    ajouter_erreur modules "postgres.sh etat indisponible"
                fi
            elif [ "$m" = argocd ]; then
                if s="$(bash "$ICI/argocd/argocd.sh" etat 2>/dev/null)"; then
                    etat_val="$s"
                else
                    etat_val=""
                    ajouter_erreur modules "argocd.sh etat indisponible"
                fi
            else
                etat_val="actif"
            fi
        else
            etat_val="facultatif"
            commande_val="devzone activer $m"
        fi
        modules_json="$(jq -c \
            --arg nom "$m" \
            --argjson actif "$actif" \
            --arg description "$desc" \
            --arg etat "$etat_val" \
            --arg echec "$echec_val" \
            --arg commande "$commande_val" \
            '. + [{nom:$nom,actif:$actif,description:$description,etat:(if $etat=="" then null else $etat end),echec:(if $echec=="" then null else $echec end),commande:(if $commande=="" then null else $commande end)}]' \
            <<<"$modules_json")"
    done

    services_cluster="$(cluster_lu)"
    if [ -n "$services_cluster" ] && ! cluster_est_local "$services_cluster"; then
        services_distant=true
    fi
    clusters_services_raw="$services_cluster"
    travail_ctx="$(kubectl config current-context 2>/dev/null || true)"
    case "$travail_ctx" in
        kind-gitlab* | kind-devzone*)
            ctx_hote="$(KUBECONFIG="${DEVZONE_KUBE_HOTE:-$HOME/.kube/hote.config}" kubectl config current-context 2>/dev/null || true)"
            if [ -n "$ctx_hote" ] && cluster_joignable "$ctx_hote" 2>/dev/null; then
                travail_interne=true
            fi
            ;;
    esac
    clusters_travail_raw="$travail_ctx"
    if [ "$travail_interne" = true ]; then
        clusters_commande="devzone utiliser $ctx_hote"
    fi

    if ports_out="$(bash "$ICI/ports.sh" liste --json 2>/dev/null)"; then
        if printf '%s' "$ports_out" | jq -e . >/dev/null 2>&1; then
            ports_json="$ports_out"
        else
            ports_json="null"
            ajouter_erreur ports "sortie ports illisible"
        fi
    else
        ports_json="null"
        ajouter_erreur ports "ports.sh indisponible"
    fi

    if [ -f "$RACINE/.password" ]; then
        identifiants_raw="$RACINE/.password"
    fi

    relais_marque="${DEVZONE_RELAIS_MARQUE:-/tmp/devzone-relais-docker.echec}"
    if [ -f "$relais_marque" ]; then
        msg="$(head -1 "$relais_marque" 2>/dev/null || true)"
        append_alerte relais_docker "$msg" "devzone reparer"
    fi
    paquets_marque="${DEVZONE_PAQUETS_MARQUE:-/tmp/devzone-paquets.echec}"
    if [ -f "$paquets_marque" ]; then
        paquets_noms=""
        while IFS= read -r n; do
            [ -n "$n" ] || continue
            paquets_noms="${paquets_noms:+$paquets_noms, }$n"
        done < "$paquets_marque"
        append_alerte paquets "$paquets_noms" "devzone paquets"
    fi
    wt_out="$(worktrees_absents 2>/dev/null || true)"
    while IFS= read -r chemin; do
        [ -n "$chemin" ] || continue
        append_alerte worktree "$chemin absent ici (créé hors du conteneur ?)" ""
    done <<<"$wt_out"
    if [ -n "$services_cluster" ] && ! cluster_est_local "$services_cluster"; then
        append_alerte cluster_distant "cluster distant : $services_cluster — services sur un cluster distant" ""
    fi
    if [ "$travail_interne" = true ]; then
        append_alerte cluster_interne "cluster de travail : $travail_ctx (cluster interne de devzone)" "devzone utiliser $ctx_hote"
    fi

    jq -n \
        --argjson schema 1 \
        --arg dv "$dv_raw" \
        --arg dvp "$dvp_raw" \
        --argjson id_ok "$id_ok" \
        --arg id_nom "$id_nom" \
        --arg id_email "$id_email" \
        --arg id_commande "$id_commande" \
        --arg plat_nom "$plat_nom" \
        --arg plat_url "$plat_url" \
        --argjson github "$github_json" \
        --argjson retards "$outils_retards_json" \
        --arg outils_commande "$outils_commande" \
        --argjson modules "$modules_json" \
        --arg clusters_services "$clusters_services_raw" \
        --argjson services_distant "$services_distant" \
        --arg clusters_travail "$clusters_travail_raw" \
        --argjson travail_interne "$travail_interne" \
        --arg clusters_commande "$clusters_commande" \
        --argjson ports "$ports_json" \
        --arg identifiants "$identifiants_raw" \
        --argjson alertes "$alertes_json" \
        --argjson erreurs "$erreurs" \
        '{
            schema: $schema,
            devzone: { version: (if $dv=="" then null else $dv end), disponible: (if $dvp=="" then null else $dvp end) },
            identite_git: { ok: $id_ok, nom: (if $id_nom=="" then null else $id_nom end), email: (if $id_email=="" then null else $id_email end), commande: (if $id_commande=="" then null else $id_commande end) },
            plateforme: { nom: $plat_nom, url: (if $plat_url=="" then null else $plat_url end), github: $github },
            outils: { retards: $retards, commande: (if $outils_commande=="" then null else $outils_commande end) },
            modules: $modules,
            clusters: { services: (if $clusters_services=="" then null else $clusters_services end), services_distant: $services_distant, travail: (if $clusters_travail=="" then null else $clusters_travail end), travail_interne: $travail_interne, commande: (if $clusters_commande=="" then null else $clusters_commande end) },
            ports: $ports,
            identifiants: (if $identifiants=="" then null else $identifiants end),
            alertes: $alertes,
            erreurs: $erreurs
        }'
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    etat_json
fi
