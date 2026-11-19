#!/usr/bin/env bash
# Guard: block Docker commands run by agents (Kubernetes-first). #670
# Reads tool call JSON on stdin (opencode, or --format claude) and exits 2 on
# stderr when a shell command runs docker/docker-compose as the command word.
# With python3, one program parses the JSON and detects. Otherwise jq extracts
# the tool and command and a best-effort shell detection runs. Without either,
# nothing is blocked.

set -u

MESSAGE="devzone est Kubernetes d'abord : seuls les pods sont des conteneurs. Utilise kubectl, ou un pod ou un namespace jetable (kubectl run, kubectl create ns, puis suppression). Action sur l'hôte lui-même : DEVZONE_ALLOW_DOCKER=1."

[ "${DEVZONE_ALLOW_DOCKER:-}" = "1" ] && exit 0

FORMAT="opencode"
[ "${1:-}" = "--format" ] && [ "${2:-}" = "claude" ] && FORMAT="claude"

INPUT="$(cat 2>/dev/null)" || exit 0
[ -n "$INPUT" ] || exit 0

block() { printf '%s\n' "$MESSAGE" >&2; exit 2; }

if command -v python3 >/dev/null 2>&1; then
    __DG_INPUT="$INPUT" __DG_FORMAT="$FORMAT" __DG_MESSAGE="$MESSAGE" python3 <<'PYTHON'
import json, os, re, sys

try:
    data = json.loads(os.environ.get("__DG_INPUT", ""))
except Exception:
    sys.exit(0)
if not isinstance(data, dict):
    sys.exit(0)
if os.environ.get("__DG_FORMAT", "opencode") == "claude":
    tool = data.get("tool_name") or ""
    inner = data.get("tool_input")
else:
    tool = data.get("tool") or ""
    inner = data.get("args")
cmd = (inner.get("command") if isinstance(inner, dict) else "") or ""
if tool not in ("bash", "shell", "Bash") or not isinstance(cmd, str) or not cmd:
    sys.exit(0)

def is_word(seg, i):
    return re.match(r"docker-compose\b|docker\b", seg[i:]) is not None

def at_pos(seg):
    i = 0
    while True:
        while i < len(seg) and seg[i] in " \t\n\r(": i += 1
        while i < len(seg) and seg[i] == "`": i += 1
        changed = True
        while changed:
            changed = False
            m = re.match(r"[A-Za-z_]\w*=", seg[i:])
            if m:
                i += m.end()
                if i < len(seg) and seg[i] in "\"'":
                    q = seg[i]; i += 1
                    while i < len(seg) and seg[i] != q:
                        if q == '"' and seg[i] == '\\': i += 2
                        else: i += 1
                    if i < len(seg): i += 1
                else:
                    while i < len(seg) and seg[i] not in " \t\n\r;&|)`": i += 1
                while i < len(seg) and seg[i] in " \t\n\r": i += 1
                changed = True
        if seg.startswith("sudo", i) and (i + 4 == len(seg) or not (seg[i + 4].isalnum() or seg[i + 4] in "_-")):
            i += 4
            while i < len(seg) and seg[i] in " \t\n\r": i += 1
            while i < len(seg) and seg[i] == "-":
                while i < len(seg) and seg[i] not in " \t\n\r": i += 1
                while i < len(seg) and seg[i] in " \t\n\r": i += 1
            continue
        return i

def split_segs(s):
    parts, i, start, n, q, d = [], 0, 0, len(s), None, 0
    while i < n:
        c = s[i]
        if q:
            if q == "'":
                if c == "'": q = None
            elif q == '"':
                if c == '\\': i += 2; continue
                if c == '"': q = None
            else:
                if c == "`": q = None
            i += 1; continue
        if c == '\\': i += 2; continue
        if c in "\"'`": q = c; i += 1; continue
        if c == "$" and i + 1 < n and s[i + 1] == "(": d += 1; i += 2; continue
        if c == "(": d += 1; i += 1; continue
        if c == ")" and d > 0: d -= 1; i += 1; continue
        if d == 0:
            if c in ";\n":
                parts.append(s[start:i]); start = i + 1; i += 1; continue
            if c == "&" and i + 1 < n and s[i + 1] == "&":
                parts.append(s[start:i]); start = i + 2; i += 2; continue
            if c == "|" and i + 1 < n and s[i + 1] == "|":
                parts.append(s[start:i]); start = i + 2; i += 2; continue
            if c == "|":
                parts.append(s[start:i]); start = i + 1; i += 1; continue
        i += 1
    parts.append(s[start:])
    return parts

def subshells(s):
    out, i, n, q = [], 0, len(s), None
    while i < n:
        c = s[i]
        if q == "'":
            if c == "'": q = None
            i += 1; continue
        if q == '"':
            if c == '\\': i += 2; continue
            if c == '"': q = None; i += 1; continue
            if c == "`":
                j = i + 1
                while j < n and s[j] != "`": j += 1
                out.append(s[i + 1:j]); i = j + 1; continue
            if c == "$" and i + 1 < n and s[i + 1] == "(": pass
            else: i += 1; continue
        if c == '\\' and q != "'": i += 2; continue
        if c == "'" and q is None: q = "'"; i += 1; continue
        if c == '"' and q is None: q = '"'; i += 1; continue
        if c == "`" and q != "'":
            j = i + 1
            while j < n and s[j] != "`": j += 1
            out.append(s[i + 1:j]); i = j + 1; continue
        if c == "$" and i + 1 < n and s[i + 1] == "(" and q != "'":
            j, depth, q2 = i + 2, 1, None
            while j < n and depth > 0:
                ch = s[j]
                if q2:
                    if q2 == "'":
                        if ch == "'": q2 = None
                    elif q2 == '"':
                        if ch == '\\': j += 2; continue
                        if ch == '"': q2 = None
                    j += 1; continue
                if ch == '\\': j += 2; continue
                if ch in "\"'": q2 = ch; j += 1; continue
                if ch == "$" and j + 1 < n and s[j + 1] == "(": depth += 1; j += 2; continue
                if ch == "(": depth += 1; j += 1; continue
                if ch == ")": depth -= 1; j += 1; continue
                j += 1
            out.append(s[i + 2:j - 1] if j > i + 2 else ""); i = j; continue
        if q == '"': i += 1; continue
        i += 1
    return out

def c_args(s):
    out = []
    for m in re.finditer(r"(^|\s)-c\s+(['\"])(.*?)\2", s, re.DOTALL):
        out.append(m.group(3))
    return out

def check(s, depth=0):
    if depth > 4: return False
    for seg in split_segs(s):
        if is_word(seg, at_pos(seg)): return True
    for inner in c_args(s):
        if check(inner, depth + 1): return True
    for sub in subshells(s):
        if check(sub, depth + 1): return True
    return False

if check(cmd):
    sys.stderr.write(os.environ.get("__DG_MESSAGE", "") + "\n")
    sys.exit(2)
sys.exit(0)
PYTHON
    exit $?
fi

if command -v jq >/dev/null 2>&1; then
    if [ "$FORMAT" = "claude" ]; then
        TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)" || exit 0
        COMMAND="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)" || exit 0
    else
        TOOL="$(printf '%s' "$INPUT" | jq -r '.tool // ""' 2>/dev/null)" || exit 0
        COMMAND="$(printf '%s' "$INPUT" | jq -r '.args.command // ""' 2>/dev/null)" || exit 0
    fi

    shell_fallback_detect() {
        # Best-effort fallback when python3 is unavailable (jq-only path).
        local c="$COMMAND" segs s
        segs="$(printf '%s' "$c" | sed -E 's/&&/\n/g; s/\|\|/\n/g; s/[;|]/\n/g; s/\$\(/\n/g; s/`/\n/g')"
        while IFS= read -r s; do
            s="$(printf '%s' "$s" | sed 's/^[[:space:]()]*//')"
            while printf '%s' "$s" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*='; do
                s="$(printf '%s' "$s" | sed -E 's/^[A-Za-z_][A-Za-z0-9_]*=([^[:space:]]*)[[:space:]]*//; s/^[A-Za-z_][A-Za-z0-9_]*=[[:space:]]*//')"
            done
            if printf '%s' "$s" | grep -qE '^sudo([[:space:]]|$)'; then
                s="$(printf '%s' "$s" | sed -E 's/^sudo[[:space:]]+//')"
                while printf '%s' "$s" | grep -qE '^-[^[:space:]]*'; do
                    s="$(printf '%s' "$s" | sed -E 's/^-[^[:space:]]*[[:space:]]*//')"
                done
                while printf '%s' "$s" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*='; do
                    s="$(printf '%s' "$s" | sed -E 's/^[A-Za-z_][A-Za-z0-9_]*=([^[:space:]]*)[[:space:]]*//; s/^[A-Za-z_][A-Za-z0-9_]*=[[:space:]]*//')"
                done
            fi
            if printf '%s' "$s" | grep -qE '^(docker-compose|docker)([[:space:]]|$)'; then
                return 0
            fi
        done <<EOF
$segs
EOF
        if printf '%s' "$c" | grep -qE -- "-c[[:space:]]+['\"]?[[:space:]]*(sudo[[:space:]]+)?(docker-compose|docker)([[:space:]]|['\"]|$)"; then
            return 0
        fi
        return 1
    }

    case "$TOOL" in bash|shell|Bash) ;; *) exit 0 ;; esac
    [ -n "$COMMAND" ] || exit 0
    shell_fallback_detect && block
    exit 0
fi

exit 0
