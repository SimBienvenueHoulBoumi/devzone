#!/usr/bin/env bash
# devzone workspace egress observation|strict|off|status|allow <domain>|deny <domain>
# (#633), sourced by manage/workspace.sh after workspace-update.sh.
#   egress_workspace <subcommand> [domain]   dispatch of the command above
#   egress_params                            key=value parameters of the chart, replayed
#                                            by workspace_deploy at each start and update
# The mode and the added domains are kept in .devzone.modules (egress=,
# egress_domains=, state_read and state_note of argocd-workspace.sh). Each
# change redeploys the workspace at the image it runs: same image tag, same
# Argo CD revision, the pod is not recreated. Only the devzone agent sessions
# started with --pod go through the proxy in strict mode. bash 3.2 (macOS).

# Base list of the chart (egressProxy.allowedDomains in values.yaml): not
# editable with allow or deny, changed in the chart
EGRESS_BASE=".opencode.ai .npmjs.org .github.com"

# Domain: lowercase letters, digits, hyphens and dots, at least one dot, an
# optional leading dot (subdomains); no space, comma, * or /
egress_domain_ok() {
    printf '%s\n' "$1" | grep -Eq '^\.?[a-z0-9-]+(\.[a-z0-9-]+)+$'
}

# Chart parameters of the proxy from .devzone.modules: nothing when off (or
# unset), else enabled, mode and the added domains (comma-separated)
egress_params() {
    local mode domains
    mode="$(state_read egress)"
    case "$mode" in
        observation | strict) ;;
        *) return 0 ;;
    esac
    printf 'egressProxy.enabled=true egressProxy.mode=%s' "$mode"
    domains="$(state_read egress_domains)"
    if [ -n "$domains" ]; then printf ' egressProxy.extraDomains=%s' "$domains"; fi
}

# Waits for the proxy after the redeploy. Argo CD creates its Deployment a few
# seconds to a minute after the sync: the Deployment is looked up every
# DEVZONE_EGRESS_STEP s (3 by default) up to DEVZONE_EGRESS_WAIT s (90 by
# default); then its rollout is awaited for DEVZONE_EGRESS_ROLLOUT s (120 by
# default). Returns 1 when either is not reached.
egress_wait_proxy() {
    local limit="${DEVZONE_EGRESS_WAIT:-90}" rollout="${DEVZONE_EGRESS_ROLLOUT:-120}" pas="${DEVZONE_EGRESS_STEP:-3}" attendu=0
    until ak -n "$NAMESPACE" get deployment devzone-workspace-egress-proxy >/dev/null 2>&1; do
        if [ "$attendu" -ge "$limit" ]; then
            echo "⚠ the egress proxy was not created by Argo CD after $limit s: the setting is kept, check devzone workspace argocd status" >&2
            return 1
        fi
        if [ $((limit - attendu)) -lt "$pas" ]; then pas=$((limit - attendu)); fi
        sleep "$pas"
        attendu=$((attendu + pas))
    done
    if ! ak -n "$NAMESPACE" rollout status deployment/devzone-workspace-egress-proxy --timeout="${rollout}s"; then
        echo "⚠ egress proxy not ready after $rollout s: the setting is kept, see devzone workspace egress status" >&2
        return 1
    fi
}

# Redeploys the workspace at the image of the current Argo CD Application
# (targetRevision and image.tag, as update_current); then waits for the proxy
# when it is on. Without Application (helm direct), the setting is only kept:
# devzone workspace start applies it.
egress_redeploy() {
    local rev tag
    read -r rev tag <<<"$(update_current)" || true
    if [ -z "$rev" ] || [ -z "$tag" ]; then
        echo "ℹ no Argo CD Application: the setting is kept, devzone workspace start applies it"
        return 0
    fi
    export DEVZONE_ARGOCD_REVISION="$rev"
    workspace_deploy "$IMAGE_REPO" "$tag" "" || return 1
    if [ -n "$(egress_params)" ]; then
        echo "▶ waiting for the egress proxy…"
        egress_wait_proxy || return 1
    fi
}

# observation | strict | off: memorised, then the workspace is redeployed
egress_set_mode() {
    kube_ready_reason --hint >&2 || return 1
    state_note egress "$1"
    egress_redeploy || return 1
    echo "✔ egress $1"
    if [ "$1" = strict ]; then
        echo "ℹ strict: only the devzone agent sessions started with --pod are filtered; the workspace stays open"
    fi
}

# allow | deny <domain>: the list of added domains has no duplicate; deny only
# removes what was added, never the base list
egress_domain_edit() {
    local action="$1" domain="$2" list new base=no present=no
    if ! egress_domain_ok "$domain"; then
        echo "✖ domain not valid: $domain (lowercase letters, digits, hyphens and dots, at least one dot, optional leading dot; no space, comma, * or /)" >&2
        return 1
    fi
    case " $EGRESS_BASE " in *" $domain "*) base=yes ;; esac
    list="$(state_read egress_domains)"
    case ",$list," in *",$domain,"*) present=yes ;; esac
    if [ "$action" = allow ]; then
        if [ "$base" = yes ]; then
            echo "ℹ $domain is in the base list (egressProxy.allowedDomains): already allowed"
            return 0
        fi
        if [ "$present" = yes ]; then
            echo "ℹ already allowed: $domain"
            return 0
        fi
        new="${list:+$list,}$domain"
    else
        if [ "$base" = yes ]; then
            echo "✖ $domain is in the base list: change it in egressProxy.allowedDomains of the chart (nothing changed)" >&2
            return 1
        fi
        if [ "$present" = no ]; then
            echo "✖ $domain was not added with allow: nothing changed" >&2
            return 1
        fi
        new="$(printf '%s' "$list" | tr ',' '\n' | grep -vxF -- "$domain" | paste -sd, -)" || new=""
    fi
    kube_ready_reason --hint >&2 || return 1
    state_note egress_domains "$new"
    echo "✔ $action $domain"
    egress_redeploy
}

# Mode of the proxy (label of its Service, off when none), readiness, number of
# allowed domains (ACL lines of the ConfigMap), then the domains contacted in
# the last 2000 lines of the access log: count and state (allowed, refused, or
# observed in observation mode). Columns of the squid native log: 4 result, 6
# method, 7 host:port.
egress_status() {
    local mode ready count table
    kube_ready_reason --hint >&2 || return 1
    mode="$(ak -n "$NAMESPACE" get service egress-proxy -o 'jsonpath={.metadata.labels.devzone\.io/egress-mode}' 2>/dev/null)" || mode=""
    if [ -z "$mode" ]; then
        echo "egress off"
        return 0
    fi
    ready="$(ak -n "$NAMESPACE" get deployment devzone-workspace-egress-proxy -o 'jsonpath={.status.readyReplicas}' 2>/dev/null || true)"
    if [ "${ready:-0}" -ge 1 ] 2>/dev/null; then ready="ready"; else ready="not ready"; fi
    count="$(ak -n "$NAMESPACE" get configmap devzone-workspace-egress-proxy -o 'jsonpath={.data.squid\.conf}' 2>/dev/null |
        grep -c 'acl allowed dstdomain ' || true)"
    echo "egress $mode, proxy $ready, allowed domains: ${count:-0}"
    table="$(ak -n "$NAMESPACE" logs deployment/devzone-workspace-egress-proxy -c access-log --tail=2000 2>/dev/null |
        awk -v mode="$mode" '
            $6 == "CONNECT" {
                host = $7
                sub(/:[0-9]+$/, "", host)
                hits[host]++
                if ($4 ~ /DENIED/) refused[host] = 1
            }
            END {
                for (h in hits) {
                    state = refused[h] ? "refused" : (mode == "observation" ? "observed" : "allowed")
                    printf "  %-40s %6d  %s\n", h, hits[h], state
                }
            }' | sort)" || table=""
    if [ -z "$table" ]; then
        echo "  no domain contacted in the recent log"
    else
        printf '  %-40s %6s  %s\n' domain accesses state
        echo "$table"
    fi
}

# Dispatch of devzone workspace egress
egress_workspace() {
    case "${1:-}" in
        observation | strict | off) egress_set_mode "$1" ;;
        status) egress_status ;;
        allow | deny)
            if [ "$#" -ne 2 ]; then
                echo "✖ egress $1 takes one domain: devzone workspace egress $1 <domain>" >&2
                return 1
            fi
            egress_domain_edit "$1" "$2"
            ;;
        *)
            echo "✖ unknown egress argument: ${1:-none} (devzone workspace egress observation|strict|off|status|allow <domain>|deny <domain>)" >&2
            return 1
            ;;
    esac
}
