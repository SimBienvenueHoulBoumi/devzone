#!/usr/bin/env bash
# Public DNS for Docker on a GitHub Actions runner (#468): runner ubuntu DNS
# sometimes fails to resolve archive.ubuntu.com while building the container.
# Adds 1.1.1.1 and 8.8.8.8 to daemon.json (existing keys are kept), restarts
# Docker and waits until it responds.
# Guard: refuses outside CI, never run on a workstation.
set -euo pipefail

if [ "${CI:-}" != true ] || [ "${GITHUB_ACTIONS:-}" != true ]; then
    echo "ci-dns.sh: reserved for GitHub Actions (CI and GITHUB_ACTIONS must be true)" >&2
    exit 1
fi

# Overridable path for tests
daemon="${DEVZONE_CI_DOCKER_DAEMON:-/etc/docker/daemon.json}"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# Merge with existing file, or create it if missing
if [ -s "$daemon" ]; then
    jq '. + {"dns": ["1.1.1.1", "8.8.8.8"]}' "$daemon" >"$tmp"
else
    jq -n '{"dns": ["1.1.1.1", "8.8.8.8"]}' >"$tmp"
fi
sudo mkdir -p "$(dirname "$daemon")"
sudo cp "$tmp" "$daemon"

sudo systemctl restart docker

# Wait for Docker: at most 20 seconds
for _ in $(seq 1 20); do
    if docker info >/dev/null 2>&1; then
        exit 0
    fi
    sleep 1
done
echo "ci-dns.sh: Docker did not respond after 20 s" >&2
exit 1
