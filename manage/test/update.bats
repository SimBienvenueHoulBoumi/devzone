#!/usr/bin/env bats
# Creation of a devzone and the manifest it writes (#349). The update itself is
# the Go program's (internal/platform/update, `devzone update`): its tests are in Go.
# The fake packages are built under $BATS_TEST_TMPDIR.

setup() {
    load commun
    # The creation calls the Go program for its checks (#884)
    devzone_go_pret
    kube_isole
    cluster_pret
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CLI="$RACINE/manage/devzone"
    T="$BATS_TEST_TMPDIR"
    cd "$T"
    export DEVZONE_NO_START=1
    build_package v1 0.0.1 ancien
}

build_package() {
    local name="$1" version="$2" mark="$3" folder="$T/$1"
    mkdir -p "$folder/.devcontainer/argocd" "$folder/.devcontainer" "$folder/manage/scripts"
    cp "$CLI" "$folder/manage/devzone"
    chmod +x "$folder/manage/devzone"
    cp "$RACINE/.devcontainer/argocd/conf.sh" "$folder/.devcontainer/argocd/conf.sh"
    # Creation and update live in Go (#884): no manifest script is copied
    printf '{"name":"devzone","version":"%s"}\n' "$version" >"$folder/package.json"
    printf '# makefile %s\n' "$mark" >"$folder/Makefile"
    printf '*.sh text eol=lf\n' >"$folder/.gitattributes"
    printf '# devzone %s\n' "$mark" >"$folder/README.md"
    printf 'licence %s\n' "$mark" >"$folder/LICENSE"
    printf '{"marque":"%s"}\n' "$mark" >"$folder/.devcontainer/devcontainer.json"
    printf '{"marque":"%s"}\n' "$mark" >"$folder/.devcontainer/devcontainer-lock.json"
    printf '#!/usr/bin/env bash\necho %s\n' "$mark" >"$folder/.devcontainer/devzone"
    printf '#!/usr/bin/env bash\necho desinstaller-%s\n' "$mark" >"$folder/manage/scripts/uninstall.sh"
    chmod +x "$folder/.devcontainer/devzone" "$folder/manage/scripts/uninstall.sh"
}

@test "creation: .devzone.version holds the version and one checksum per copied file" {
    DZ="$T/devzone"
    bash "$T/v1/manage/devzone" "$DZ" --kubernetes >/dev/null
    [ "$(sed -n '1p' "$DZ/.devzone.version")" = "version 0.0.1" ]
    for f in .devcontainer/devcontainer.json .devcontainer/devzone Makefile .gitattributes manage/scripts/uninstall.sh README.md LICENSE; do
        attendue="$(node -e 'const fs = require("fs"), crypto = require("crypto"); const h = crypto.createHash("sha256"); h.update(fs.readFileSync(process.argv[1])); process.stdout.write(h.digest("hex"))' "$DZ/$f")"
        grep -qxF "$attendue  $f" "$DZ/.devzone.version" || { echo "empreinte absente : $f"; return 1; }
    done
    ! grep -q 'manage/devzone' "$DZ/.devzone.version" || false
}
