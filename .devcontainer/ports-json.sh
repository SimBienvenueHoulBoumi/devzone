#!/usr/bin/env bash
# JSON output of the port relays (#557): the array
# [{port,active,application,auto}] read by the tools (devzone status --json).
# The keys and the application values are a contract.
# Sourced by ports.sh, which holds the functions used here.

# JSON list of the relays of the state: jq only
list_json() {
    local ports port active app json='[]'
    ports="$(sort_ports "$(read_ports)")"
    if [ -z "$ports" ]; then
        printf '[]\n'
        return 0
    fi
    # shellcheck disable=SC2046 # list of ports separated by commas
    for port in $(printf '%s' "$ports" | tr ',' ' '); do
        if relay_active "$port"; then
            active=true
        else
            active=false
        fi
        if app_responds "$port"; then
            app="$JSON_APP_RESPONDS"
        else
            app="$JSON_APP_NONE"
        fi
        json="$(jq -c --argjson port "$port" --argjson active "$active" --arg app "$app" \
            '. + [{port:$port,active:$active,application:$app,auto:false}]' <<<"$json")"
    done
    printf '%s\n' "$json"
}
