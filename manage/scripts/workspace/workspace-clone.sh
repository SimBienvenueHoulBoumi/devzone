#!/usr/bin/env bash

# Guard of the agents in the pod (#558): when the ai module is on there,
# "repowarden agents init --global" is run (idempotent), so that an agent
# launched in the pod cannot edit develop. Never fails the workspace start.
workspace_agents_guard() {
    # shellcheck disable=SC2046
    if kubectl $(kubectl_flag) exec "$POD" --namespace "$NAMESPACE" -c workspace -- \
        bash -lc 'devzone is-enabled ai && repowarden agents init --global' >/dev/null 2>&1; then
        echo "✔ repowarden guard active for the agents of the pod"
    fi
}
