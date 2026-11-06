#!/usr/bin/env bats
# devzone agent : quota/pays reconnus tout de suite dans la boucle d'attente (#367).

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
    modele=""
    for a in "$@"; do case "$a" in opencode/*) modele="${a#opencode/}" ;; esac; done
    case " ${FAKE_OP_QUOTA_MODELS:-} " in
        *" $modele "*)
            echo "$modele" >>"${FAKE_OP_LOG:?}"
            echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%S.000Z) level=ERROR run=8b522c10 message=stream error providerID=opencode modelID=$modele error=AI_APICallError: Free usage limit" >&2
            sleep "${FAKE_OP_DUREE:-30}"
            exit 0
            ;;
    esac
    case " ${FAKE_OP_PAYS_MODELS:-} " in
        *" $modele "*)
            echo "$modele" >>"${FAKE_OP_LOG:?}"
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

@test "agent : quota reconnu tout de suite -> modele ecarte (quota), modele suivant" {
    agent_consigne
    export FAKE_OP_QUOTA_MODELS="big-pickle"
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(grep -c . "$FAKE_OP_LOG")" -eq 2 ]
    [ "$(sed -n '1p' "$FAKE_OP_LOG")" = "big-pickle" ]
    [ "$(sed -n '2p' "$FAKE_OP_LOG")" = "deepseek-v4.1-flash-free" ]
    grep -q "^[0-9]* quota 3600$" "$DEVZONE_AGENT_ETAT/ecart-big-pickle" || false
    grep -q "écarté (quota) : modèle suivant" "$(agent_journal)" || false
}

@test "agent : pays reconnu tout de suite -> modele ecarte (pays), modele suivant" {
    agent_consigne
    export FAKE_OP_PAYS_MODELS="big-pickle"
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(grep -c . "$FAKE_OP_LOG")" -eq 2 ]
    [ "$(sed -n '2p' "$FAKE_OP_LOG")" = "deepseek-v4.1-flash-free" ]
    grep -q "^[0-9]* pays 604800$" "$DEVZONE_AGENT_ETAT/ecart-big-pickle" || false
    grep -q "écarté (pays) : modèle suivant" "$(agent_journal)" || false
}

@test "agent : le faux opencode recoit --print-logs --log-level ERROR" {
    agent_consigne
    export FAKE_OP_QUOTA_MODELS="big-pickle"
    agent_lance
    grep -q -- "--print-logs --log-level ERROR" "$FAKE_OP_ARGS_LOG" || false
}

@test "agent : texte ordinaire avec quota/pays affiche, fin normale -> fin avec" {
    agent_consigne
    export FAKE_OP_TEXTE_MODELS="big-pickle"
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(grep -c . "$FAKE_OP_LOG")" -eq 1 ]
    grep -q "fin avec opencode/big-pickle" "$(agent_journal)" || false
    ! grep -q "écarté" "$(agent_journal)" || false
    [ ! -f "$DEVZONE_AGENT_ETAT/ecart-big-pickle" ]
}
