# Helpers of the agent-pod tests (#222), loaded with `load agent-pod-racine`.
# The projects root of the launcher is a test folder under BATS_TEST_TMPDIR:
# no test creates or needs /workspaces.

# Sets DEVZONE_ROOT to <test tmp>/projets (created inside BATS_TEST_TMPDIR),
# TMPDIR to BATS_TEST_TMPDIR, and REAL_KUBECTL to the kubectl found without the
# fake bin folder (empty when kubectl is absent). Call it in setup, after agent_isole.
racine_test() {
    export DEVZONE_ROOT="$BATS_TEST_TMPDIR/projets"
    export TMPDIR="$BATS_TEST_TMPDIR"
    mkdir -p "$DEVZONE_ROOT"
    REAL_KUBECTL="$(PATH="${PATH#"$BATS_TEST_TMPDIR/bin:"}" command -v kubectl 2>/dev/null || true)"
    export REAL_KUBECTL
}

# Creates <root>/<depot>-wt/<nom> with a .git file that points to
# <root>/<depot>/.git/worktrees/<nom>, as git writes it. Prints the folder.
faux_worktree() {
    local depot="$1" nom="$2"
    local folder="$DEVZONE_ROOT/$depot-wt/$nom"
    mkdir -p "$folder" "$DEVZONE_ROOT/$depot/.git/worktrees/$nom"
    printf 'gitdir: %s/%s/.git/worktrees/%s\n' "$DEVZONE_ROOT" "$depot" "$nom" >"$folder/.git"
    echo "$folder"
}

# Ruby and Python checks of a Pod manifest, run by yaml_valid. Each one exits 0
# when the file is a YAML Pod with metadata.name and a non-empty
# spec.containers, and 1 otherwise (a YAML syntax error also exits 1).
YAML_POD_RUBY='
require "yaml"
doc = YAML.load_file(ARGV[0])
ok = doc.is_a?(Hash) && doc["kind"] == "Pod" &&
     doc["metadata"].is_a?(Hash) && !doc["metadata"]["name"].to_s.empty? &&
     doc["spec"].is_a?(Hash) && doc["spec"]["containers"].is_a?(Array) &&
     !doc["spec"]["containers"].empty?
exit(ok ? 0 : 1)
'
YAML_POD_PYTHON='
import sys, yaml
with open(sys.argv[1]) as handle:
    doc = yaml.safe_load(handle)
ok = (isinstance(doc, dict) and doc.get("kind") == "Pod"
      and isinstance(doc.get("metadata"), dict) and str(doc["metadata"].get("name") or "") != ""
      and isinstance(doc.get("spec"), dict) and isinstance(doc["spec"].get("containers"), list)
      and len(doc["spec"]["containers"]) > 0)
sys.exit(0 if ok else 1)
'

# Prints the YAML parser that works here: ruby (with yaml), else python3 (with
# PyYAML), else nothing. Ruby is tried first: it is the parser of the CI runner.
yaml_parser() {
    if command -v ruby >/dev/null 2>&1 && ruby -ryaml -e 'exit 0' 2>/dev/null; then
        echo ruby
    elif command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
        echo python
    fi
}

# Checks a Pod manifest without any cluster. Returns 0 when valid, 1 when not
# (syntax error, not a Pod, no metadata.name, no containers) and 3 when neither
# Ruby nor PyYAML exists: the caller skips the test then.
yaml_valid() {
    case "$(yaml_parser)" in
        ruby) ruby -ryaml -e "$YAML_POD_RUBY" "$1" ;;
        python) python3 -c "$YAML_POD_PYTHON" "$1" ;;
        *)
            echo "yaml_valid: neither ruby with yaml nor python3 with PyYAML" >&2
            return 3
            ;;
    esac
}

# Returns 0 when the real kubectl can dry-run a minimal Pod. Without a reachable
# cluster it cannot map the Pod kind, so the control dry-run must be skipped.
kubectl_dry_run_ok() {
    local minimal
    [ -n "$REAL_KUBECTL" ] || return 1
    minimal="$BATS_TEST_TMPDIR/dry-run-minimal.yaml"
    printf '%s\n' "apiVersion: v1" "kind: Pod" "metadata:" "  name: dz-dry-run" \
        "spec:" "  containers:" "  - name: c" "    image: busybox" >"$minimal"
    "$REAL_KUBECTL" create --dry-run=client --validate=false -f "$minimal" -o name >/dev/null 2>&1
}
