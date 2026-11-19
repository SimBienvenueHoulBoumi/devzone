#!/usr/bin/env bats
# Guard: block Docker commands for agents (Kubernetes-first). #670
# Fake tool calls only, no docker executed, no cluster.

setup() {
    GUARD="$BATS_TEST_DIRNAME/../../.devcontainer/ia/docker-garde.sh"
    MSG="devzone est Kubernetes d'abord : seuls les pods sont des conteneurs. Utilise kubectl, ou un pod ou un namespace jetable (kubectl run, kubectl create ns, puis suppression). Action sur l'hôte lui-même : DEVZONE_ALLOW_DOCKER=1."
    export MSG
}

opencode_call() {
    local tool="$1" cmd="$2"
    printf '{"tool":"%s","args":{"command":"%s"},"cwd":"/tmp"}' "$tool" "$cmd"
}

claude_call() {
    local cmd="$1"
    printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$cmd"
}

# Build a PATH containing everything except the named commands.
path_without() {
    local dir="$BATS_TEST_TMPDIR/bin-$RANDOM"
    mkdir -p "$dir"
    local p b skip
    for p in /usr/bin/* /bin/* /usr/local/bin/*; do
        [ -e "$p" ] || continue
        b="$(basename "$p")"
        skip=0
        for rm in "$@"; do [ "$b" = "$rm" ] && skip=1; done
        [ "$skip" -eq 1 ] && continue
        ln -s "$p" "$dir/$b" 2>/dev/null || true
    done
    printf '%s' "$dir"
}

assert_blocked() {
    [ "$status" -eq 2 ]
    [ "$output" = "$MSG" ]
}

# --- blocked cases (opencode format) ---

@test "blocks: docker ps" {
    run bash -c 'printf "%s" "$1" | bash "$2"' _ "$(opencode_call bash 'docker ps')" "$GUARD"
    assert_blocked
}

@test "blocks: docker run x" {
    run bash -c 'printf "%s" "$1" | bash "$2"' _ "$(opencode_call bash 'docker run x')" "$GUARD"
    assert_blocked
}

@test "blocks: docker build after cd" {
    run bash -c 'printf "%s" "$1" | bash "$2"' _ "$(opencode_call bash 'cd /tmp && docker build .')" "$GUARD"
    assert_blocked
}

@test "blocks: docker exec with env assignment" {
    run bash -c 'printf "%s" "$1" | bash "$2"' _ "$(opencode_call bash 'FOO=1 docker exec c sh')" "$GUARD"
    assert_blocked
}

@test "blocks: sudo docker ps" {
    run bash -c 'printf "%s" "$1" | bash "$2"' _ "$(opencode_call bash 'sudo docker ps')" "$GUARD"
    assert_blocked
}

@test "blocks: bash -c docker ps" {
    run bash -c "printf '%s' '{\"tool\":\"bash\",\"args\":{\"command\":\"bash -c \\\"docker ps\\\"\"},\"cwd\":\"/tmp\"}' | bash \"$GUARD\""
    assert_blocked
}

@test "blocks: docker images after semicolon" {
    run bash -c 'printf "%s" "$1" | bash "$2"' _ "$(opencode_call bash 'echo ok; docker images')" "$GUARD"
    assert_blocked
}

@test "blocks: docker-compose up" {
    run bash -c 'printf "%s" "$1" | bash "$2"' _ "$(opencode_call bash 'docker-compose up')" "$GUARD"
    assert_blocked
}

# --- allowed cases (opencode format) ---

@test "allows: grep docker in a file" {
    run bash -c 'printf "%s" "$1" | bash "$2"' _ "$(opencode_call bash 'grep docker README.md')" "$GUARD"
    [ "$status" -eq 0 ]
}

@test "allows: git commit message mentioning docker" {
    run bash -c "printf '%s' '{\"tool\":\"bash\",\"args\":{\"command\":\"git commit -m \\\"docker\\\"\"},\"cwd\":\"/tmp\"}' | bash \"$GUARD\""
    [ "$status" -eq 0 ]
}

@test "allows: echo docker" {
    run bash -c 'printf "%s" "$1" | bash "$2"' _ "$(opencode_call bash 'echo docker')" "$GUARD"
    [ "$status" -eq 0 ]
}

@test "allows: cat docker-compose.yml" {
    run bash -c 'printf "%s" "$1" | bash "$2"' _ "$(opencode_call bash 'cat docker-compose.yml')" "$GUARD"
    [ "$status" -eq 0 ]
}

@test "allows: kubectl get pods" {
    run bash -c 'printf "%s" "$1" | bash "$2"' _ "$(opencode_call bash 'kubectl get pods')" "$GUARD"
    [ "$status" -eq 0 ]
}

# --- env bypass ---

@test "DEVZONE_ALLOW_DOCKER=1 allows docker ps" {
    run bash -c 'printf "%s" "$1" | DEVZONE_ALLOW_DOCKER=1 bash "$2"' _ "$(opencode_call bash 'docker ps')" "$GUARD"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- both input formats ---

@test "claude format: blocks docker ps" {
    run bash -c "printf '%s' '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"docker ps\"}}' | bash \"$GUARD\" --format claude"
    assert_blocked
}

@test "claude format: allows echo docker" {
    run bash -c "printf '%s' '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo docker\"}}' | bash \"$GUARD\" --format claude"
    [ "$status" -eq 0 ]
}

@test "opencode shell tool name is inspected" {
    run bash -c 'printf "%s" "$1" | bash "$2"' _ "$(opencode_call shell 'docker ps')" "$GUARD"
    assert_blocked
}

# --- non-shell tools are never blocked ---

@test "non-shell tool with docker in content is never blocked" {
    run bash -c "printf '%s' '{\"tool\":\"write\",\"args\":{\"content\":\"docker ps\",\"filePath\":\"x\"},\"cwd\":\"/tmp\"}' | bash \"$GUARD\""
    [ "$status" -eq 0 ]
}

@test "claude non-shell tool with docker in content is never blocked" {
    run bash -c "printf '%s' '{\"tool_name\":\"Write\",\"tool_input\":{\"content\":\"docker ps\",\"file_path\":\"x\"}}' | bash \"$GUARD\" --format claude"
    [ "$status" -eq 0 ]
}

# --- unreadable input ---

@test "unreadable input: exits 0 without blocking" {
    run bash -c "printf '%s' 'not json {{{' | bash \"$GUARD\""
    [ "$status" -eq 0 ]
}

@test "empty input: exits 0 without blocking" {
    run bash -c "printf '' | bash \"$GUARD\""
    [ "$status" -eq 0 ]
}

# --- without jq (python3 available) ---

@test "without jq but with python3: blocks docker ps" {
    local p
    p="$(path_without jq)"
    run bash -c 'PATH="$1" printf "%s" "$2" | PATH="$1" bash "$3"' _ "$p" "$(opencode_call bash 'docker ps')" "$GUARD"
    assert_blocked
}

@test "without jq but with python3: allows echo docker" {
    local p
    p="$(path_without jq)"
    run bash -c 'PATH="$1" printf "%s" "$2" | PATH="$1" bash "$3"' _ "$p" "$(opencode_call bash 'echo docker')" "$GUARD"
    [ "$status" -eq 0 ]
}

# --- without jq and without python3 ---

@test "without jq and python3: unreadable extraction blocks nothing" {
    local p
    p="$(path_without jq python3)"
    run bash -c 'PATH="$1" printf "%s" "$2" | PATH="$1" bash "$3"' _ "$p" "$(opencode_call bash 'docker ps')" "$GUARD"
    [ "$status" -eq 0 ]
}
