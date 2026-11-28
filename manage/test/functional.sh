#!/usr/bin/env bash
# Pod workspace functional test on a kind cluster (#869). The old container-mode
# scenarios were retired with the pod-only model; this script keeps the historical
# name used by CI and make. It builds the workspace image, loads it into kind,
# prepares a devzone folder and builds the Go program.
#
# Deploying the workspace goes through Argo CD, which only serves published charts; it is covered by the Go tests, not by this scenario.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER="${DEVZONE_KIND_CLUSTER:-devzone-ci}"
IMAGE="${DEVZONE_WORKSPACE_IMAGE:-devzone-workspace:ci}"
TMP="$(mktemp -d)"
DEVZONE_DIR="$TMP/devzone"
passed=0
failed=0
ENGINE="docker"

# cleanup removes the temporary kind cluster and temp dir so CI runners stay clean.
cleanup() {
  local code=$?
  set +e
  if [ "${CREATED:-0}" = 1 ] && command -v kind >/dev/null 2>&1; then
    kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP"
  exit "$code"
}
trap cleanup EXIT

ok() { passed=$((passed + 1)); echo "  ✔ $1"; }
ko() { failed=$((failed + 1)); echo "  ✖ $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | tail -20 | sed 's/^/    /'; }

# need fails early when a required CLI is missing because the kind scenario cannot run.
need() { command -v "$1" >/dev/null 2>&1 || { echo "✖ missing required command: $1" >&2; exit 1; }; }

for cmd in "$ENGINE" kind kubectl node; do need "$cmd"; done

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "✖ kind cluster $CLUSTER already exists" >&2
  exit 1
fi

CREATED=0
echo "▶ kind cluster $CLUSTER"
kind create cluster --name "$CLUSTER" --wait 120s
CREATED=1
kubectl cluster-info --context "kind-$CLUSTER" >/dev/null
ok "kind cluster ready"

echo "▶ build workspace image"
df="$ROOT/.devcontainer/Dockerfile"
"$ENGINE" image build -f "$df" -t "$IMAGE" "$ROOT/.devcontainer"
kind load "${ENGINE}-image" "$IMAGE" --name "$CLUSTER"
ok "image built and loaded: $IMAGE"

echo "▶ devzone folder"
mkdir -p "$DEVZONE_DIR/workspace"
cp "$ROOT/.gitignore" "$DEVZONE_DIR/.gitignore" 2>/dev/null || true
cp -R "$ROOT/.devcontainer" "$DEVZONE_DIR/.devcontainer"
cp -R "$ROOT/charts" "$DEVZONE_DIR/charts"
cp -R "$ROOT/manage" "$DEVZONE_DIR/manage"
cp "$ROOT/package.json" "$DEVZONE_DIR/package.json"
cp "$ROOT/Makefile" "$DEVZONE_DIR/Makefile" 2>/dev/null || true
ok "devzone folder prepared"

echo "▶ Go program of the workspace commands"
(cd "$ROOT" && go build -o "$TMP/devzone-go" ./cmd/devzone) || exit 1
ok "Go program built"

echo
echo "Result: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
