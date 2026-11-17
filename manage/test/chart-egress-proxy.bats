#!/usr/bin/env bats
# Chart charts/devzone-workspace egress proxy (#220).
# helm template only; skipped without helm.

setup() {
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CHART="$RACINE/charts/devzone-workspace"
    command -v helm >/dev/null 2>&1 || skip "helm missing"
    T="$BATS_TEST_TMPDIR"
}

# Here a bare helm call can be summarised by an intermediate tool: rtk proxy
# gives the full rendering when rtk exists.
render() {
    if command -v rtk >/dev/null 2>&1; then
        rtk proxy helm template ws "$CHART" --namespace team "$@"
    else
        helm template ws "$CHART" --namespace team "$@"
    fi
}

# key=value pairs of every descendant label of the first block matching $4 in
# the document of kind $2 and name $3 (awk: portable to macOS bash 3.2).
label_pairs() {
    awk -v kind="$2" -v name="$3" -v anchor="$4" '
        function indent(s,  n) { n = 0; while (substr(s, n + 1, 1) == " ") n++; return n }
        /^---$/ { doc_kind = ""; doc_name = ""; inblock = 0; next }
        /^kind: / { doc_kind = $2; doc_name = "" }
        /^  name: / { if (doc_name == "") doc_name = $2 }
        {
            if (doc_kind == kind && doc_name == name && inblock == 0 && $0 ~ anchor) {
                inblock = 1; block_indent = indent($0); next
            }
            if (inblock == 1) {
                if ($0 ~ /^[[:space:]]*$/) next
                if (indent($0) <= block_indent) { inblock = 0; next }
                line = $0
                sub(/^[ \t]+/, "", line)
                if (line ~ /^[^:]+:/) {
                    key = line
                    sub(/:.*$/, "", key)
                    val = line
                    sub(/^[^:]*:[ \t]*/, "", val)
                    gsub(/^"|"$/, "", val)
                    if (val != "") printf "%s=%s\n", key, val
                }
            }
        }
    ' "$1"
}

# True when every pair of $1 appears in $2.
is_subset() {
    local pair
    while IFS= read -r pair; do
        [ -n "$pair" ] || continue
        grep -Fqx "$pair" "$2" || return 1
    done <"$1"
    return 0
}

@test "chart egress-proxy: disabled by default renders no egress objects" {
    run render
    [ "$status" -eq 0 ]
    if printf '%s' "$output" | grep -q "egress-proxy"; then false; fi
    if printf '%s' "$output" | grep -q "egress-strict"; then false; fi
    if printf '%s' "$output" | grep -q "devzone.io/egress-mode"; then false; fi
}

@test "chart egress-proxy: observation renders Deployment, Service, ConfigMap without NetworkPolicy" {
    run render --set egressProxy.enabled=true --set egressProxy.mode=observation
    [ "$status" -eq 0 ]
    printf '%s' "$output" | grep -q "kind: Deployment" || false
    printf '%s' "$output" | grep -q "kind: Service" || false
    printf '%s' "$output" | grep -q "kind: ConfigMap" || false
    printf '%s' "$output" | grep -q "name: egress-proxy" || false
    printf '%s' "$output" | grep -q 'devzone.io/egress-mode: "observation"' || false
    if printf '%s' "$output" | grep -q "egress-strict"; then false; fi
    if printf '%s' "$output" | grep -q "devzone-workspace-egress-strict"; then false; fi
}

@test "chart egress-proxy: strict renders NetworkPolicy with existence selector on agent-session label" {
    run render --set egressProxy.enabled=true --set egressProxy.mode=strict
    [ "$status" -eq 0 ]
    printf '%s' "$output" | grep -q "kind: NetworkPolicy" || false
    printf '%s' "$output" | grep -q "name: devzone-workspace-egress-strict" || false
    printf '%s' "$output" | grep -q "key: devzone.io/agent-session" || false
    printf '%s' "$output" | grep -q "operator: Exists" || false
    printf '%s' "$output" | grep -q "port: 3128" || false
    printf '%s' "$output" | grep -q "port: 53" || false
}

@test "chart egress-proxy: image digest is exact and squid config has no stdio stdout" {
    run render --set egressProxy.enabled=true --set egressProxy.mode=observation
    [ "$status" -eq 0 ]
    printf '%s' "$output" | grep -q "ubuntu/squid@sha256:6a097f68bae708cedbabd6188d68c7e2e7a38cedd05a176e1cc0ba29e3bbe029" || false
    if printf '%s' "$output" | grep -q "stdio:/dev/stdout"; then false; fi
    printf '%s' "$output" | grep -q "max_filedescriptors 1024" || false
    printf '%s' "$output" | grep -q "access_log daemon:/var/log/squid/access.log" || false
}

@test "chart egress-proxy: strict squid config allows listed domains and denies others" {
    run render --set egressProxy.enabled=true --set egressProxy.mode=strict
    [ "$status" -eq 0 ]
    printf '%s' "$output" | grep -q "acl allowed dstdomain .opencode.ai" || false
    printf '%s' "$output" | grep -q "http_access allow CONNECT SSL_ports allowed" || false
    printf '%s' "$output" | grep -q "http_access deny all" || false
}

@test "chart egress-proxy: observation squid config allows all" {
    run render --set egressProxy.enabled=true --set egressProxy.mode=observation
    [ "$status" -eq 0 ]
    printf '%s' "$output" | grep -q "http_access allow all" || false
}

@test "chart egress-proxy: no egress object takes the workspace name label" {
    for mode in observation strict; do
        render --set egressProxy.enabled=true --set egressProxy.mode="$mode" >"$T/render.yaml"
        sources="egress-proxy.yaml"
        if [ "$mode" = strict ]; then sources="$sources egress-networkpolicy.yaml"; fi
        for source in $sources; do
            block="$(awk -v src="$source" '
                /^# Source: / { want = ($0 == "# Source: devzone-workspace/templates/" src); next }
                want { print }
            ' "$T/render.yaml")"
            [ -n "$block" ] || { echo "missing source: $source"; false; }
            if printf '%s\n' "$block" | grep -Eq '^[[:space:]]*app\.kubernetes\.io/name:[[:space:]]*devzone-workspace[[:space:]]*$'; then
                echo "$source carries the workspace app.kubernetes.io/name"
                false
            fi
        done
    done
}

@test "chart egress-proxy: workspace selectors do not match the proxy pod labels" {
    for mode in observation strict; do
        render --set egressProxy.enabled=true --set egressProxy.mode="$mode" >"$T/render.yaml"
        label_pairs "$T/render.yaml" Deployment devzone-workspace-egress-proxy '^      labels:$' >"$T/pod.txt"
        [ -s "$T/pod.txt" ] || { echo "proxy pod labels missing"; false; }
        grep -Fq 'app.kubernetes.io/name=devzone-workspace-egress-proxy' "$T/pod.txt" || false
        for kind in Service StatefulSet; do
            label_pairs "$T/render.yaml" "$kind" devzone-workspace '^  selector:$' >"$T/selector.txt"
            [ -s "$T/selector.txt" ] || { echo "$kind selector missing"; false; }
            if is_subset "$T/selector.txt" "$T/pod.txt"; then
                echo "the $kind selector matches the proxy pod"
                false
            fi
        done
    done
}

@test "chart egress-proxy: strict NetworkPolicy targets the proxy pod labels" {
    render --set egressProxy.enabled=true --set egressProxy.mode=strict >"$T/render.yaml"
    label_pairs "$T/render.yaml" Deployment devzone-workspace-egress-proxy '^      labels:$' >"$T/pod.txt"
    [ -s "$T/pod.txt" ] || { echo "proxy pod labels missing"; false; }
    label_pairs "$T/render.yaml" NetworkPolicy devzone-workspace-egress-strict '^        - podSelector:$' >"$T/to.txt"
    [ -s "$T/to.txt" ] || { echo "NetworkPolicy to selector missing"; false; }
    is_subset "$T/to.txt" "$T/pod.txt" || { echo "the to selector does not match the proxy pod"; false; }
    grep -Fq 'app.kubernetes.io/component=egress-proxy' "$T/to.txt" || false
}

@test "chart egress-proxy: strict enabled renders the ten documents" {
    render --set egressProxy.enabled=true --set egressProxy.mode=strict >"$T/render.yaml"
    docs="$(grep -c '^---$' "$T/render.yaml" || true)"
    [ "$docs" -eq 10 ] || { echo "rendered documents: $docs"; false; }
}

@test "chart egress-proxy: strict adds the extra domains to the allow list, empty items ignored" {
    run render --set egressProxy.enabled=true --set egressProxy.mode=strict --set "egressProxy.extraDomains=a.example.com\,.b.example.org\,"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | grep -q "acl allowed dstdomain a.example.com" || false
    printf '%s' "$output" | grep -q "acl allowed dstdomain .b.example.org" || false
    [ "$(printf '%s\n' "$output" | grep -c 'acl allowed dstdomain ')" -eq 5 ] || false
}

@test "chart egress-proxy: strict without extra domains keeps the three base domains" {
    run render --set egressProxy.enabled=true --set egressProxy.mode=strict
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c 'acl allowed dstdomain ')" -eq 3 ] || false
}

@test "chart egress-proxy: observation ignores the extra domains" {
    run render --set egressProxy.enabled=true --set egressProxy.mode=observation --set "egressProxy.extraDomains=a.example.com"
    [ "$status" -eq 0 ]
    if printf '%s' "$output" | grep -q "acl allowed"; then false; fi
    printf '%s' "$output" | grep -q "http_access allow all" || false
}
