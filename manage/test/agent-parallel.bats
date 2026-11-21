#!/usr/bin/env bats
# devzone agent: simultaneous launches, shared rank taken under lock and exclusions
# written file by file (#289). Rotation and resume: agent.bats.

setup() {
    load commun
    kube_isole
    agent_isole
    export DEVZONE_AGENT_SILENCE=10
    mkdir -p "$DEVZONE_AGENT_STATE"
    # Fake opencode that sleeps 2 s before working: two launches really live at the
    # same time, like two `devzone agent` started at the same instant.
    mv "$BATS_TEST_TMPDIR/bin/opencode" "$BATS_TEST_TMPDIR/bin/opencode.reel"
    cat >"$BATS_TEST_TMPDIR/bin/opencode" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = run ]; then sleep 2; fi
exec "$BATS_TEST_TMPDIR/bin/opencode.reel" "$@"
FAKE
    chmod +x "$BATS_TEST_TMPDIR/bin/opencode"
}

# Starts devzone agent in the background on a folder; the pid is in AGENT_PID.
launch_background() {
    bash "$DEVZONE" agent "$1" "$DEVZONE_ROOT/workspace/consigne.txt" >"$2" 2>&1 &
    AGENT_PID=$!
}

# First model chosen in the journal of a parallel launch folder.
first_model() {
    grep -m1 -oE '^=== model opencode/[A-Za-z0-9._-]+' "$1" | sed 's#.*opencode/##'
}

# Prints, on the bats output, the facts visible when a test fails: full journals of
# the agents, rank and state list, models of the fake opencode, outputs of each
# launch (un.out, deux.out...).
diagnostic() {
    echo "===== parallel diagnostic =====" >&2
    echo "--- agent journals ---" >&2
    for j in "$DEVZONE_ROOT"/workspace/.agents/*.log; do
        [ -e "$j" ] || continue
        echo "### $j" >&2
        cat "$j" >&2
    done
    echo "--- rank ($DEVZONE_AGENT_STATE/rang) ---" >&2
    [ -r "$DEVZONE_AGENT_STATE/rang" ] && cat "$DEVZONE_AGENT_STATE/rang" >&2
    echo "--- list of $DEVZONE_AGENT_STATE ---" >&2
    ls -la "$DEVZONE_AGENT_STATE" >&2
    echo "--- opencode models ---" >&2
    opencode models opencode >&2
    echo "--- launch outputs ---" >&2
    for o in "$BATS_TEST_TMPDIR"/*.out; do
        [ -e "$o" ] || continue
        echo "### $o" >&2
        cat "$o" >&2
    done
    echo "===== end of parallel diagnostic =====" >&2
}

# Prints, on the bats output, the facts visible when an assertion of the rank
# interleaving test fails (#421): both journals with their "=== rank" lines (and
# "=== lock taken/released"), the content of the rank file, the state with its
# timestamps, the date and the kernel.
diagnostic_rang() {
    echo "===== rank diagnostic =====" >&2
    for j in "$j1" "$j2"; do
        [ -e "$j" ] || continue
        echo "### $j" >&2
        cat "$j" >&2
    done
    echo "--- === rank lines ---" >&2
    grep -n '^=== rank' "$j1" "$j2" >&2 || true
    echo "--- $DEVZONE_AGENT_STATE/rang ---" >&2
    if [ -r "$DEVZONE_AGENT_STATE/rang" ]; then
        cat "$DEVZONE_AGENT_STATE/rang" >&2
    else
        echo "(absent)" >&2
    fi
    echo "--- $DEVZONE_AGENT_STATE ---" >&2
    case "$(uname -s)" in
        Darwin) ls -laT "$DEVZONE_AGENT_STATE" >&2 ;;
        *) ls -la --time-style=full-iso "$DEVZONE_AGENT_STATE" >&2 ;;
    esac
    echo "--- date ---" >&2
    date +%s >&2
    echo "--- kernel ---" >&2
    uname -a >&2
    echo "===== end of rank diagnostic =====" >&2
}

@test "agent : two simultaneous launches -> both start on two different models" {
    printf 'construis la feature\n' >"$DEVZONE_ROOT/workspace/consigne.txt"
    mkdir -p "$DEVZONE_ROOT/workspace/projet-un" "$DEVZONE_ROOT/workspace/projet-deux"
    j1="$DEVZONE_ROOT/workspace/.agents/projet-un.log"
    j2="$DEVZONE_ROOT/workspace/.agents/projet-deux.log"
    launch_background "$DEVZONE_ROOT/workspace/projet-un" "$BATS_TEST_TMPDIR/un.out"
    p1="$AGENT_PID"
    launch_background "$DEVZONE_ROOT/workspace/projet-deux" "$BATS_TEST_TMPDIR/deux.out"
    p2="$AGENT_PID"
    s1=0
    wait "$p1" || s1=$?
    s2=0
    wait "$p2" || s2=$?
    [ "$s1" -eq 0 ] || { diagnostic_rang; false; }
    [ "$s2" -eq 0 ] || { diagnostic_rang; false; }
    grep -q '^=== model opencode/' "$j1" || { diagnostic_rang; false; }
    grep -q '^=== model opencode/' "$j2" || { diagnostic_rang; false; }
    if grep -q "no free model available" "$j1"; then diagnostic_rang; false; fi
    if grep -q "no free model available" "$j2"; then diagnostic_rang; false; fi
    [ "$(first_model "$j1")" != "$(first_model "$j2")" ] || { diagnostic_rang; false; }
}

# Deterministic exclusion of the rank (#421): the first agent holds the lock for
# DEVZONE_AGENT_PAUSE_RANK=3 s between the read and the write of the rank; started
# 1 s later, the second waits for the lock then takes the next rank. Without
# exclusion, the second would read rank 0 before the write of the first.
@test "agent : first agent holds the lock 3 s -> the second takes rank 2" {
    printf 'construis la feature\n' >"$DEVZONE_ROOT/workspace/consigne.txt"
    mkdir -p "$DEVZONE_ROOT/workspace/projet-neuf" "$DEVZONE_ROOT/workspace/projet-dix"
    j1="$DEVZONE_ROOT/workspace/.agents/projet-neuf.log"
    j2="$DEVZONE_ROOT/workspace/.agents/projet-dix.log"
    export DEVZONE_AGENT_PAUSE_RANK=3
    launch_background "$DEVZONE_ROOT/workspace/projet-neuf" "$BATS_TEST_TMPDIR/neuf.out"
    unset DEVZONE_AGENT_PAUSE_RANK
    p1="$AGENT_PID"
    sleep 1
    launch_background "$DEVZONE_ROOT/workspace/projet-dix" "$BATS_TEST_TMPDIR/dix.out"
    p2="$AGENT_PID"
    s1=0
    wait "$p1" || s1=$?
    s2=0
    wait "$p2" || s2=$?
    [ "$s1" -eq 0 ] || { diagnostic_rang; false; }
    [ "$s2" -eq 0 ] || { diagnostic_rang; false; }
    grep -qE '^=== rank 2/[0-9]+$' "$j2" || { diagnostic_rang; false; }
    [ "$(cat "$DEVZONE_AGENT_STATE/rang")" = 2 ] || { diagnostic_rang; false; }
}

@test "agent : three simultaneous launches -> none stops for lack of a model" {
    printf 'construis la feature\n' >"$DEVZONE_ROOT/workspace/consigne.txt"
    mkdir -p "$DEVZONE_ROOT/workspace/projet-trois" "$DEVZONE_ROOT/workspace/projet-quatre" \
        "$DEVZONE_ROOT/workspace/projet-cinq"
    launch_background "$DEVZONE_ROOT/workspace/projet-trois" "$BATS_TEST_TMPDIR/trois.out"
    p1="$AGENT_PID"
    launch_background "$DEVZONE_ROOT/workspace/projet-quatre" "$BATS_TEST_TMPDIR/quatre.out"
    p2="$AGENT_PID"
    launch_background "$DEVZONE_ROOT/workspace/projet-cinq" "$BATS_TEST_TMPDIR/cinq.out"
    p3="$AGENT_PID"
    s1=0
    wait "$p1" || s1=$?
    s2=0
    wait "$p2" || s2=$?
    s3=0
    wait "$p3" || s3=$?
    [ "$s1" -eq 0 ]
    [ "$s2" -eq 0 ]
    [ "$s3" -eq 0 ]
    for j in projet-trois projet-quatre projet-cinq; do
        journal="$DEVZONE_ROOT/workspace/.agents/$j.log"
        grep -q '^=== model opencode/' "$journal" || false
        ! grep -q "no free model available" "$journal" || false
    done
}

@test "agent : all excluded but one -> both take that model, none only if all excluded" {
    printf 'construis la feature\n' >"$DEVZONE_ROOT/workspace/consigne.txt"
    mkdir -p "$DEVZONE_ROOT/workspace/projet-six" "$DEVZONE_ROOT/workspace/projet-sept" \
        "$DEVZONE_ROOT/workspace/projet-huit"
    for m in deepseek-v4.1-flash-free hy4-flash-free nemotron-3.5-super-vl-free \
        nemotron-3.5-lightning-free mimo-v2.6-flash-free beam-free flint-40b-free \
        longcat-2.5-free; do
        echo "$(date +%s) quota 3600" >"$DEVZONE_AGENT_STATE/ecart-$m"
    done
    j1="$DEVZONE_ROOT/workspace/.agents/projet-six.log"
    j2="$DEVZONE_ROOT/workspace/.agents/projet-sept.log"
    launch_background "$DEVZONE_ROOT/workspace/projet-six" "$BATS_TEST_TMPDIR/six.out"
    p1="$AGENT_PID"
    launch_background "$DEVZONE_ROOT/workspace/projet-sept" "$BATS_TEST_TMPDIR/sept.out"
    p2="$AGENT_PID"
    s1=0
    wait "$p1" || s1=$?
    s2=0
    wait "$p2" || s2=$?
    [ "$s1" -eq 0 ]
    [ "$s2" -eq 0 ]
    [ "$(first_model "$j1")" = "big-pickle" ]
    [ "$(first_model "$j2")" = "big-pickle" ]
    ! grep -q "no free model available" "$j1" || false
    ! grep -q "no free model available" "$j2" || false
    echo "$(date +%s) quota 3600" >"$DEVZONE_AGENT_STATE/ecart-big-pickle"
    j3="$DEVZONE_ROOT/workspace/.agents/projet-huit.log"
    launch_background "$DEVZONE_ROOT/workspace/projet-huit" "$BATS_TEST_TMPDIR/huit.out"
    p3="$AGENT_PID"
    s3=0
    wait "$p3" || s3=$?
    [ "$s3" -eq 3 ]
    grep -q "no free model available" "$j3" || false
}

@test "agent : journal traces the rank taking (=== rank start/total)" {
    printf 'construis la feature\n' >"$DEVZONE_ROOT/workspace/consigne.txt"
    mkdir -p "$DEVZONE_ROOT/workspace/projet-rang"
    journal="$DEVZONE_ROOT/workspace/.agents/projet-rang.log"
    bash "$DEVZONE" agent "$DEVZONE_ROOT/workspace/projet-rang" "$DEVZONE_ROOT/workspace/consigne.txt" >"$BATS_TEST_TMPDIR/rang.out" 2>&1
    [ "$?" -eq 0 ] || false
    grep -qE '^=== rank [0-9]+/[0-9]+$' "$journal" || false
}

# Only after a failing test (BATS_TEST_COMPLETED empty): the facts visible in CI
# (#385), without changing the assertions.
teardown() {
    [ -n "${BATS_TEST_COMPLETED:-}" ] || diagnostic
}
