#!/usr/bin/env bash
# Build a container image in the Kubernetes workspace pod with the BuildKit
# sidecar (#514). Uses buildctl against $BUILDKIT_HOST (tcp://127.0.0.1:1234).
# On the Docker workstation, use docker build instead.
set -euo pipefail

refuse() {
    echo "devzone build: $*" >&2
    exit 1
}

if [ "${DEVZONE_WORKSPACE:-}" != "kubernetes" ]; then
    refuse "use docker build on the Docker workstation"
fi

if [ "$#" -lt 1 ]; then
    refuse "usage: devzone build <directory> [--tag <name>]"
fi

dir="$1"
shift
tag=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --tag)
            [ "$#" -ge 2 ] || refuse "--tag requires a name"
            tag="$2"
            shift 2
            ;;
        *)
            refuse "unknown argument: $1"
            ;;
    esac
done

[ -d "$dir" ] || refuse "directory not found: $dir"
[ -f "$dir/Dockerfile" ] || refuse "Dockerfile not found in: $dir"

if [ -n "$tag" ]; then
    output="type=image,name=${tag},push=false"
else
    output="type=cacheonly"
fi

addr="${BUILDKIT_HOST:-tcp://127.0.0.1:1234}"
exec buildctl --addr "$addr" build \
    --frontend dockerfile.v0 \
    --local "context=$dir" \
    --local "dockerfile=$dir" \
    --output "$output"
