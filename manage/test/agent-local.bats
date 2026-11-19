#!/usr/bin/env bats
# devzone agent: the local model devzone-llm/local comes last in the rotation (#586).
# Fake opencode and curl: no model, no cluster.

setup() {
    load commun
    agent_isole
    agent_consigne
    export FAKE_ARGS="$BATS_TEST_TMPDIR/refs.log" FAKE_CURL="$BATS_TEST_TMPDIR/curl.log"
    : >"$FAKE_ARGS"
    : >"$FAKE_CURL"
    # Fake opencode: records the -m reference; online models hit the quota
    cat >"$BATS_TEST_TMPDIR/bin/opencode" <<'FAKE'
#!/usr/bin/env bash
case "${1:-}" in
    models) printf 'opencode/big-pickle\nopencode/glm-5.3-flash-free\n' ;;
    run)
        ref=""
        while [ "$#" -gt 0 ]; do [ "$1" != -m ] || ref="$2"; shift; done
        echo "$ref" >>"$FAKE_ARGS"
        case "$ref" in
            opencode/*)
                echo "timestamp=2026-01-01T00:00:00.000Z level=ERROR message=stream error providerID=opencode error=AI_APICallError: Free usage limit" >&2
                exit 1
                ;;
        esac
        ;;
esac
FAKE
    cat >"$BATS_TEST_TMPDIR/bin/curl" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_CURL"
[ "${FAKE_HEALTH:-ok}" = ok ]
FAKE
    chmod +x "$BATS_TEST_TMPDIR/bin/opencode" "$BATS_TEST_TMPDIR/bin/curl"
    export DEVZONE_AGENT_SILENCE=20
}

@test "agent: module llm on and /health ok: every online model first, the local one last" {
    printf 'llm=on\n' >>"$DEVZONE_RACINE/.devzone.modules"
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(tail -1 "$FAKE_ARGS")" = "devzone-llm/local" ]
    [ "$(grep -c '^opencode/' "$FAKE_ARGS")" -eq 2 ]
    [ "$(grep -c 'devzone-llm/local' "$FAKE_ARGS")" -eq 1 ]
    grep -q 'http://127.0.0.1:8089/health' "$FAKE_CURL" || false
    grep -q "=== fin .*devzone-llm-local" "$(agent_journal)" || false
}

@test "agent: the local model is not used while an online one answers" {
    printf 'llm=on\n' >>"$DEVZONE_RACINE/.devzone.modules"
    sed -i 's/exit 1/exit 0/' "$BATS_TEST_TMPDIR/bin/opencode"
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(grep -c . "$FAKE_ARGS")" -eq 1 ]
    ! grep -q 'devzone-llm' "$FAKE_ARGS" || false
}

@test "agent: module llm off: never tried, no health check" {
    printf 'llm=off\n' >>"$DEVZONE_RACINE/.devzone.modules"
    agent_lance
    [ "$status" -eq 3 ]
    ! grep -q 'devzone-llm' "$FAKE_ARGS" || false
    grep -q '/api/tags' "$FAKE_CURL" || false
    ! grep -q '/health' "$FAKE_CURL" || false
}

@test "agent: module llm on but /health fails: never tried" {
    printf 'llm=on\n' >>"$DEVZONE_RACINE/.devzone.modules"
    FAKE_HEALTH=ko agent_lance
    [ "$status" -eq 3 ]
    ! grep -q 'devzone-llm' "$FAKE_ARGS" || false
    grep -q '/health' "$FAKE_CURL" || false
}
