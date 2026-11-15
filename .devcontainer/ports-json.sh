#!/usr/bin/env bash
# JSON output of the port relays (#557) : the array
# [{port,actif,application,auto}] read by the tools (devzone etat --json).
# Sourced by ports.sh, which holds the functions used here.

# JSON list of the relays of the state : jq only
liste_json() {
    local ports port actif app json='[]'
    ports="$(trier_ports "$(lire_ports)")"
    if [ -z "$ports" ]; then
        printf '[]\n'
        return 0
    fi
    # shellcheck disable=SC2046 # list of ports separated by commas
    for port in $(printf '%s' "$ports" | tr ',' ' '); do
        if relais_actif "$port"; then
            actif=true
        else
            actif=false
        fi
        if application_repond "$port"; then
            app="$APP_REPOND"
        else
            app="$APP_AUCUNE"
        fi
        json="$(jq -c --argjson port "$port" --argjson actif "$actif" --arg app "$app" \
            '. + [{port:$port,actif:$actif,application:$app,auto:false}]' <<<"$json")"
    done
    auto_json="$(bash "$ICI/ports-auto.sh" liste_json_auto 2>/dev/null || echo '[]')"
    if [ -n "$auto_json" ] && [ "$auto_json" != "[]" ]; then
        json="$(jq -s 'add' <<<"$json"$'\n'"$auto_json")"
    fi
    printf '%s\n' "$json"
}
