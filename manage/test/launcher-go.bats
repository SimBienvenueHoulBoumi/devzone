#!/usr/bin/env bats
# Go binary launched by manage/devzone (#773). The package is rebuilt in a
# temporary folder (the launcher, a package.json, bin/ with one FAKE binary per
# platform: a shell script named like the real file, and bin/SHA256SUMS). A fake
# uname at the head of PATH chooses the platform. The last test uses the real
# binary, to prove that the bridge towards bash does not loop.

setup() {
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    # Real platform, read before the fake uname hides it
    HOST_OS="$(uname -s)"
    HOST_ARCH="$(uname -m)"
    PKG="$BATS_TEST_TMPDIR/pkg"
    FAKEBIN="$BATS_TEST_TMPDIR/fakebin"
    export XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache"
    CACHE="$XDG_CACHE_HOME/devzone/bin"
    unset DEVZONE_NO_GO DEVZONE_FROM_GO DEVZONE_BASH_ENTRY
    mkdir -p "$PKG/manage" "$PKG/bin" "$FAKEBIN"
    cp "$RACINE/manage/devzone" "$PKG/manage/devzone"
    printf '{"name":"devzone","version":"1.2.3"}\n' >"$PKG/package.json"
    # Fake uname: FAKE_OS and FAKE_ARCH answer -s and -m
    cat >"$FAKEBIN/uname" <<'EOT'
#!/bin/sh
case "$1" in
    -s) echo "$FAKE_OS" ;;
    -m) echo "$FAKE_ARCH" ;;
    *) echo "$FAKE_OS" ;;
esac
EOT
    chmod 755 "$FAKEBIN/uname"
    export PATH="$FAKEBIN:$PATH"
    # One fake binary per platform, not executable (npm does not keep the bit)
    for name in devzone-linux-amd64 devzone-linux-arm64 devzone-darwin-amd64 \
        devzone-darwin-arm64 devzone-windows-amd64.exe devzone-windows-arm64.exe; do
        printf '#!/bin/sh\necho "go-binary %s args:$* entry:$DEVZONE_BASH_ENTRY"\n' "$name" >"$PKG/bin/$name"
        chmod 644 "$PKG/bin/$name"
    done
    write_sums
}

# sum_of <file>: SHA-256 of a file
sum_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# write_sums: bin/SHA256SUMS of the files of bin/
write_sums() {
    : >"$PKG/bin/SHA256SUMS"
    for f in "$PKG"/bin/devzone-*; do
        printf '%s  %s\n' "$(sum_of "$f")" "$(basename "$f")" >>"$PKG/bin/SHA256SUMS"
    done
}

# launch <os> <arch> <args...>: runs the launcher of the package as that platform
launch() {
    local os="$1" arch="$2"
    shift 2
    FAKE_OS="$os" FAKE_ARCH="$arch" run bash "$PKG/manage/devzone" "$@"
}

@test "launcher-go: each platform runs its own binary" {
    while read -r os arch want; do
        launch "$os" "$arch" --version
        [ "$status" -eq 0 ]
        [[ "$output" == "go-binary $want args:--version entry:$PKG/manage/devzone" ]] || { echo "$os $arch: $output"; return 1; }
    done <<'EOT'
Linux x86_64 devzone-linux-amd64
Linux aarch64 devzone-linux-arm64
Darwin x86_64 devzone-darwin-amd64
Darwin arm64 devzone-darwin-arm64
MINGW64_NT-10.0-22631 x86_64 devzone-windows-amd64.exe
MSYS_NT-10.0-22631 aarch64 devzone-windows-arm64.exe
CYGWIN_NT-10.0 amd64 devzone-windows-amd64.exe
EOT
}

@test "launcher-go: the binary is copied to the cache with the execute right, arguments kept" {
    launch Linux x86_64 workspace status "two words"
    [ "$status" -eq 0 ]
    [[ "$output" == "go-binary devzone-linux-amd64 args:workspace status two words"* ]] || false
    [ -x "$CACHE/1.2.3/devzone" ]
    [ ! -x "$PKG/bin/devzone-linux-amd64" ]
    [ "$(cat "$CACHE/1.2.3/devzone.sha256")" = "$(sum_of "$PKG/bin/devzone-linux-amd64")" ]
    # No temporary file left behind
    [ "$(ls -A "$CACHE/1.2.3" | wc -l | tr -d ' ')" -eq 2 ]
}

@test "launcher-go: windows copy keeps the .exe name" {
    launch MINGW64_NT-10.0 x86_64 --version
    [ "$status" -eq 0 ]
    [ -x "$CACHE/1.2.3/devzone.exe" ]
}

@test "launcher-go: the cache is reused at the same version" {
    launch Linux x86_64 --version
    echo 'echo cached-copy-kept' >>"$CACHE/1.2.3/devzone"
    launch Linux x86_64 --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"cached-copy-kept"* ]] || { echo "$output"; return 1; }
}

@test "launcher-go: a copy that no longer matches the package is replaced" {
    launch Linux x86_64 --version
    echo 'echo stale' >>"$CACHE/1.2.3/devzone"
    printf 'other\n' >"$CACHE/1.2.3/devzone.sha256"
    launch Linux x86_64 --version
    [[ "$output" != *stale* ]] || { echo "$output"; return 1; }
    [ "$(cat "$CACHE/1.2.3/devzone.sha256")" = "$(sum_of "$PKG/bin/devzone-linux-amd64")" ]
}

@test "launcher-go: another version gets its own cache folder" {
    launch Linux x86_64 --version
    printf '{"name":"devzone","version":"1.2.4"}\n' >"$PKG/package.json"
    launch Linux x86_64 --version
    [ "$status" -eq 0 ]
    [ -x "$CACHE/1.2.3/devzone" ]
    [ -x "$CACHE/1.2.4/devzone" ]
}

@test "launcher-go: a wrong checksum is refused with a message and the bash command runs" {
    sed -i.bak 's/^[0-9a-f]*  devzone-linux-amd64$/0000  devzone-linux-amd64/' "$PKG/bin/SHA256SUMS"
    launch Linux x86_64 --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"checksum of devzone-linux-amd64 does not match"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"using the bash command"* ]] || false
    [ "${lines[${#lines[@]}-1]}" = "1.2.3" ]
    [ ! -e "$CACHE" ]
}

@test "launcher-go: a binary changed after the sums were written is refused" {
    echo 'echo tampered' >>"$PKG/bin/devzone-linux-amd64"
    launch Linux x86_64 --version
    [[ "$output" == *"does not match"* ]] || { echo "$output"; return 1; }
    [ "${lines[${#lines[@]}-1]}" = "1.2.3" ]
    [ ! -e "$CACHE" ]
}

@test "launcher-go: a binary without a line in SHA256SUMS is refused" {
    grep -v 'devzone-linux-amd64' "$PKG/bin/SHA256SUMS" >"$PKG/bin/sums.tmp"
    mv "$PKG/bin/sums.tmp" "$PKG/bin/SHA256SUMS"
    launch Linux x86_64 --version
    [[ "$output" == *"no checksum for devzone-linux-amd64"* ]] || { echo "$output"; return 1; }
    [ "${lines[${#lines[@]}-1]}" = "1.2.3" ]
}

@test "launcher-go: DEVZONE_NO_GO forces the bash command" {
    DEVZONE_NO_GO=1 launch Linux x86_64 --version
    [ "$status" -eq 0 ]
    [ "$output" = "1.2.3" ]
    [ ! -e "$CACHE" ]
}

@test "launcher-go: no binary for the platform keeps the bash command" {
    rm "$PKG/bin/devzone-linux-arm64"
    launch Linux aarch64 --version
    [ "$status" -eq 0 ]
    [ "$output" = "1.2.3" ]
    launch FreeBSD amd64 --version
    [ "$output" = "1.2.3" ]
    launch Linux riscv64 --version
    [ "$output" = "1.2.3" ]
    rm -rf "${PKG:?}/bin"
    launch Linux x86_64 --version
    [ "$output" = "1.2.3" ]
    [ ! -e "$CACHE" ]
}

@test "launcher-go: the bash command is unchanged when the package has no bin/ folder" {
    rm -rf "${PKG:?}/bin"
    run bash "$PKG/manage/devzone" --version
    [ "$output" = "1.2.3" ]
    run bash "$PKG/manage/devzone" --help
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == "devzone 1.2.3: "* ]] || false
}

@test "launcher-go: no loop when the binary calls the launcher back (DEVZONE_FROM_GO)" {
    # A fake binary that does what the bridge does: runs the bash entry point
    # with DEVZONE_FROM_GO=1, and counts its own passes
    cat >"$PKG/bin/devzone-linux-amd64" <<'EOT'
#!/bin/sh
echo pass >>"$PASS_FILE"
DEVZONE_FROM_GO=1 bash "$DEVZONE_BASH_ENTRY" "$@"
EOT
    write_sums
    export PASS_FILE="$BATS_TEST_TMPDIR/passes"
    FAKE_OS=Linux FAKE_ARCH=x86_64 run timeout 30 bash "$PKG/manage/devzone" --version
    [ "$status" -eq 0 ]
    [ "$output" = "1.2.3" ]
    [ "$(wc -l <"$PASS_FILE" | tr -d ' ')" -eq 1 ]
}

@test "launcher-go: control: without DEVZONE_FROM_GO a binary calling the launcher back is launched again" {
    cat >"$PKG/bin/devzone-linux-amd64" <<'EOT'
#!/bin/sh
echo pass >>"$PASS_FILE"
[ "$(wc -l <"$PASS_FILE" | tr -d ' ')" -lt 3 ] || { echo stopped-by-test; exit 0; }
bash "$DEVZONE_BASH_ENTRY" "$@"
EOT
    write_sums
    export PASS_FILE="$BATS_TEST_TMPDIR/passes"
    FAKE_OS=Linux FAKE_ARCH=x86_64 run timeout 30 bash "$PKG/manage/devzone" --version
    [ "$(wc -l <"$PASS_FILE" | tr -d ' ')" -eq 3 ]
}

@test "launcher-go: the real binary delegating to bash does not loop" {
    command -v go >/dev/null 2>&1 || skip "go is not installed"
    export FAKE_OS="$HOST_OS" FAKE_ARCH="$HOST_ARCH"
    case "$HOST_OS-$HOST_ARCH" in
        Linux-x86_64) name=devzone-linux-amd64 ;;
        Linux-aarch64 | Linux-arm64) name=devzone-linux-arm64 ;;
        Darwin-x86_64) name=devzone-darwin-amd64 ;;
        Darwin-arm64) name=devzone-darwin-arm64 ;;
        *) skip "no binary name for this machine" ;;
    esac
    # Real binary built from this checkout; the commands it does not port go to bash
    rm -f "$PKG/bin/$name"
    (cd "$RACINE" && go build -o "$PKG/bin/$name" ./cmd/devzone)
    write_sums
    # A bash that counts each run of the launcher, then runs the real one
    real_bash="$(command -v bash)"
    printf '#!/bin/sh\necho "$*" >>"$BASH_LOG"\nexec "%s" "$@"\n' "$real_bash" >"$FAKEBIN/bash"
    chmod 755 "$FAKEBIN/bash"
    export BASH_LOG="$BATS_TEST_TMPDIR/bash.log"
    # An unknown option is not ported to Go: the binary delegates it to bash, which
    # prints an error and ends. The launcher runs exactly twice: from this test,
    # then from the bridge (with DEVZONE_FROM_GO=1, so without relaunching Go).
    cd "$BATS_TEST_TMPDIR"
    run timeout 60 bash "$PKG/manage/devzone" --no-such-option
    [ "$status" -eq 1 ]
    [[ "$output" == *"option inconnue : --no-such-option"* ]] || { echo "$output"; return 1; }
    [ "$(wc -l <"$BASH_LOG" | tr -d ' ')" -eq 2 ]
    [ -x "$CACHE/1.2.3/devzone" ]
}
