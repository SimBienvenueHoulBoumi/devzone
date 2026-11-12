#!/usr/bin/env bats
# devzone build: BuildKit client in the Kubernetes workspace pod (#514).
# Fake buildctl logs its arguments; no real cluster or build runs.

setup() {
    load commun
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    T="$BATS_TEST_TMPDIR"
    mkdir -p "$T/bin" "$T/app"
    printf 'FROM scratch\n' >"$T/app/Dockerfile"
    cat >"$T/bin/buildctl" <<'BIN'
#!/usr/bin/env bash
echo "buildctl $*" >>"$BATS_TEST_TMPDIR/buildctl.log"
exit 0
BIN
    chmod +x "$T/bin/buildctl"
    export PATH="$T/bin:$PATH"
    export DEVZONE_RACINE="$T/racine"
    mkdir -p "$DEVZONE_RACINE"
}

@test "devzone build in the pod: cacheonly output and expected buildctl arguments" {
    export DEVZONE_WORKSPACE=kubernetes
    export BUILDKIT_HOST=tcp://127.0.0.1:1234
    run bash "$DEVZONE" build "$T/app"
    [ "$status" -eq 0 ] || false
    grep -q -- "--addr tcp://127.0.0.1:1234" "$T/buildctl.log" || false
    grep -q -- "--frontend dockerfile.v0" "$T/buildctl.log" || false
    grep -q -- "--local context=$T/app" "$T/buildctl.log" || false
    grep -q -- "--local dockerfile=$T/app" "$T/buildctl.log" || false
    grep -q -- "--output type=cacheonly" "$T/buildctl.log" || false
}

@test "devzone build --tag in the pod: image output without push" {
    export DEVZONE_WORKSPACE=kubernetes
    export BUILDKIT_HOST=tcp://127.0.0.1:1234
    run bash "$DEVZONE" build "$T/app" --tag app:1
    [ "$status" -eq 0 ] || false
    grep -q -- "--output type=image,name=app:1,push=false" "$T/buildctl.log" || false
}

@test "devzone build outside the pod: refuses with a clear message" {
    unset DEVZONE_WORKSPACE
    run bash "$DEVZONE" build "$T/app"
    [ "$status" -ne 0 ] || false
    [[ "$output" == *"use docker build on the Docker workstation"* ]] || false
    [ ! -f "$T/buildctl.log" ] || false
}

@test "devzone build without a Dockerfile: clear error and non-zero exit" {
    export DEVZONE_WORKSPACE=kubernetes
    mkdir -p "$T/empty"
    run bash "$DEVZONE" build "$T/empty"
    [ "$status" -ne 0 ] || false
    [[ "$output" == *"Dockerfile"* ]] || false
}

@test "Dockerfile installs buildctl from moby/buildkit with SHA-256 verification" {
    dockerfile="$BATS_TEST_DIRNAME/../../.devcontainer/Dockerfile"
    grep -q -- "moby/buildkit" "$dockerfile" || false
    grep -q -- "BUILDKIT_VERSION" "$dockerfile" || false
    grep -q -- "buildctl" "$dockerfile" || false
    grep -q -- "sha256sum -c" "$dockerfile" || false
}

@test "BuildKit version matches between versions.env, Dockerfile and the chart" {
    root="$BATS_TEST_DIRNAME/../.."
    env_ver="$(sed -nE 's/^BUILDKIT_VERSION=([^[:space:]]+)$/\1/p' "$root/.devcontainer/versions.env" | head -1)"
    df_ver="$(sed -nE 's/^ARG BUILDKIT_VERSION=([^[:space:]]+)$/\1/p' "$root/.devcontainer/Dockerfile" | head -1)"
    chart_img="$(awk '/^buildkit:/{p=1} p && /^  image:/{print $2; exit}' "$root/charts/devzone-workspace/values.yaml")"
    chart_ver="${chart_img##*:v}"
    chart_ver="${chart_ver%%-*}"
    [ -n "$env_ver" ] || false
    [ "$env_ver" = "$df_ver" ] || false
    [ "$env_ver" = "$chart_ver" ] || false
}
