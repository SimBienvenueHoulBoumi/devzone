#!/usr/bin/env bash
# Pod workspace functional test on a kind cluster (#869). The old container-mode
# scenarios were retired with the pod-only model; this script keeps the historical
# name used by CI and make. It builds the workspace image, loads it into kind,
# installs charts/devzone-workspace, then exercises start/status/stop and a module.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER="${DEVZONE_KIND_CLUSTER:-devzone-ci}"
IMAGE="${DEVZONE_WORKSPACE_IMAGE:-devzone-workspace:ci}"
NAMESPACE="devzone-workspace"
POD="devzone-workspace-0"
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

for cmd in "$ENGINE" kind kubectl helm node; do need "$cmd"; done

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
printf 'argocd=off\n' > "$DEVZONE_DIR/.devzone.modules"
ok "devzone folder prepared"

echo "▶ Go program of the workspace commands"
DEVZONE_HOST_BIN="$TMP/devzone-go"
(cd "$ROOT" && go build -o "$DEVZONE_HOST_BIN" ./cmd/devzone) || exit 1
export DEVZONE_HOST_BIN
echo "▶ workspace start/status/stop"
set +e
start_out="$(cd "$DEVZONE_DIR" && DEVZONE_ARGOCD_REVISION='' bash "$ROOT/manage/workspace.sh" start --image "$IMAGE" 2>&1)"
start_rc=$?
set -e
if [ "$start_rc" -eq 0 ]; then
  ok "workspace start"
else
  ko "workspace start" "$start_out"
fi

# A CI node has too few CPUs for the chart defaults (a limit without request
# reserves the whole limit): lower the requests of this test release only. A
# never-ready StatefulSet pod does not roll by itself, hence the deletion.
set +e
fit_out="$(helm --kube-context "kind-$CLUSTER" -n "$NAMESPACE" upgrade devzone-workspace "$ROOT/charts/devzone-workspace" --reuse-values \
  --set resources.requests.cpu=100m --set resources.requests.memory=256Mi \
  --set kubedock.resources.requests.cpu=100m --set kubedock.resources.requests.memory=128Mi \
  --set buildkit.resources.requests.cpu=100m --set buildkit.resources.requests.memory=256Mi 2>&1 &&
  kubectl --context "kind-$CLUSTER" -n "$NAMESPACE" delete "pod/$POD" --ignore-not-found 2>&1 &&
  kubectl --context "kind-$CLUSTER" -n "$NAMESPACE" wait --for=create "pod/$POD" --timeout=60s 2>&1)"
fit_rc=$?
set -e
if [ "$fit_rc" -eq 0 ]; then
  ok "resource requests fitted to the node"
else
  ko "resource requests fitted to the node" "$fit_out"
fi

set +e
status_out="$(cd "$DEVZONE_DIR" && bash "$ROOT/manage/workspace.sh" status 2>&1)"
status_rc=$?
set -e
if [ "$status_rc" -eq 0 ] && printf '%s' "$status_out" | grep -q "$POD"; then
  ok "workspace status"
else
  ko "workspace status" "$status_out"
fi

if kubectl --context "kind-$CLUSTER" -n "$NAMESPACE" wait --for=condition=Ready "pod/$POD" --timeout=300s >/dev/null 2>&1; then
  ok "pod ready"
else
  ko "pod ready" "$(kubectl --context "kind-$CLUSTER" -n "$NAMESPACE" get pods -o wide 2>&1; kubectl --context "kind-$CLUSTER" -n "$NAMESPACE" describe "pod/$POD" 2>&1 | tail -60)"
fi

echo "▶ module"
set +e
module_out="$(cd "$DEVZONE_DIR" && bash "$ROOT/manage/workspace.sh" services status 2>&1)"
module_rc=$?
set -e
if [ "$module_rc" -eq 0 ]; then
  ok "workspace services status (module command)"
else
  ko "workspace services status" "$module_out"
fi

set +e
stop_out="$(cd "$DEVZONE_DIR" && bash "$ROOT/manage/workspace.sh" stop 2>&1)"
stop_rc=$?
set -e
if [ "$stop_rc" -eq 0 ]; then
  ok "workspace stop"
else
  ko "workspace stop" "$stop_out"
fi

echo
echo "Result: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
