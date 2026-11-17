#!/usr/bin/env bash
# Egress proxy helpers for the ephemeral session pod (#220).
# Sourced by agent-pod-manifest.sh. bash 3.2 compatible ; shellcheck -x clean.

agent_pod_egress_mode() {
    kubectl get service -l app.kubernetes.io/component=egress-proxy \
        -o jsonpath='{.items[0].metadata.labels.devzone\.io/egress-mode}' 2>/dev/null || true
}

agent_pod_egress_manifest_lines() {
    local mode="$1"
    [ -n "$mode" ] || return 0
    printf '%s\n' "    - name: HTTP_PROXY"
    printf '%s\n' "      value: \"http://egress-proxy:3128\""
    printf '%s\n' "    - name: HTTPS_PROXY"
    printf '%s\n' "      value: \"http://egress-proxy:3128\""
    printf '%s\n' "    - name: NO_PROXY"
    printf '%s\n' "      value: \"localhost,127.0.0.1,.svc,.cluster.local\""
}

agent_pod_egress_init_lines() {
    local mode="$1" ws_image="$2"
    [ "$mode" = "strict" ] || return 0
    printf '%s\n' "  initContainers:"
    printf '%s\n' "  - name: wait-egress-restriction"
    printf '%s\n' "    image: ${ws_image}"
    printf '%s\n' "    command: [\"/bin/bash\", \"-lc\"]"
    printf '%s\n' "    args:"
    printf '%s\n' "    - 'i=0; while [ \$i -lt 20 ]; do if ! curl --noproxy \"*\" -m 3 -sS https://opencode.ai >/dev/null 2>&1; then exit 0; fi; i=\$((i+1)); sleep 1; done; echo \"egress restriction never became effective: session refused\" >&2; exit 1'"
    printf '%s\n' "    securityContext:"
    printf '%s\n' "      runAsUser: 1000"
    printf '%s\n' "      runAsGroup: 1000"
    printf '%s\n' "      allowPrivilegeEscalation: false"
    printf '%s\n' "      capabilities:"
    printf '%s\n' "        drop: [\"ALL\"]"
}
