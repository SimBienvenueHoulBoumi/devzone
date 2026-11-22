#!/usr/bin/env bats
# devzone agent command: launch, rotation, resume, configuration (#221, #328).
# Causes of exclusion, network, state and release are in agent-gaps.bats.

setup() {
    load commun
    agent_isole
}

@test "agent : caller without git push -> accepted, deny supplied by devzone" {
    agent_consigne
    export OPENCODE_CONFIG_CONTENT='{"permission":{"bash":{"*":"ask"}}}'
    agent_lance
    [ "$status" -eq 0 ]
    [ -s "$FAKE_OP_LOG" ]
    jq -e '.permission.bash["git push*"] == "deny"' "$FAKE_OP_CONFIG_LOG"
}

@test "agent : caller with * allow -> devzone deny entries stay and win" {
    agent_consigne
    export OPENCODE_CONFIG_CONTENT='{"permission":{"bash":{"*":"allow"}}}'
    agent_lance
    [ "$status" -eq 0 ]
    for r in 'git push*' 'gh api*' 'repowarden ticket nouveau*' 'git checkout*' 'git reset*' 'git restore*' 'git stash*' 'git clean*' 'git branch -D*' 'repowarden proteger*' 'repowarden run*'; do
        jq -e --arg r "$r" '.permission.bash[$r] == "deny"' "$FAKE_OP_CONFIG_LOG" || { echo "deny lost: $r"; false; }
    done
    jq -e '.permission.bash["*"] == "allow"' "$FAKE_OP_CONFIG_LOG"
    jq -e '(.permission.bash | keys_unsorted | index("*")) < (.permission.bash | keys_unsorted | index("git push*"))' "$FAKE_OP_CONFIG_LOG"
}

@test "agent : supplied configuration completed (git commit allowed, bash32 protected)" {
    agent_consigne
    export OPENCODE_CONFIG_CONTENT='{"permission":{"bash":{"*":"ask","git push*":"deny"}}}'
    agent_lance
    [ "$status" -eq 0 ]
    grep -q '"git commit\*":"allow"' "$FAKE_OP_CONFIG_LOG" || false
    grep -q '"ln \*bash32\*":"deny"' "$FAKE_OP_CONFIG_LOG" || false
    grep -q '"git push\*":"deny"' "$FAKE_OP_CONFIG_LOG" || false
}

@test "agent : launches opencode on the brief, journal written, end of session" {
    agent_consigne
    agent_lance
    [ "$status" -eq 0 ]
    [ -f "$(agent_journal)" ]
    grep -q "end with opencode/" "$(agent_journal)" || false
    grep -qx "big-pickle" "$FAKE_OP_LOG" || false
    grep -q "construis la feature" "$FAKE_OP_CONSIGNE_LOG" || false
}

@test "agent : two launches -> two different models" {
    agent_consigne
    agent_lance
    [ "$status" -eq 0 ]
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(grep -c . "$FAKE_OP_LOG")" -eq 2 ]
    [ "$(sed -n '1p' "$FAKE_OP_LOG")" != "$(sed -n '2p' "$FAKE_OP_LOG")" ]
}

@test "agent : Free usage limit in the printed code, normal end -> end with" {
    agent_consigne
    export FAKE_OP_TEXTE_MODELS="big-pickle"
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(grep -c . "$FAKE_OP_LOG")" -eq 1 ]
    grep -q "end with opencode/big-pickle" "$(agent_journal)" || false
    ! grep -q "excluded" "$(agent_journal)" || false
}

@test "agent : old error outside the last 30 lines -> stopped on error, not refused" {
    agent_consigne
    export FAKE_OP_ANCIEN_ERREUR_MODELS="big-pickle"
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(grep -c . "$FAKE_OP_LOG")" -eq 2 ]
    grep -q "stopped on error (code 1)" "$(agent_journal)" || false
    ! grep -q "excluded" "$(agent_journal)" || false
}

@test "agent : frozen session -> relaunched, resume brief" {
    agent_consigne
    export FAKE_OP_FIGEE_MODELS="big-pickle"
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(grep -c . "$FAKE_OP_LOG")" -eq 2 ]
    [ "$(sed -n '2p' "$FAKE_OP_LOG")" = "deepseek-v4.1-flash-free" ]
    grep -q "RESUME" "$FAKE_OP_CONSIGNE_LOG" || false
    grep -q "git log" "$FAKE_OP_CONSIGNE_LOG" || false
    grep -q "frozen" "$(agent_journal)" || false
}

@test "agent : all models excluded -> code 3" {
    agent_consigne
    export FAKE_OP_ECHEC_MODELS="big-pickle deepseek-v4.1-flash-free hy4-flash-free nemotron-3.5-super-vl-free nemotron-3.5-lightning-free mimo-v2.6-flash-free beam-free flint-40b-free longcat-2.5-free"
    agent_lance
    [ "$status" -eq 3 ]
    grep -q "no free model available" "$(agent_journal)" || false
}

@test "agent : ia disabled -> refuses to launch, code 2, message to enable it" {
    bash "$DEVZONE" disable ai
    agent_consigne
    agent_lance
    [ "$status" -eq 2 ]
    [[ "$output" == *"devzone enable ai"* ]] || false
}

@test "agent : opencode session with dedicated KUBECONFIG, without the host config" {
    mkdir -p "$HOME/.kube"
    printf 'current-context: docker-desktop\n' >"$HOME/.kube/config"
    agent_consigne
    agent_lance
    [ "$status" -eq 0 ]
    [ -f "$FAKE_OP_KUBECONFIG_LOG" ] || false
    grep -qx "$DEVZONE_AGENT_STATE/kubeconfig" "$FAKE_OP_KUBECONFIG_LOG" || false
    ! grep -q 'hote.config' "$FAKE_OP_KUBECONFIG_LOG" || false
}

# Fake kubectl: "config view --minify --flatten --context devzone" only renders the
# devzone context of $KUBECONFIG, and fails when it does not exist (#470).
fake_kubectl_devzone() {
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
[ "$*" = "config view --minify --flatten --context devzone" ] || exit 1
grep -q 'name: devzone' "$KUBECONFIG" 2>/dev/null || { echo "error: context was not found" >&2; exit 1; }
grep -v 'kind-x' "$KUBECONFIG"
KUBECTL
    chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
}

@test "agent : session kubeconfig without the other contexts, in 600 (#470)" {
    fake_kubectl_devzone
    printf 'contexts:\n- name: devzone\n- name: kind-x\n' >"$HOME/.kube/config"
    agent_consigne
    agent_lance
    [ "$status" -eq 0 ]
    grep -q 'name: devzone' "$DEVZONE_AGENT_STATE/kubeconfig" || false
    ! grep -q 'kind-x' "$DEVZONE_AGENT_STATE/kubeconfig" || false
    [ "$(stat -c %a "$DEVZONE_AGENT_STATE/kubeconfig" 2>/dev/null || stat -f %Lp "$DEVZONE_AGENT_STATE/kubeconfig")" = 600 ]
}

@test "agent : no devzone context -> empty kubeconfig and journal line (#470)" {
    fake_kubectl_devzone
    printf 'contexts:\n- name: kind-x\n' >"$HOME/.kube/config"
    agent_consigne
    agent_lance
    [ "$status" -eq 0 ]
    [ ! -s "$DEVZONE_AGENT_STATE/kubeconfig" ]
    [ "$(stat -c %a "$DEVZONE_AGENT_STATE/kubeconfig" 2>/dev/null || stat -f %Lp "$DEVZONE_AGENT_STATE/kubeconfig")" = 600 ]
    grep -q "=== kubernetes: no devzone context, session without access" "$(agent_journal)" || false
}

@test "agent : recent lock without pid -> not taken over, wait then refusal" {
    # A lock without pid is only taken over when its age exceeds 30 s (#377)
    source "$BATS_TEST_DIRNAME/../../.devcontainer/agent-session.sh"
    AGENT_STATE="$DEVZONE_AGENT_STATE"
    export DEVZONE_AGENT_LOCK_MAX=2
    mkdir -p "$AGENT_STATE/lock"
    start="$(date +%s)"
    run lock_take
    [ "$status" -eq 1 ] || false
    [ $(( $(date +%s) - start )) -ge 1 ] || false
    [ $(( $(date +%s) - start )) -le 5 ] || false
    [ -d "$AGENT_STATE/lock" ] || false
    [ ! -e "$AGENT_STATE/lock/pid" ] || false
}

@test "agent : recent lock with unknown pid (other container) -> not taken over" {
    # Pid absent from this pid space: only the age of the lock decides (#377)
    source "$BATS_TEST_DIRNAME/../../.devcontainer/agent-session.sh"
    AGENT_STATE="$DEVZONE_AGENT_STATE"
    export DEVZONE_AGENT_LOCK_MAX=2
    mkdir -p "$AGENT_STATE/lock"
    echo 999999 >"$AGENT_STATE/lock/pid"
    start="$(date +%s)"
    run lock_take
    [ "$status" -eq 1 ] || false
    [ $(( $(date +%s) - start )) -ge 1 ] || false
    grep -qx 999999 "$AGENT_STATE/lock/pid" || false
}

@test "agent : lock older than 30 s -> taken at once, released lock cleaned up" {
    # Lock left by a stop: age over 30 s, taken over without waiting even if its pid
    # is still alive, the age alone decides (#377)
    source "$BATS_TEST_DIRNAME/../../.devcontainer/agent-session.sh"
    AGENT_STATE="$DEVZONE_AGENT_STATE"
    mkdir -p "$AGENT_STATE/lock"
    echo "$$" >"$AGENT_STATE/lock/pid"
    touch -d '-60 seconds' "$AGENT_STATE/lock" 2>/dev/null || touch -t 200001010000 "$AGENT_STATE/lock" || false
    start="$(date +%s)"
    run lock_take
    [ "$status" -eq 0 ] || false
    [ $(( $(date +%s) - start )) -le 5 ] || false
    [ -s "$AGENT_STATE/lock/pid" ] || false
    lock_release
    [ ! -e "$AGENT_STATE/lock" ] || false
}
