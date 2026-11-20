#!/usr/bin/env bash
# JSON output of the port relays (#557): the array
# [{port,actif,application,auto}] read by the tools (devzone status --json).
# The keys and the application values are a contract, kept unchanged.
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
        json="$(jq -c --argjson port "$port" --argjson actif "$active" --arg app "$app" \
            '. + [{port:$port,actif:$actif,application:$app,auto:false}]' <<<"$json")"
    done
    auto_json="$(bash "$HERE/ports-auto.sh" list_json_auto 2>/dev/null || echo '[]')"
    if [ -n "$auto_json" ] && [ "$auto_json" != "[]" ]; then
        json="$(jq -s 'add' <<<"$json"$'\n'"$auto_json")"
    fi
    printf '%s\n' "$json"
}
