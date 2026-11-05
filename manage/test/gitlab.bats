#!/usr/bin/env bats
# Module gitlab (#239, #273) : installer, désinstaller, état, seed, hôte
# gitlab.localhost dans /etc/hosts (DEVZONE_HOSTS) et démarrage. Faux kind,
# kubectl, helm, curl, git, docker et gh dans le PATH : aucun cluster n'est
# créé. Chaque faux binaire journalise ses arguments dans
# $BATS_TEST_TMPDIR/<outil>.log.

setup() {
    load commun
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    GITLAB="$BATS_TEST_DIRNAME/../../.devcontainer/gitlab/gitlab.sh"
    DEMARRAGE="$BATS_TEST_DIRNAME/../../.devcontainer/demarrage.sh"
    relais_docker_isole
    kube_isole
    export HOME="$BATS_TEST_TMPDIR/home"
    export DEVZONE_RACINE="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_ETAT="$BATS_TEST_TMPDIR/modules"
    export DEVZONE_MEMINFO="$BATS_TEST_TMPDIR/meminfo"
    export DEVZONE_HOSTS="$BATS_TEST_TMPDIR/hosts"
    export KIND_CLUSTERS="$BATS_TEST_TMPDIR/clusters"
    SECRETS="$DEVZONE_RACINE/workspace/.gitlab"
    mkdir -p "$HOME" "$DEVZONE_RACINE/workspace" "$BATS_TEST_TMPDIR/bin"
    printf 'MemAvailable: 16000000 kB\n' >"$DEVZONE_MEMINFO"
    : >"$KIND_CLUSTERS"
    printf '127.0.0.1 localhost\n' >"$DEVZONE_HOSTS"

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
    # docker : network connect (réseau kind), mapping SSH du cluster kind
    # (nodePort 32022) et publications du nœud (docker port sans port).
    # FAUX_DOCKER_RESEAU_KO : connect échoue ; FAUX_DOCKER_RESEAU_EXISTE :
    # « already exists » (succès) ; FAUX_DOCKER_PORT : mapping SSH présent ;
    # FAUX_DOCKER_PORT_EXPOSE / _LOCAL : nœud publié sur 0.0.0.0 / 127.0.0.1.
    cat >"$BATS_TEST_TMPDIR/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
echo "docker $*" >>"$BATS_TEST_TMPDIR/docker.log"
case "$*" in
    *"network connect kind "*)
        if [ -n "${FAUX_DOCKER_RESEAU_EXISTE:-}" ]; then
            echo "Error response from daemon: endpoint with name $(hostname) already exists in network kind"
            exit 1
        fi
        if [ -n "${FAUX_DOCKER_RESEAU_KO:-}" ]; then
            echo "Error response from daemon: network kind not found"
            exit 1
        fi
        exit 0
        ;;
    *"port gitlab-control-plane 32022"*)
        if [ -n "${FAUX_DOCKER_PORT:-}" ]; then
            echo "0.0.0.0:2224 -> 32022/tcp"
            exit 0
        fi
        exit 1
        ;;
    *"port gitlab"*"control-plane"*)
        if [ -n "${FAUX_DOCKER_PORT_EXPOSE:-}" ]; then
            printf '80/tcp -> 0.0.0.0:8929\n32022/tcp -> 0.0.0.0:2224\n'
        elif [ -n "${FAUX_DOCKER_PORT_LOCAL:-}" ]; then
            printf '80/tcp -> 127.0.0.1:8929\n32022/tcp -> 127.0.0.1:2224\n'
        fi
        exit 0
        ;;
esac
exit 0
DOCKER
    # curl : API GitLab simulée ; FAUX_GROUPE_KO=1 fait échouer le groupe ;
    # FAUX_RUNNER_VERIFY_CODE : code HTTP rendu pour /api/v4/runners/verify ;
    # FAUX_RUNNER_INJOIGNABLE : la vérification du jeton est injoignable (exit 7)
    cat >"$BATS_TEST_TMPDIR/bin/curl" <<'CURL'
#!/usr/bin/env bash
echo "curl $*" | sed -e 's/token=[^ &]*/token=<masque>/g' -e 's/PRIVATE-TOKEN: [^ "]*/PRIVATE-TOKEN: <masque>/g' >>"$BATS_TEST_TMPDIR/curl.log"
[ -n "${FAUX_GITLAB_KO:-}" ] && exit 7
case "$*" in
    *"api/v4/runners/verify"*)
        if [ -n "${FAUX_RUNNER_INJOIGNABLE:-}" ]; then
            exit 7
        fi
        echo "${FAUX_RUNNER_VERIFY_CODE:-200}"
        ;;
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
    # gh : jamais connecté (git-identite, état devzone) : aucun appel réseau
    cat >"$BATS_TEST_TMPDIR/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "gh $*" >>"$BATS_TEST_TMPDIR/gh.log"
exit 1
GH
    # getent : hosts rend l'IPv6 de Docker Desktop, ahostsv4 l'IPv4 de l'hôte
    cat >"$BATS_TEST_TMPDIR/bin/getent" <<'GETENT'
#!/usr/bin/env bash
echo "getent $*" >>"$BATS_TEST_TMPDIR/getent.log"
case "$*" in
    "hosts host.docker.internal") echo "fdc4:f303:9324::254 host.docker.internal" ;;
    "ahostsv4 host.docker.internal") echo "192.168.65.254 STREAM host.docker.internal" ;;
    "hosts gitlab.localhost") echo "127.0.0.1 gitlab.localhost" ;;
esac
exit 0
GETENT
    # socat/setsid : relais TCP journalisé, sans processus réel
    cat >"$BATS_TEST_TMPDIR/bin/socat" <<'SOCAT'
#!/usr/bin/env bash
echo "socat $*" >>"$BATS_TEST_TMPDIR/socat.log"
exit 0
SOCAT
    cat >"$BATS_TEST_TMPDIR/bin/setsid" <<'SETSID'
#!/usr/bin/env bash
echo "setsid $*" >>"$BATS_TEST_TMPDIR/setsid.log"
exec "$@"
SETSID
    # kill : -0 laisse le test vivant, les autres signaux sont seulement journalisés
    cat >"$BATS_TEST_TMPDIR/bin/kill" <<'KILL'
#!/usr/bin/env bash
if [ "${1:-}" = "-0" ]; then
    builtin kill -0 "${2:-}" 2>/dev/null
    exit $?
fi
echo "kill $*" >>"$BATS_TEST_TMPDIR/kill.log"
exit 0
KILL
    cat >"$BATS_TEST_TMPDIR/bin/pgrep" <<'PGREP'
#!/usr/bin/env bash
echo "pgrep $*" >>"$BATS_TEST_TMPDIR/pgrep.log"
exit 1
PGREP
    chmod +x "$BATS_TEST_TMPDIR"/bin/*
    HELM_BIN="$(command -v helm)"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

attendre_journal() {
    local fichier="$1" motif="$2" i=0
    while [ "$i" -lt 50 ]; do
        if grep -q -- "$motif" "$fichier" 2>/dev/null; then
            return 0
        fi
        i=$((i + 1))
        sleep 0.1
    done
    echo "$fichier : ligne absente après 5 s : $motif" >&2
    return 1
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

@test "gitlab : cluster créé sans basculer le contexte, restauré ensuite" {
    mkdir -p "$HOME/.kube"
    printf 'current-context: docker-desktop\n' >"$HOME/.kube/config"
    cat >"$BATS_TEST_TMPDIR/bin/kind" <<'KIND'
#!/usr/bin/env bash
echo "kind $*" >>"$BATS_TEST_TMPDIR/kind.log"
case "$1 $2" in
    "get clusters") cat "$KIND_CLUSTERS" ;;
    "create cluster")
        nom=""
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --name) nom="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        echo "$nom" >>"$KIND_CLUSTERS"
        mkdir -p "$HOME/.kube"
        printf 'current-context: kind-%s\n' "$nom" >"$HOME/.kube/config"
        ;;
    "delete cluster") grep -vx "${4:-}" "$KIND_CLUSTERS" >"$KIND_CLUSTERS.tmp" || true; mv "$KIND_CLUSTERS.tmp" "$KIND_CLUSTERS" ;;
esac
KIND
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"$BATS_TEST_TMPDIR/kubectl.log"
fichier="$HOME/.kube/config"
mkdir -p "$HOME/.kube"
case "$*" in
    "config current-context") sed -n 's/^current-context:[[:space:]]*//p' "$fichier" 2>/dev/null | head -1 ;;
    "config use-context "*)
        nouveau="${3:-}"
        { grep -v '^current-context:' "$fichier" 2>/dev/null || true; printf 'current-context: %s\n' "$nouveau"; } >"$fichier.tmp"
        mv "$fichier.tmp" "$fichier"
        ;;
    "config unset current-context")
        { grep -v '^current-context:' "$fichier" 2>/dev/null || true; } >"$fichier.tmp"
        mv "$fichier.tmp" "$fichier"
        ;;
    *"get secret"*) echo "cGFzc3dvcmQxMjM=" ;;
    *"get pod"*) echo "gitlab-toolbox-1" ;;
    *"gitlab-rails runner"*) echo "jeton-root-secret" ;;
esac
exit 0
KUBE
    chmod +x "$BATS_TEST_TMPDIR/bin/kind" "$BATS_TEST_TMPDIR/bin/kubectl"
    run bash "$GITLAB" installer
    [ "$status" -eq 0 ] || false
    grep -q "kind create cluster --name gitlab" "$BATS_TEST_TMPDIR/kind.log" || false
    grep -qx 'kubectl config use-context docker-desktop' "$BATS_TEST_TMPDIR/kubectl.log" || false
    [ "$(sed -n 's/^current-context:[[:space:]]*//p' "$HOME/.kube/config")" = docker-desktop ] || false
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

@test "gitlab : kind.yaml limite les publications 8929 et 2224 à 127.0.0.1" {
    local kind_yaml="$BATS_TEST_DIRNAME/../../.devcontainer/gitlab/kind.yaml"
    [ "$(grep -c 'listenAddress: "127.0.0.1"' "$kind_yaml")" -eq 2 ]
    grep -A3 "containerPort: 80$" "$kind_yaml" | grep -q 'listenAddress: "127.0.0.1"' || false
    grep -A3 "containerPort: 32022$" "$kind_yaml" | grep -q 'listenAddress: "127.0.0.1"' || false
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

@test "gitlab : seed et désinstallation régénèrent .password" {
    run bash "$GITLAB" installer
    [ "$status" -eq 0 ]
    grep -q $'^gitlab\thttp://gitlab.localhost:8929\tdev\t' "$DEVZONE_RACINE/.password"
    grep -q $'^gitlab\thttp://gitlab.localhost:8929\troot\tpassword123$' "$DEVZONE_RACINE/.password"
    run bash "$GITLAB" desinstaller
    [ "$status" -eq 0 ]
    [ ! -e "$DEVZONE_RACINE/.password" ]
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

@test "gitlab : seed : runner-token présent et vérifié 200 → jeton gardé, pas de création" {
    mkdir -p "$SECRETS"
    printf 'jeton-runner-secret' >"$SECRETS/runner-token"
    export FAUX_RUNNER_VERIFY_CODE=200
    run bash "$GITLAB" seed
    [ "$status" -eq 0 ]
    [ "$(cat "$SECRETS/runner-token")" = "jeton-runner-secret" ]
    ! grep -q "api/v4/user/runners" "$BATS_TEST_TMPDIR/curl.log" || false
    [[ "$output" != *"jeton-runner-secret"* ]] || false
}

@test "gitlab : seed : runner-token présent et refusé 403 → jeton recréé, fichier écrasé" {
    mkdir -p "$SECRETS"
    printf 'ancien-jeton-runner' >"$SECRETS/runner-token"
    export FAUX_RUNNER_VERIFY_CODE=403
    run bash "$GITLAB" seed
    [ "$status" -eq 0 ]
    [[ "$output" == *"refusé : recréé"* ]] || false
    grep -q "api/v4/user/runners" "$BATS_TEST_TMPDIR/curl.log"
    [ "$(cat "$SECRETS/runner-token")" = "jeton-runner-secret" ]
}

@test "gitlab : seed : runner-token absent → jeton créé" {
    rm -f "$SECRETS/runner-token"
    run bash "$GITLAB" seed
    [ "$status" -eq 0 ]
    [ -f "$SECRETS/runner-token" ]
    grep -q "api/v4/user/runners" "$BATS_TEST_TMPDIR/curl.log"
}

@test "gitlab : seed : vérification du jeton de runner injoignable → arrêt du seed" {
    mkdir -p "$SECRETS"
    printf 'jeton-runner-secret' >"$SECRETS/runner-token"
    export FAUX_RUNNER_INJOIGNABLE=1
    run bash "$GITLAB" seed
    [ "$status" -ne 0 ]
    [[ "$output" == *"arrêt du seed"* ]] || false
}

@test "gitlab : seed : jeton de runner jamais affiché" {
    mkdir -p "$SECRETS"
    printf 'jeton-runner-secret' >"$SECRETS/runner-token"
    export FAUX_RUNNER_VERIFY_CODE=200
    run bash "$GITLAB" seed
    [ "$status" -eq 0 ]
    [[ "$output" != *"jeton-runner-secret"* ]] || false
    ! grep -q "jeton-runner-secret" "$BATS_TEST_TMPDIR/curl.log" || false
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

@test "gitlab : état signale un nœud publié sur 0.0.0.0" {
    echo gitlab >"$KIND_CLUSTERS"
    FAUX_DOCKER_PORT_EXPOSE=1 run bash "$GITLAB" etat
    [ "$status" -eq 0 ]
    [[ "$output" == *"⚠ GitLab exposé au réseau local"* ]] || false
    [[ "$output" == *"devzone desactiver gitlab puis devzone activer gitlab (données de test perdues)"* ]] || false
}

@test "gitlab : état sans avertissement pour un nœud publié sur 127.0.0.1" {
    echo gitlab >"$KIND_CLUSTERS"
    FAUX_DOCKER_PORT_LOCAL=1 run bash "$GITLAB" etat
    [ "$status" -eq 0 ]
    [[ "$output" != *"GitLab exposé au réseau local"* ]] || false
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

@test "gitlab : hote-poser pose gitlab.localhost une seule fois, localhost gardé" {
    run bash "$GITLAB" hote-poser
    [ "$status" -eq 0 ]
    run bash "$GITLAB" hote-poser
    [ "$status" -eq 0 ]
    [ "$(grep -c 'devzone:gitlab' "$DEVZONE_HOSTS")" -eq 1 ]
    grep -q '^127\.0\.0\.1 localhost$' "$DEVZONE_HOSTS"
    grep -q $'^127\.0\.0\.1\tgitlab\.localhost # devzone:gitlab$' "$DEVZONE_HOSTS"
}

@test "gitlab : hote-poser remplace une ligne IPv6 déjà posée par 127.0.0.1" {
    printf '127.0.0.1 localhost\nfdc4:f303:9324::254\tgitlab.localhost # devzone:gitlab\n' >"$DEVZONE_HOSTS"
    run bash "$GITLAB" hote-poser
    [ "$status" -eq 0 ]
    [ "$(grep -c 'devzone:gitlab' "$DEVZONE_HOSTS")" -eq 1 ]
    grep -q $'^127\.0\.0\.1\tgitlab\.localhost # devzone:gitlab$' "$DEVZONE_HOSTS"
    ! grep -q 'fdc4:f303' "$DEVZONE_HOSTS" || false
    grep -q '^127\.0\.0\.1 localhost$' "$DEVZONE_HOSTS"
}

@test "gitlab : relais vers le nœud kind après network connect" {
    run bash "$GITLAB" relais-lancer
    [ "$status" -eq 0 ]
    grep -qF "docker network connect kind $(hostname)" "$BATS_TEST_TMPDIR/docker.log"
    attendre_journal "$BATS_TEST_TMPDIR/socat.log" 'TCP-LISTEN:8929,bind=127.0.0.1,fork,reuseaddr TCP:gitlab-control-plane:80'
    grep -q 'TCP-LISTEN:8929,bind=127.0.0.1,fork,reuseaddr TCP:gitlab-control-plane:80' "$BATS_TEST_TMPDIR/socat.log"
    attendre_journal "$BATS_TEST_TMPDIR/socat.log" 'TCP-LISTEN:2224,bind=127.0.0.1,fork,reuseaddr TCP:gitlab-control-plane:32022'
    grep -q 'TCP-LISTEN:2224,bind=127.0.0.1,fork,reuseaddr TCP:gitlab-control-plane:32022' "$BATS_TEST_TMPDIR/socat.log"
    [ "$(cat "$DEVZONE_RACINE/workspace/.gitlab-8929/relais.cible")" = "TCP:gitlab-control-plane:80" ]
    [ "$(cat "$DEVZONE_RACINE/workspace/.gitlab-2224/relais.cible")" = "TCP:gitlab-control-plane:32022" ]
}

@test "gitlab : network connect déjà existant → relais vers le nœud" {
    FAUX_DOCKER_RESEAU_EXISTE=1 run bash "$GITLAB" relais-lancer
    [ "$status" -eq 0 ]
    [[ "$output" != *"repli"* ]] || false
    attendre_journal "$BATS_TEST_TMPDIR/socat.log" 'TCP:gitlab-control-plane:80'
    attendre_journal "$BATS_TEST_TMPDIR/socat.log" 'TCP:gitlab-control-plane:32022'
}

@test "gitlab : network connect en échec → repli sur l'IPv4 de l'hôte, message stderr" {
    FAUX_DOCKER_RESEAU_KO=1 run bash "$GITLAB" relais-lancer
    [ "$status" -eq 0 ]
    [[ "$output" == *"repli sur l'IPv4 de host.docker.internal"* ]] || false
    attendre_journal "$BATS_TEST_TMPDIR/socat.log" 'TCP-LISTEN:8929,bind=127.0.0.1,fork,reuseaddr TCP:192.168.65.254:8929'
    grep -q 'TCP-LISTEN:8929,bind=127.0.0.1,fork,reuseaddr TCP:192.168.65.254:8929' "$BATS_TEST_TMPDIR/socat.log"
    attendre_journal "$BATS_TEST_TMPDIR/socat.log" 'TCP-LISTEN:2224,bind=127.0.0.1,fork,reuseaddr TCP:192.168.65.254:2224'
    grep -q 'TCP-LISTEN:2224,bind=127.0.0.1,fork,reuseaddr TCP:192.168.65.254:2224' "$BATS_TEST_TMPDIR/socat.log"
    ! grep -q 'fdc4:f303' "$BATS_TEST_TMPDIR/socat.log" || false
    [ "$(cat "$DEVZONE_RACINE/workspace/.gitlab-8929/relais.cible")" = "TCP:192.168.65.254:8929" ]
}

@test "gitlab : cible changée → relais relancé vers la nouvelle cible" {
    # Premier lancement : repli sur l'IPv4 de l'hôte (ancienne cible)
    FAUX_DOCKER_RESEAU_KO=1 run bash "$GITLAB" relais-lancer
    [ "$status" -eq 0 ]
    [ "$(cat "$DEVZONE_RACINE/workspace/.gitlab-8929/relais.cible")" = "TCP:192.168.65.254:8929" ]
    attendre_journal "$BATS_TEST_TMPDIR/socat.log" 'TCP-LISTEN:8929,bind=127.0.0.1,fork,reuseaddr TCP:192.168.65.254:8929'
    # Réseau kind rejoignable : la cible change, le relais est relancé
    run bash "$GITLAB" relais-lancer
    [ "$status" -eq 0 ]
    [ "$(cat "$DEVZONE_RACINE/workspace/.gitlab-8929/relais.cible")" = "TCP:gitlab-control-plane:80" ]
    [ "$(cat "$DEVZONE_RACINE/workspace/.gitlab-2224/relais.cible")" = "TCP:gitlab-control-plane:32022" ]
    attendre_journal "$BATS_TEST_TMPDIR/socat.log" 'TCP-LISTEN:8929,bind=127.0.0.1,fork,reuseaddr TCP:gitlab-control-plane:80'
    attendre_journal "$BATS_TEST_TMPDIR/socat.log" 'TCP-LISTEN:2224,bind=127.0.0.1,fork,reuseaddr TCP:gitlab-control-plane:32022'
    grep -q 'TCP-LISTEN:8929,bind=127.0.0.1,fork,reuseaddr TCP:192.168.65.254:8929' "$BATS_TEST_TMPDIR/socat.log"
}

@test "gitlab : desinstaller arrête les relais 8929 et 2224" {
    local pid
    { true; } &
    pid=$!
    wait "$pid" || true
    mkdir -p "$DEVZONE_RACINE/workspace/.gitlab-8929" "$DEVZONE_RACINE/workspace/.gitlab-2224"
    echo "$pid" >"$DEVZONE_RACINE/workspace/.gitlab-8929/relais.pid"
    echo "$pid" >"$DEVZONE_RACINE/workspace/.gitlab-2224/relais.pid"
    run bash "$GITLAB" desinstaller
    [ "$status" -eq 0 ]
    grep -q "pgrep -P $pid" "$BATS_TEST_TMPDIR/pgrep.log"
    [ ! -e "$DEVZONE_RACINE/workspace/.gitlab-8929" ]
    [ ! -e "$DEVZONE_RACINE/workspace/.gitlab-2224" ]
}

@test "gitlab : hote-retirer retire la ligne, garde localhost ; sans ligne → rien, code 0" {
    run bash "$GITLAB" hote-poser
    [ "$status" -eq 0 ]
    run bash "$GITLAB" hote-retirer
    [ "$status" -eq 0 ]
    ! grep -q 'devzone:gitlab' "$DEVZONE_HOSTS" || false
    grep -q '^127\.0\.0\.1 localhost$' "$DEVZONE_HOSTS"
    # Sans ligne à retirer : fichier inchangé, code 0
    local avant
    avant="$(cat "$DEVZONE_HOSTS")"
    run bash "$GITLAB" hote-retirer
    [ "$status" -eq 0 ]
    [ "$(cat "$DEVZONE_HOSTS")" = "$avant" ]
}

@test "gitlab : hote-poser sans droits ni sudo utilisable → avertissement, code 0" {
    chmod 444 "$DEVZONE_HOSTS"
    cat >"$BATS_TEST_TMPDIR/bin/sudo" <<'SUDO'
#!/usr/bin/env bash
echo "sudo $*" >>"$BATS_TEST_TMPDIR/sudo.log"
exit 1
SUDO
    chmod +x "$BATS_TEST_TMPDIR/bin/sudo"
    run bash "$GITLAB" hote-poser
    [ "$status" -eq 0 ]
    [[ "$output" == *"nom gitlab.localhost non posé"* ]] || false
    ! grep -q 'devzone:gitlab' "$DEVZONE_HOSTS" || false
    # Relance : même échec, même code 0 (ne casse jamais l'installation)
    run bash "$GITLAB" hote-poser
    [ "$status" -eq 0 ]
    [[ "$output" == *"nom gitlab.localhost non posé"* ]] || false
}

@test "gitlab : installer pose la ligne, desinstaller la retire" {
    run bash "$GITLAB" installer
    [ "$status" -eq 0 ]
    grep -q 'devzone:gitlab' "$DEVZONE_HOSTS"
    run bash "$GITLAB" desinstaller
    [ "$status" -eq 0 ]
    ! grep -q 'devzone:gitlab' "$DEVZONE_HOSTS" || false
    grep -q '^127\.0\.0\.1 localhost$' "$DEVZONE_HOSTS"
}

@test "devzone appliquer : gitlab actif, prêt → ligne gitlab.localhost posée" {
    printf 'gitlab=on\n' >"$DEVZONE_ETAT"
    echo "gitlab" >"$KIND_CLUSTERS"
    mkdir -p "$SECRETS" && echo jeton >"$SECRETS/root-token"
    FAUX_RUNNERS='[{"id":1}]' run bash "$DEVZONE" appliquer
    [ "$status" -eq 0 ]
    [[ "$output" == *"déjà actif, rien à faire"* ]] || false
    grep -q 'devzone:gitlab' "$DEVZONE_HOSTS"
}

marque_reelle() {
    stat -c %Y /tmp/devzone-relais-docker.echec 2>/dev/null ||
        stat -f %m /tmp/devzone-relais-docker.echec 2>/dev/null ||
        echo absente
}

@test "demarrage : gitlab actif → ligne posée, inactif → rien" {
    # Isolation (#346) : le relais Docker tourne sous $BATS_TEST_TMPDIR, la
    # marque réelle du poste n'est jamais touchée (inchangée, pas absente :
    # elle peut exister si le relais du poste est réellement en échec)
    [[ "$DEVZONE_RELAIS_MARQUE" == "$BATS_TEST_TMPDIR"/* ]] || false
    local avant
    avant="$(marque_reelle)"
    # Module inactif : rien n'est posé
    printf 'gitlab=off\n' >"$DEVZONE_ETAT"
    run bash "$DEMARRAGE"
    [ "$status" -eq 0 ]
    ! grep -q 'devzone:gitlab' "$DEVZONE_HOSTS" || false
    # Module actif : le nom est posé au démarrage
    printf 'gitlab=on\n' >"$DEVZONE_ETAT"
    run bash "$DEMARRAGE"
    [ "$status" -eq 0 ]
    grep -q 'devzone:gitlab' "$DEVZONE_HOSTS"
    grep -q $'^127\.0\.0\.1\tgitlab\.localhost # devzone:gitlab$' "$DEVZONE_HOSTS"
    attendre_journal "$BATS_TEST_TMPDIR/socat.log" 'TCP-LISTEN:8929,bind=127.0.0.1'
    grep -q 'TCP-LISTEN:8929,bind=127.0.0.1' "$BATS_TEST_TMPDIR/socat.log"
    attendre_journal "$BATS_TEST_TMPDIR/socat.log" 'TCP-LISTEN:2224,bind=127.0.0.1'
    grep -q 'TCP-LISTEN:2224,bind=127.0.0.1' "$BATS_TEST_TMPDIR/socat.log"
    # Isolation (#346) : la marque réelle du poste est inchangée après le
    # démarrage (relevée avant le premier lancement de demarrage.sh)
    [[ "$DEVZONE_RELAIS_MARQUE" == "$BATS_TEST_TMPDIR"/* ]] || false
    [ "$(marque_reelle)" = "$avant" ]
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
