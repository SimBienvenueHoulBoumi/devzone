#!/usr/bin/env bats
# Module gitlab (#239) : installer, désinstaller, état, seed. Faux kind,
# kubectl, helm, curl et git dans le PATH : aucun cluster n'est créé. Chaque
# faux binaire journalise ses arguments dans $BATS_TEST_TMPDIR/<outil>.log.

setup() {
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    GITLAB="$BATS_TEST_DIRNAME/../../.devcontainer/gitlab/gitlab.sh"
    export HOME="$BATS_TEST_TMPDIR/home"
    export DEVZONE_RACINE="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_ETAT="$BATS_TEST_TMPDIR/modules"
    export DEVZONE_MEMINFO="$BATS_TEST_TMPDIR/meminfo"
    export KIND_CLUSTERS="$BATS_TEST_TMPDIR/clusters"
    SECRETS="$DEVZONE_RACINE/workspace/.gitlab"
    mkdir -p "$HOME" "$DEVZONE_RACINE/workspace" "$BATS_TEST_TMPDIR/bin"
    printf 'MemAvailable: 16000000 kB\n' >"$DEVZONE_MEMINFO"
    : >"$KIND_CLUSTERS"

    # kind : clusters tenus dans $KIND_CLUSTERS
    cat >"$BATS_TEST_TMPDIR/bin/kind" <<'KIND'
#!/usr/bin/env bash
echo "kind $*" >>"$BATS_TEST_TMPDIR/kind.log"
case "$1 $2" in
    "get clusters") cat "$KIND_CLUSTERS" ;;
    "create cluster") echo "${4:-}" >>"$KIND_CLUSTERS" ;;
    "delete cluster") grep -vx "${4:-}" "$KIND_CLUSTERS" >"$KIND_CLUSTERS.tmp" || true; mv "$KIND_CLUSTERS.tmp" "$KIND_CLUSTERS" ;;
esac
KIND
    # kubectl : secret root « password123 » (base64), pod toolbox, jeton root
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"$BATS_TEST_TMPDIR/kubectl.log"
case "$*" in
    *"config current-context"*) echo "${FAUX_CONTEXTE:-}" ;;
    *"get secret"*) echo "cGFzc3dvcmQxMjM=" ;;
    *"get pod"*) echo "gitlab-toolbox-1" ;;
    *"gitlab-rails runner"*) echo "jeton-root-secret" ;;
esac
KUBE
    cat >"$BATS_TEST_TMPDIR/bin/helm" <<'HELM'
#!/usr/bin/env bash
echo "helm $*" >>"$BATS_TEST_TMPDIR/helm.log"
HELM
    # docker : mapping SSH du cluster kind (nodePort 32022) ; FAUX_DOCKER_PORT l'active
    cat >"$BATS_TEST_TMPDIR/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
echo "docker $*" >>"$BATS_TEST_TMPDIR/docker.log"
case "$*" in
    *"port gitlab-control-plane 32022"*)
        if [ -n "${FAUX_DOCKER_PORT:-}" ]; then
            echo "0.0.0.0:2224 -> 32022/tcp"
            exit 0
        fi
        exit 1
        ;;
esac
exit 0
DOCKER
    # curl : API GitLab simulée ; FAUX_GROUPE_KO=1 fait échouer le groupe
    cat >"$BATS_TEST_TMPDIR/bin/curl" <<'CURL'
#!/usr/bin/env bash
echo "curl $*" >>"$BATS_TEST_TMPDIR/curl.log"
[ -n "${FAUX_GITLAB_KO:-}" ] && exit 7
case "$*" in
    *"api/v4/groups/devzone"*)
        [ -n "${FAUX_GROUPE_KO:-}" ] && exit 22
        echo '{"id":42}' ;;
    *"--request POST"*"api/v4/groups"*) [ -n "${FAUX_GROUPE_KO:-}" ] && exit 22 ;;
    *"--request POST"*"api/v4/user/runners"*) echo '{"token":"jeton-runner-secret"}' ;;
    # Branche main : absente tant que le faux git n'a pas poussé
    *"api/v4/projects/devzone%2Fdemo/repository"*) [ -f "$BATS_TEST_TMPDIR/pousse" ] || exit 22 ;;
    *"--request POST"*) ;;
    *"api/v4/projects/devzone%2Fdemo"*) exit 22 ;;
    *"api/v4/users?username=dev"*) echo '[]' ;;
    *"api/v4/runners/all"*) echo "${FAUX_RUNNERS:-[]}" ;;
esac
exit 0
CURL
    cat >"$BATS_TEST_TMPDIR/bin/git" <<'GIT'
#!/usr/bin/env bash
echo "git $*" >>"$BATS_TEST_TMPDIR/git.log"
case "$*" in *" push "*) touch "$BATS_TEST_TMPDIR/pousse" ;; esac
GIT
    # npm : rien d'installé globalement (devzone appliquer vérifie repowarden)
    cat >"$BATS_TEST_TMPDIR/bin/npm" <<'NPM'
#!/usr/bin/env bash
if [ "${1:-}" = ls ]; then printf '{"dependencies":{}}\n'; fi
NPM
    chmod +x "$BATS_TEST_TMPDIR"/bin/*
    HELM_BIN="$(command -v helm)"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "gitlab : désactivé par défaut" {
    run bash "$DEVZONE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"○ module gitlab"* ]] || false
    run bash "$DEVZONE" actif gitlab
    [ "$status" -ne 0 ]
}

@test "gitlab : moins de 8 Go de RAM libre → refus, rien lancé" {
    printf 'MemAvailable: 4000000 kB\n' >"$DEVZONE_MEMINFO"
    run bash "$GITLAB" installer
    [ "$status" -eq 2 ]
    [[ "$output" == *"8 Go"* ]] || false
    [ ! -e "$BATS_TEST_TMPDIR/kind.log" ] || ! grep -q "create" "$BATS_TEST_TMPDIR/kind.log" || false
    [ ! -e "$BATS_TEST_TMPDIR/helm.log" ]
}

@test "gitlab : autre cluster présent, pas gitlab → cluster gitlab créé" {
    echo "dev" >"$KIND_CLUSTERS"
    run bash "$GITLAB" installer
    [ "$status" -eq 0 ]
    grep -q "kind create cluster --name gitlab" "$BATS_TEST_TMPDIR/kind.log"
}

@test "gitlab : cluster gitlab déjà là → pas recréé" {
    echo "gitlab" >"$KIND_CLUSTERS"
    run bash "$GITLAB" installer
    [ "$status" -eq 0 ]
    ! grep -q "kind create" "$BATS_TEST_TMPDIR/kind.log" || false
}

@test "gitlab : values.yaml configure le clone SSH (port 2224, nodePort gitlab-shell 32022)" {
    grep -q "port: 2224" "$BATS_TEST_DIRNAME/../../.devcontainer/gitlab/values.yaml" || false
    grep -q "gitlab-shell: 32022" "$BATS_TEST_DIRNAME/../../.devcontainer/gitlab/values.yaml" || false
}

@test "gitlab : kind.yaml mappe le nodePort gitlab-shell 32022 sur le hostPort 2224" {
    grep -q "containerPort: 32022" "$BATS_TEST_DIRNAME/../../.devcontainer/gitlab/kind.yaml" || false
    ! grep -q "containerPort: 22" "$BATS_TEST_DIRNAME/../../.devcontainer/gitlab/kind.yaml" || false
}

@test "gitlab : helm template : ssh_port 2224 et nodePort gitlab-shell 32022" {
    if [ -z "${DEVZONE_GITLAB_CHART:-}" ] || ! command -v helm >/dev/null 2>&1; then
        skip "helm indisponible (DEVZONE_GITLAB_CHART ou helm)"
    fi
    local helm_bin="${HELM_BIN:-$(command -v helm)}"
    [ -x "$helm_bin" ] || skip "helm indisponible (DEVZONE_GITLAB_CHART ou helm)"
    local sortie
    sortie="$("$helm_bin" template gitlab "${DEVZONE_GITLAB_CHART:-/tmp/gl/gitlab}" --version 9.11.16 -f "$BATS_TEST_DIRNAME/../../.devcontainer/gitlab/values.yaml" 2>&1)"
    [[ "$sortie" == *"ssh_port: 2224"* ]] || false
    [[ "$sortie" == *"nodePort: 32022"* ]] || false
    [[ "$sortie" != *"nodePort: 2224"* ]] || false
}

@test "gitlab : cluster existant sans mapping SSH → avertissement, installation continue" {
    echo "gitlab" >"$KIND_CLUSTERS"
    run bash "$GITLAB" installer
    [ "$status" -eq 0 ]
    [[ "$output" == *"clone SSH (port 2224) indisponible"* ]] || false
}

@test "gitlab : cluster existant avec mapping SSH → pas d'avertissement" {
    echo "gitlab" >"$KIND_CLUSTERS"
    FAUX_DOCKER_PORT=1 run bash "$GITLAB" installer
    [ "$status" -eq 0 ]
    [[ "$output" != *"clone SSH (port 2224) indisponible"* ]] || false
}

@test "gitlab : charts figés, contexte kind-gitlab explicite" {
    run bash "$GITLAB" installer
    [ "$status" -eq 0 ]
    grep -q -- "--kube-context kind-gitlab upgrade --install gitlab gitlab/gitlab --version 9.11.16" "$BATS_TEST_TMPDIR/helm.log"
    grep -q -- "--kube-context kind-gitlab upgrade --install gitlab-runner gitlab/gitlab-runner --version 0.88.2" "$BATS_TEST_TMPDIR/helm.log"
}

@test "gitlab : secrets dans workspace/.gitlab (600), jamais dans le dépôt ni affichés" {
    run bash "$GITLAB" installer
    [ "$status" -eq 0 ]
    for f in root-password root-token runner-token dev-password; do
        [ -f "$SECRETS/$f" ] || { echo "absent : $f"; false; }
        [ "$(stat -c %a "$SECRETS/$f" 2>/dev/null || stat -f %Lp "$SECRETS/$f")" = 600 ]
    done
    [ "$(cat "$SECRETS/root-password")" = password123 ]
    [ ! -e "$BATS_TEST_DIRNAME/../../.devcontainer/workspace" ]
    [[ "$output" != *"password123"* ]] || false
    [[ "$output" != *"jeton-root-secret"* ]] || false
    [[ "$output" != *"jeton-runner-secret"* ]] || false
}

@test "gitlab : projet créé avec l'ID numérique du groupe, push avec le jeton root" {
    run bash "$GITLAB" installer
    [ "$status" -eq 0 ]
    grep -q "namespace_id=42" "$BATS_TEST_TMPDIR/curl.log"
    grep -q "oauth2:jeton-root-secret@127.0.0.1:8929/devzone/demo.git" "$BATS_TEST_TMPDIR/git.log"
    ! grep -q "jeton-runner-secret@" "$BATS_TEST_TMPDIR/git.log" || false
}

@test "gitlab : installation relancée → projet demo pas re-poussé, RAM non revérifiée" {
    run bash "$GITLAB" installer
    [ "$status" -eq 0 ]
    [ "$(grep -c " push " "$BATS_TEST_TMPDIR/git.log")" -eq 1 ]
    # GitLab installé occupe la mémoire : la relance ne la revérifie pas
    printf 'MemAvailable: 4000000 kB\n' >"$DEVZONE_MEMINFO"
    run bash "$GITLAB" installer
    [ "$status" -eq 0 ]
    [ "$(grep -c " push " "$BATS_TEST_TMPDIR/git.log")" -eq 1 ]
}

@test "gitlab : échec du seed → installation en échec, message clair, pas de runner" {
    export FAUX_GROUPE_KO=1
    run bash "$GITLAB" installer
    [ "$status" -ne 0 ]
    [[ "$output" == *"groupe devzone"* ]] || false
    ! grep -q "gitlab-runner" "$BATS_TEST_TMPDIR/helm.log" || false
}

@test "gitlab : désinstaller retire cluster, contexte et secrets, restaure le contexte" {
    export FAUX_CONTEXTE=kind-dev
    run bash "$GITLAB" installer
    [ "$status" -eq 0 ]
    [ "$(cat "$SECRETS/contexte-precedent")" = kind-dev ]
    run bash "$GITLAB" desinstaller
    [ "$status" -eq 0 ]
    grep -q "kind delete cluster --name gitlab" "$BATS_TEST_TMPDIR/kind.log"
    grep -q "kubectl config delete-context kind-gitlab" "$BATS_TEST_TMPDIR/kubectl.log"
    grep -q "kubectl config use-context kind-dev" "$BATS_TEST_TMPDIR/kubectl.log"
    [ ! -e "$SECRETS" ]
    [ ! -s "$KIND_CLUSTERS" ]
}

@test "gitlab : état désactivé, prêt (runner en ligne ou non), en échec" {
    run bash "$GITLAB" etat
    [ "$output" = "désactivé" ]
    echo gitlab >"$KIND_CLUSTERS"
    mkdir -p "$SECRETS" && echo jeton >"$SECRETS/root-token"
    run bash "$GITLAB" etat
    [ "$output" = "prêt : http://gitlab.localhost:8929, runner hors ligne" ]
    FAUX_RUNNERS='[{"id":1}]' run bash "$GITLAB" etat
    [ "$output" = "prêt : http://gitlab.localhost:8929, runner en ligne" ]
    FAUX_GITLAB_KO=1 run bash "$GITLAB" etat
    [ "$output" = "en échec : devzone appliquer" ]
}

@test "devzone : activer gitlab saute l'installation si prêt et runner en ligne" {
    echo "gitlab" >"$KIND_CLUSTERS"
    mkdir -p "$SECRETS" && echo jeton >"$SECRETS/root-token"
    FAUX_RUNNERS='[{"id":1}]' run bash "$DEVZONE" activer gitlab
    [ "$status" -eq 0 ]
    [[ "$output" == *"déjà actif, rien à faire"* ]] || false
    ! grep -q "upgrade --install" "$BATS_TEST_TMPDIR/helm.log" || false
}

@test "devzone : activer gitlab : prêt sans runner en ligne → installer (seed, runner)" {
    echo "gitlab" >"$KIND_CLUSTERS"
    mkdir -p "$SECRETS" && echo jeton >"$SECRETS/root-token"
    run bash "$DEVZONE" activer gitlab
    [ "$status" -eq 0 ]
    [[ "$output" != *"déjà actif, rien à faire"* ]] || false
    grep -q -- "--kube-context kind-gitlab upgrade --install gitlab gitlab/gitlab --version 9.11.16" "$BATS_TEST_TMPDIR/helm.log"
}

@test "devzone appliquer : gitlab actif, prêt sans runner en ligne → installer" {
    printf 'gitlab=on\n' >"$DEVZONE_ETAT"
    echo "gitlab" >"$KIND_CLUSTERS"
    mkdir -p "$SECRETS" && echo jeton >"$SECRETS/root-token"
    run bash "$DEVZONE" appliquer
    [ "$status" -eq 0 ]
    grep -q -- "--kube-context kind-gitlab upgrade --install gitlab gitlab/gitlab --version 9.11.16" "$BATS_TEST_TMPDIR/helm.log"
}

@test "devzone appliquer : gitlab actif, prêt runner en ligne → pas d'installer" {
    printf 'gitlab=on\n' >"$DEVZONE_ETAT"
    echo "gitlab" >"$KIND_CLUSTERS"
    mkdir -p "$SECRETS" && echo jeton >"$SECRETS/root-token"
    FAUX_RUNNERS='[{"id":1}]' run bash "$DEVZONE" appliquer
    [ "$status" -eq 0 ]
    [[ "$output" == *"déjà actif, rien à faire"* ]] || false
    [ ! -e "$BATS_TEST_TMPDIR/helm.log" ]
}

@test "devzone appliquer : gitlab désactivé → rien" {
    printf 'gitlab=off\n' >"$DEVZONE_ETAT"
    run bash "$DEVZONE" appliquer
    [ "$status" -eq 0 ]
    [ ! -e "$BATS_TEST_TMPDIR/helm.log" ]
    [ ! -e "$BATS_TEST_TMPDIR/kind.log" ]
}

@test "gitlab : valeurs — host sans port, port externe par GITLAB_PORT" {
    local values="$BATS_TEST_DIRNAME/../../.devcontainer/gitlab/values.yaml"
    grep -Eq 'name: gitlab\.localhost([[:space:]]|$)' "$values"
    grep -q 'GITLAB_PORT: "8929"' "$values"
    ! grep -q "hostnameOverride" "$values" || false
    ! grep -Eq 'gitlab-shell:[[:space:]]*2224' "$values" || false
}

@test "gitlab : valeurs helm — host sans port, port externe par GITLAB_PORT" {
    [ -n "${DEVZONE_GITLAB_CHART:-}" ] || skip "DEVZONE_GITLAB_CHART absent"
    local helm_bin
    helm_bin="$(PATH=/usr/local/bin:/usr/bin:/bin command -v helm 2>/dev/null || true)"
    [ -n "$helm_bin" ] || skip "helm absent"
    local chart="$DEVZONE_GITLAB_CHART"
    [ -d "$chart" ] || skip "chart absent"
    local values="$BATS_TEST_DIRNAME/../../.devcontainer/gitlab/values.yaml"
    run "$helm_bin" template gitlab "$chart" -f "$values" --namespace gitlab
    [ "$status" -eq 0 ]
    local rendu="$output"
    printf '%s\n' "$rendu" | grep -qE '^[[:space:]]*host: gitlab\.localhost$' || false
    local webservice
    webservice="$(printf '%s\n' "$rendu" | awk '
        /^kind: Deployment$/ { dans = 1; nom = 0; bloc = "" }
        dans { bloc = bloc $0 "\n" }
        dans && /^  name: gitlab-webservice-default$/ { nom = 1 }
        dans && /^---$/ { if (nom) printf "%s", bloc; dans = 0; nom = 0 }
        END { if (dans && nom) printf "%s", bloc }
    ')"
    [[ "$webservice" == *"name: GITLAB_PORT"* ]] || false
    [[ "$webservice" == *'value: "8929"'* ]] || false
    ! printf '%s\n' "$rendu" | grep -q "nodePort: 2224" || false
}
