#!/usr/bin/env bash
# Starts the container on the host without ever staying silent:
#   bash manage/scripts/lancer.sh up [folder]        (make up)
#   bash manage/scripts/lancer.sh rebuild [folder]   (make rebuild: rebuild from scratch)
# Full devcontainer CLI output goes to <folder>/.devzone.log; the terminal shows
# key steps, a heartbeat at least every DEVZONE_SIGNE_DE_VIE seconds (30), and a
# question asked inside the container (last log line left unanswered for
# DEVZONE_ATTENTE_QUESTION seconds, 20) is shown and startup is stopped: nobody
# can answer it (the CLI runs without input), waiting would hang forever.
# Portable: bash 3.2 (macOS) and Linux.
set -uo pipefail

mode="${1:-}"
FOLDER="${2:-$PWD}"
case "$mode" in
    up) options=() done_msg="devzone started" ;;
    rebuild) options=(--remove-existing-container) done_msg="devzone rebuilt" ;;
    *)
        echo "usage: bash manage/scripts/lancer.sh up|rebuild [folder]" >&2
        exit 2
        ;;
esac

# Host Docker socket (#432): docker-hote line in instance state, written by devzone
# inside the container. Missing or on: historical behavior.
host_off() {
    local v
    v="$(grep -E '^docker-hote=' "$FOLDER/.devzone.modules" 2>/dev/null | tail -1 | cut -d= -f2 || true)"
    [ "$v" = off ]
}

# Copy of devcontainer.json without the docker-outside-of-docker feature, for a
# container without the host socket. The file lives one level deeper: build
# paths go up one level (../). Written at each start, in a git-ignored folder;
# comments from the original JSON are kept.
# shellcheck disable=SC2034
generate_config_without_host_docker() {
    local folder="$FOLDER/.devcontainer/without-host-docker" context=no
    grep -q '"context"' "$FOLDER/.devcontainer/devcontainer.json" && context=yes
    mkdir -p "$folder"
    awk -v context="$context" '
        /ghcr\.io\/devcontainers\/features\/docker-outside-of-docker/ { next }
        /"build"[[:space:]]*:[[:space:]]*\{[[:space:]]*"dockerfile"[[:space:]]*:[[:space:]]*"Dockerfile"[[:space:]]*\}/ {
            sub(/\{[[:space:]]*"dockerfile"[[:space:]]*:[[:space:]]*"Dockerfile"[[:space:]]*\}/,
                "{ \"dockerfile\": \"../Dockerfile\", \"context\": \"..\" }")
            print
            next
        }
        context == "no" && /"build"[[:space:]]*:[[:space:]]*\{[[:space:]]*$/ {
            print
            print "    \"context\": \"..\","
            next
        }
        /"dockerfile"[[:space:]]*:/ {
            sub(/"dockerfile"[[:space:]]*:[[:space:]]*"[^"]*"/, "\"dockerfile\": \"../Dockerfile\"")
        }
        { print }
    ' "$FOLDER/.devcontainer/devcontainer.json" >"$folder/devcontainer.json"
}

if host_off; then
    generate_config_without_host_docker
    options+=(--config "$FOLDER/.devcontainer/without-host-docker/devcontainer.json")
fi
LOG="$FOLDER/.devzone.log"
HEARTBEAT="${DEVZONE_SIGNE_DE_VIE:-30}"
QUESTION_WAIT="${DEVZONE_ATTENTE_QUESTION:-20}"
ESC="$(printf '\033')"

# Readable log line: without color codes or carriage returns
clean_line() { sed "s/${ESC}\[[0-9;?]*[A-Za-z]//g" | tr -d '\r'; }
# Last non-empty log line, shortened
last_line() { tail -c 2000 "$LOG" | clean_line | grep -v '^[[:space:]]*$' | tail -1 | cut -c1-110; }

# Pending question: last unfinished line (no newline, like a prompt) ending with
# [o/N], [y/N], ? or a password prompt
pattern='(\[[^]]*/[^]]*\]|\?|[Pp]assword[^:]*:|[Mm]ot de passe[^:]*:)[[:space:]]*$'
pending_question() {
    local line
    # Last byte: empty after $( ) if it is a newline
    [ -n "$(tail -c 1 "$LOG")" ] || return 1
    line="$(tail -c 600 "$LOG" | clean_line | tail -1)"
    [[ "$line" =~ $pattern ]] || return 1
    printf '%s\n' "$line" | cut -c1-200
}

# Key steps, each shown once; devzone state copied as-is
seen=" "
read_lines=0
show_steps() {
    local total line
    total="$(wc -l <"$LOG" | tr -d ' ')"
    [ "$total" -gt "$read_lines" ] || return 0
    while IFS= read -r line; do
        case "$line" in
            *"Start: Run: docker buildx build"* | *"Start: Run: docker build"*) announce image "Building image (several minutes the first time)" ;;
            *"Start: Run: docker run"*) announce container "Creating container" ;;
            *"Running the postCreateCommand"*) announce postcreate "Installing in container (repowarden, modules)" ;;
            *"Running the postStartCommand"*) announce poststart "Starting (git identity, clusters, state)" ;;
            "devzone ready"* | "devzone started"* | "devzone rebuilt"* | "devzone : "* | "  ✔ "* | "  ✖ "* | "  ○ "* | "  ⚠ "* | "                    "[!\ ]* | "git-identite : "* | "kube-config : "* | "metrics-server : "*)
                echo "  $line"
                last_announce="$(date +%s)"
                ;;
        esac
    done < <(sed -n "$((read_lines + 1)),${total}p" "$LOG" | clean_line)
    read_lines="$total"
}
announce() {
    case "$seen" in *" $1 "*) return 0 ;; esac
    seen="$seen$1 "
    echo "▶ $2"
    last_announce="$(date +%s)"
}

stop_launch() {
    [ -n "${pid:-}" ] || return 0
    pkill -TERM -P "$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    pid=""
}
trap 'stop_launch; echo; echo "interrupted - log: .devzone.log"; exit 130' INT TERM

# Docker first: without it the CLI would only show a raw JSON error
# shellcheck source=SCRIPTDIR/docker.sh
. "$(dirname "${BASH_SOURCE[0]}")/docker.sh"
docker_ready "${DEVZONE_COMMANDE:-make $mode}" || exit 1

: >"$LOG"
start="$(date +%s)"
last_announce="$start"
echo "▶ Starting devzone (full log: .devzone.log)"
# Empty input: the CLI forwards nothing; a question asked inside the container
# would stay unanswered, hence the detection below
npx -y @devcontainers/cli up --workspace-folder "$FOLDER" ${options[@]+"${options[@]}"} </dev/null >"$LOG" 2>&1 &
pid=$!

size=0
quiet=0
while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    t="$(wc -c <"$LOG" | tr -d ' ')"
    if [ "$t" != "$size" ]; then
        size="$t"
        quiet=0
        show_steps
    else
        quiet=$((quiet + 1))
    fi
    if [ "$quiet" -ge "$QUESTION_WAIT" ] && q="$(pending_question)"; then
        stop_launch
        echo "✖ A container step asks a question and waits for an answer (log idle for $quiet s):" >&2
        echo "    $q" >&2
        echo "  Nobody can answer it here: startup stopped instead of waiting forever." >&2
        echo "  Full log: .devzone.log; report it: https://github.com/SimBienvenueHoulBoumi/devzone/issues" >&2
        echo "  The container may be incomplete: make rebuild to start from scratch." >&2
        exit 1
    fi
    now="$(date +%s)"
    if [ $((now - last_announce)) -ge "$HEARTBEAT" ]; then
        elapsed=$((now - start))
        info="running for $((elapsed / 60)) min $((elapsed % 60)) s"
        [ "$quiet" -lt "$HEARTBEAT" ] || info="$info, no new line for $quiet s"
        echo "  … $info: $(last_line)"
        last_announce="$now"
    fi
done
wait "$pid"
code=$?
pid=""
show_steps
if [ "$code" -eq 0 ]; then
    echo "$done_msg"
else
    tail -15 "$LOG" | clean_line
    echo "failed - full log: .devzone.log"
    exit 1
fi
