#!/usr/bin/env bats
# devzone agent: quota and country recognized right away in the wait loop (#367).

setup() {
    load commun
    agent_isole
    agent_consigne
    export FAKE_OP_ARGS_LOG="$BATS_TEST_TMPDIR/args.log"
    : >"$FAKE_OP_ARGS_LOG"
    mv "$BATS_TEST_TMPDIR/bin/opencode" "$BATS_TEST_TMPDIR/bin/opencode.reel"
    cat >"$BATS_TEST_TMPDIR/bin/opencode" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"${FAKE_OP_ARGS_LOG:?}"
if [ "${1:-}" = run ]; then
    model=""
    for a in "$@"; do case "$a" in opencode/*) model="${a#opencode/}" ;; esac; done
    case " ${FAKE_OP_QUOTA_MODELS:-} " in
        *" $model "*)
            echo "$model" >>"${FAKE_OP_LOG:?}"
            echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%S.000Z) level=ERROR run=8b522c10 message=stream error providerID=opencode modelID=$model error=AI_APICallError: Free usage limit" >&2
            sleep "${FAKE_OP_DUREE:-30}"
            exit 0
            ;;
    esac
    case " ${FAKE_OP_PAYS_MODELS:-} " in
        *" $model "*)
            echo "$model" >>"${FAKE_OP_LOG:?}"
            echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%S.000Z) level=ERROR run=8b522c10 message=process session.id=ses_8b522c10 error=This model is not available in your country stack=opencode" >&2
            sleep "${FAKE_OP_DUREE:-30}"
            exit 0
            ;;
    esac
fi
exec "$BATS_TEST_TMPDIR/bin/opencode.reel" "$@"
FAKE
    chmod +x "$BATS_TEST_TMPDIR/bin/opencode"
}

@test "agent : quota recognized right away -> model excluded (quota), next model" {
    agent_consigne
    export FAKE_OP_QUOTA_MODELS="big-pickle"
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(grep -c . "$FAKE_OP_LOG")" -eq 2 ]
    [ "$(sed -n '1p' "$FAKE_OP_LOG")" = "big-pickle" ]
    [ "$(sed -n '2p' "$FAKE_OP_LOG")" = "deepseek-v4.1-flash-free" ]
    grep -q "^[0-9]* quota 3600$" "$DEVZONE_AGENT_ETAT/ecart-big-pickle" || false
    grep -q "excluded (quota): next model" "$(agent_journal)" || false
}

@test "agent : country recognized right away -> model excluded (country), next model" {
    agent_consigne
    export FAKE_OP_PAYS_MODELS="big-pickle"
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(grep -c . "$FAKE_OP_LOG")" -eq 2 ]
    [ "$(sed -n '2p' "$FAKE_OP_LOG")" = "deepseek-v4.1-flash-free" ]
    grep -q "^[0-9]* pays 604800$" "$DEVZONE_AGENT_ETAT/ecart-big-pickle" || false
    grep -q "excluded (country): next model" "$(agent_journal)" || false
}

@test "agent : the fake opencode receives --print-logs --log-level ERROR" {
    agent_consigne
    export FAKE_OP_QUOTA_MODELS="big-pickle"
    agent_lance
    grep -q -- "--print-logs --log-level ERROR" "$FAKE_OP_ARGS_LOG" || false
}

@test "agent : ordinary text with quota/country displayed, normal end -> end with" {
    agent_consigne
    export FAKE_OP_TEXTE_MODELS="big-pickle"
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(grep -c . "$FAKE_OP_LOG")" -eq 1 ]
    grep -q "end with opencode/big-pickle" "$(agent_journal)" || false
    ! grep -q "excluded" "$(agent_journal)" || false
    [ ! -f "$DEVZONE_AGENT_ETAT/ecart-big-pickle" ]
}
