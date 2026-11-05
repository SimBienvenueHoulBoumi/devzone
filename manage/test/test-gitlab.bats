#!/usr/bin/env bats
# devzone test-gitlab (#263) : essai de bout en bout du module gitlab et de la
# plateforme. Faux kind, kubectl, curl, git, ssh-keygen, glab, gh, getent et
# devzone dans le PATH : aucun cluster, aucun réseau, aucun vrai GitLab.
# Chaque faux binaire journalise ses arguments dans $BATS_TEST_TMPDIR/<outil>.log.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../../.devcontainer/gitlab/test-gitlab.sh"
    export HOME="$BATS_TEST_TMPDIR/home"
    export DEVZONE_RACINE="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_ETAT="$BATS_TEST_TMPDIR/modules"
    export DEVZONE_HOSTS="$BATS_TEST_TMPDIR/hosts"
    export KIND_CLUSTERS="$BATS_TEST_TMPDIR/clusters"
    export GITLAB_TEST_PIPELINE=2
    export GITLAB_TEST_INTERVALLE=0
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"
    export DEVZONE_INSTANCE=mon-devzone
    export INSTANCE_TEST=-mon-devzone
    export DEVZONE_TEST_DEVZONE="$BATS_TEST_TMPDIR/bin/devzone"
    mkdir -p "$HOME/.local/bin" "$DEVZONE_RACINE/workspace/.gitlab" \
        "$BATS_TEST_TMPDIR/bin" "$TMPDIR"
    printf 'jeton-root-secret' >"$DEVZONE_RACINE/workspace/.gitlab/root-token"
    # Relais 8929/2224 actifs : PID vivant (celui du test) dans leur dossier
    for port in 8929 2224; do
        mkdir -p "$DEVZONE_RACINE/workspace/.gitlab-$port"
        echo $$ >"$DEVZONE_RACINE/workspace/.gitlab-$port/relais.pid"
    done
    printf 'gitlab%s\n' "$INSTANCE_TEST" >"$KIND_CLUSTERS"
    printf 'kind-gitlab%s\nkind-dev\n' "$INSTANCE_TEST" >"$BATS_TEST_TMPDIR/contextes"
    printf '127.0.0.1 localhost\n127.0.0.1\tgitlab.localhost # devzone:gitlab\n' >"$DEVZONE_HOSTS"
    : >"$DEVZONE_ETAT"
    touch "$BATS_TEST_TMPDIR/module_actif"

    # devzone : doublure des commandes utilisées par test-gitlab.sh
    cat >"$BATS_TEST_TMPDIR/bin/devzone" <<'DEVZONE'
#!/usr/bin/env bash
echo "devzone $*" >>"$BATS_TEST_TMPDIR/devzone.log"
case "$1 $2" in
    "actif gitlab")
        [ -f "$BATS_TEST_TMPDIR/module_actif" ]
        exit $?
        ;;
    "activer gitlab")
        [ -n "${FAUX_ACTIVER_KO:-}" ] && exit 1
        touch "$BATS_TEST_TMPDIR/module_actif"
        grep -qx "gitlab$INSTANCE_TEST" "$KIND_CLUSTERS" 2>/dev/null ||
            echo "gitlab$INSTANCE_TEST" >>"$KIND_CLUSTERS"
        mkdir -p "$DEVZONE_RACINE/workspace/.gitlab"
        printf 'jeton-root-secret' >"$DEVZONE_RACINE/workspace/.gitlab/root-token"
        ;;
    "desactiver gitlab")
        [ -n "${FAUX_DESACTIVER_KO:-}" ] && exit 1
        rm -f "$BATS_TEST_TMPDIR/module_actif"
        if [ "${FAUX_DESACTIVER_LAISSE:-}" != cluster ]; then
            grep -vx "gitlab$INSTANCE_TEST" "$KIND_CLUSTERS" >"$KIND_CLUSTERS.tmp" 2>/dev/null || true
            mv "$KIND_CLUSTERS.tmp" "$KIND_CLUSTERS"
        fi
        if [ "${FAUX_DESACTIVER_LAISSE:-}" != contexte ]; then
            grep -vx "kind-gitlab$INSTANCE_TEST" "$BATS_TEST_TMPDIR/contextes" >"$BATS_TEST_TMPDIR/contextes.tmp" 2>/dev/null || true
            mv "$BATS_TEST_TMPDIR/contextes.tmp" "$BATS_TEST_TMPDIR/contextes"
        fi
        if [ "${FAUX_DESACTIVER_LAISSE:-}" != secrets ]; then
            rm -rf "$DEVZONE_RACINE/workspace/.gitlab"
        fi
        if [ "${FAUX_DESACTIVER_LAISSE:-}" != hosts ]; then
            grep -v 'devzone:gitlab' "$DEVZONE_HOSTS" >"$DEVZONE_HOSTS.tmp" 2>/dev/null || true
            mv "$DEVZONE_HOSTS.tmp" "$DEVZONE_HOSTS"
        fi
        ;;
    "plateforme gitlab")
        [ -n "${FAUX_PLATEFORME_KO:-}" ] && exit 1
        mkdir -p "$HOME/.local/bin" "$HOME/.config/glab-cli"
        cp "$BATS_TEST_TMPDIR/bin/glab" "$HOME/.local/bin/glab"
        chmod +x "$HOME/.local/bin/glab"
        grep -vE '^(plateforme|gitlab_url)=' "$DEVZONE_ETAT" >"$DEVZONE_ETAT.tmp" 2>/dev/null || true
        mv "$DEVZONE_ETAT.tmp" "$DEVZONE_ETAT"
        printf 'plateforme=gitlab\ngitlab_url=http://gitlab.localhost:8929\n' >>"$DEVZONE_ETAT"
        ;;
    "plateforme github")
        rm -f "$HOME/.local/bin/glab"
        rm -rf "$HOME/.config/glab-cli"
        grep -vE '^(plateforme|gitlab_url)=' "$DEVZONE_ETAT" >"$DEVZONE_ETAT.tmp" 2>/dev/null || true
        mv "$DEVZONE_ETAT.tmp" "$DEVZONE_ETAT"
        ;;
    "plateforme "*)
        echo "devzone : plateforme gitlab"
        ;;
    *)
        echo "devzone : commande inconnue : $*" >&2
        exit 1
        ;;
esac
exit 0
DEVZONE

    # kind : clusters tenus dans $KIND_CLUSTERS
    cat >"$BATS_TEST_TMPDIR/bin/kind" <<'KIND'
#!/usr/bin/env bash
echo "kind $*" >>"$BATS_TEST_TMPDIR/kind.log"
case "$1 $2" in
    "get clusters") cat "$KIND_CLUSTERS" ;;
    "delete cluster") grep -vx "${4:-}" "$KIND_CLUSTERS" >"$KIND_CLUSTERS.tmp" || true; mv "$KIND_CLUSTERS.tmp" "$KIND_CLUSTERS" ;;
esac
KIND

    # kubectl : contextes tenus dans un fichier
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"$BATS_TEST_TMPDIR/kubectl.log"
case "$*" in
    *"config get-contexts"*) cat "$BATS_TEST_TMPDIR/contextes" 2>/dev/null || true ;;
    *"config current-context"*) echo "${FAUX_CONTEXTE:-kind-dev}" ;;
esac
exit 0
KUBE

    # docker : conteneurs de l'instance sur le Docker de l'hôte
    cat >"$BATS_TEST_TMPDIR/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
echo "docker $*" >>"$BATS_TEST_TMPDIR/docker.log"
case "$*" in
    "ps -aq"*) [ -z "${FAUX_CONTENEURS_ETIQUETES:-}" ] || echo "$FAUX_CONTENEURS_ETIQUETES" ;;
esac
exit 0
DOCKER

    # curl : API GitLab simulée (pipeline, clés, état du module)
    export CURL_SETUP="$BATS_TEST_TMPDIR/curl_setup"
    mkdir -p "$CURL_SETUP"
    printf '0' >"$CURL_SETUP/pipeline_count"
    cat >"$BATS_TEST_TMPDIR/bin/curl" <<'CURL'
#!/usr/bin/env bash
echo "curl $*" >>"$BATS_TEST_TMPDIR/curl.log"
[ -n "${FAUX_GITLAB_KO:-}" ] && exit 7
methode=GET
url=""
while [ $# -gt 0 ]; do
    case "$1" in
        --request) methode="$2"; shift 2 ;;
        --header | --data | --data-urlencode) shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
pipeline_file="$CURL_SETUP/pipeline_count"
    case "$url" in
    *"/api/v4/projects/devzone%2Fdemo/pipeline")
        [ -n "${FAUX_PIPELINE_CREATION_KO:-}" ] && exit 22
        printf '{"id":42,"web_url":"http://gitlab.localhost:8929/devzone/demo/-/pipelines/42"}\n'
        ;;
    *"/api/v4/projects/devzone%2Fdemo/pipelines/42")
        if [ -n "${FAUX_PIPELINE_ETAT:-}" ]; then
            case "${FAUX_PIPELINE_ETAT}" in
                success) printf '{"status":"success"}\n' ;;
                failed) printf '{"status":"failed"}\n' ;;
                *) printf '{"status":"running"}\n' ;;
            esac
        else
            # Par défaut : transition running → success au prochain appel
            pipeline_count="$(cat "$pipeline_file" 2>/dev/null || echo 0)"
            if [ "$pipeline_count" -eq 0 ]; then
                printf '{"status":"running"}\n'
            else
                printf '{"status":"success"}\n'
            fi
            printf '%d' $((pipeline_count + 1)) >"$pipeline_file"
        fi
        ;;
    *"/api/v4/user/keys/7") exit 0 ;;
    *"/api/v4/user/keys")
        [ -n "${FAUX_CLE_KO:-}" ] && exit 22
        printf '{"id":7}\n'
        ;;
    *"/api/v4/runners/all"*)
        if [ -n "${FAUX_RUNNERS:-}" ]; then
            printf '%s\n' "$FAUX_RUNNERS"
        else
            printf '%s\n' '[{"id":1}]'
        fi
        ;;
    *"/-/readiness"* | *"/users/sign_in"*) exit 0 ;;
    *"/api/v4/projects/devzone%2Fdemo/repository"*) exit 0 ;;
esac
exit 0
CURL

    # git : clone simulé ; la suite repowarden est un vrai fichier bats
    cat >"$BATS_TEST_TMPDIR/bin/git" <<'GIT'
#!/usr/bin/env bash
echo "git $*" >>"$BATS_TEST_TMPDIR/git.log"
case "$*" in
    "rev-parse HEAD") echo "0123456789abcdef"; exit 0 ;;
esac
clone=0
for a in "$@"; do
    [ "$a" = clone ] && clone=1
done
if [ "$clone" = 1 ]; then
    for a in "$@"; do cible="$a"; done
    case "$*" in
        *repowarden*)
            [ -n "${FAUX_REPOWARDEN_CLONE_KO:-}" ] && exit 1
            if [ -z "${FAUX_REPOWARDEN_SANS_TEST:-}" ]; then
                mkdir -p "$cible/test/gitlab"
                : >"$cible/test/gitlab/forge.bats"
            else
                mkdir -p "$cible"
            fi
            ;;
        *"ssh://git@"*)
            [ "${FAUX_CLONE_KO:-}" = ssh ] && exit 1
            mkdir -p "$cible/.git"
            : >"$cible/.git/config"
            ;;
        *"http://"* | *"https://"*)
            [ "${FAUX_CLONE_KO:-}" = http ] && exit 1
            mkdir -p "$cible/.git"
            if [ -n "${FAUX_JETON_DANS_CONFIG:-}" ]; then
                printf 'extraheader = PRIVATE-TOKEN: jeton-root-secret\n' >"$cible/.git/config"
            else
                : >"$cible/.git/config"
            fi
            ;;
        *)
            mkdir -p "$cible/.git"
            : >"$cible/.git/config"
            ;;
    esac
fi
exit 0
GIT

    # ssh-keygen : clé jetable factice
    cat >"$BATS_TEST_TMPDIR/bin/ssh-keygen" <<'SSHKEYGEN'
#!/usr/bin/env bash
echo "ssh-keygen $*" >>"$BATS_TEST_TMPDIR/ssh-keygen.log"
[ -n "${FAUX_SSH_KEYGEN_KO:-}" ] && exit 1
f=""
while [ $# -gt 0 ]; do
    case "$1" in
        -f) f="$2"; shift 2 ;;
        *) shift ;;
    esac
done
[ -n "$f" ] || exit 1
printf 'cle-privee\n' >"$f"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI test@devzone\n' >"$f.pub"
SSHKEYGEN

    # glab : clone simulé
    cat >"$BATS_TEST_TMPDIR/bin/glab" <<'GLAB'
#!/usr/bin/env bash
echo "glab $*" >>"$BATS_TEST_TMPDIR/glab.log"
case "$*" in
    "repo clone"*)
        [ -n "${FAUX_GLAB_CLONE_KO:-}" ] && exit 1
        for a in "$@"; do cible="$a"; done
        mkdir -p "$cible/.git"
        : >"$cible/.git/config"
        ;;
    "--version") echo "glab 1.0.0" ;;
esac
exit 0
GLAB

    # bats : la suite d'intégration repowarden, simulée ; en échec, elle
    # affiche le jeton reçu pour vérifier qu'il est masqué dans le journal
    cat >"$BATS_TEST_TMPDIR/bin/bats" <<'BATS'
#!/usr/bin/env bash
echo "bats $*" >>"$BATS_TEST_TMPDIR/bats.log"
if [ -n "${FAUX_SUITE_KO:-}" ]; then
    echo "échec de la suite avec le jeton ${REPOWARDEN_IT_GITLAB_TOKEN:-}"
    exit 1
fi
exit 0
BATS

    # gh : connexion et API simulées
    cat >"$BATS_TEST_TMPDIR/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "gh $*" >>"$BATS_TEST_TMPDIR/gh.log"
case "$*" in
    "auth status"*) exit "${FAUX_GH_AUTH_KO:-0}" ;;
    "repo view"*) echo "SimBienvenueHoulBoumi/devzone" ;;
esac
exit 0
GH

    # getent : gitlab.localhost vers 127.0.0.1 (relais), hôte en IPv6 par
    # « hosts » mais IPv4 par « ahostsv4 » (comme Docker Desktop, #320)
    cat >"$BATS_TEST_TMPDIR/bin/getent" <<'GETENT'
#!/usr/bin/env bash
echo "getent $*" >>"$BATS_TEST_TMPDIR/getent.log"
[ -n "${FAUX_GETENT_KO:-}" ] && exit 2
case "$*" in
    "hosts gitlab.localhost")
        if [ -n "${FAUX_GETENT_AUTRE:-}" ]; then
            echo "172.17.0.1 gitlab.localhost"
        else
            echo "127.0.0.1 gitlab.localhost"
        fi
        ;;
    "ahostsv4 host.docker.internal")
        echo "172.17.0.1 STREAM host.docker.internal"
        ;;
    "hosts host.docker.internal")
        echo "fdc4:f303:9324::254 host.docker.internal"
        ;;
esac
exit 0
GETENT

    chmod +x "$BATS_TEST_TMPDIR"/bin/*
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "test-gitlab : tout vert, résumé, code 0, clé retirée, jeton jamais affiché" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"✔ 1. module"* ]] || false
    [[ "$output" == *"✔ 2. état"* ]] || false
    [[ "$output" == *"✔ 3. nom d'hôte"* ]] || false
    [[ "$output" == *"✔ 4. pipeline"* ]] || false
    [[ "$output" == *"✔ 5. clones HTTP et SSH"* ]] || false
    [[ "$output" == *"✔ 6. plateforme"* ]] || false
    [[ "$output" == *"✔ 7. intégration repowarden"* ]] || false
    [[ "$output" == *"devzone test-gitlab : résumé"* ]] || false
    [[ "$output" != *"jeton-root-secret"* ]] || false
    grep -q "DELETE" "$BATS_TEST_TMPDIR/curl.log" || false
    grep -q "/user/keys/7" "$BATS_TEST_TMPDIR/curl.log" || false
    [ ! -e "$HOME/.local/bin/glab" ]
    ! grep -q '^plateforme=' "$DEVZONE_ETAT" || false
}

@test "test-gitlab : étape 1 en échec → ✖ avec la raison, code non nul" {
    rm -f "$BATS_TEST_TMPDIR/module_actif"
    export FAUX_ACTIVER_KO=1
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ 1. module"* ]] || false
    [[ "$output" == *"devzone activer gitlab a échoué"* ]] || false
}

@test "test-gitlab : étape 2 en échec (runner hors ligne) → ✖ avec la raison" {
    export FAUX_RUNNERS='[]'
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ 2. état"* ]] || false
    [[ "$output" == *"runner hors ligne"* ]] || false
}

@test "test-gitlab : étape 3 en échec (nom non résolu) → ✖ avec la raison" {
    export FAUX_GETENT_KO=1
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ 3. nom d'hôte"* ]] || false
    [[ "$output" == *"gitlab.localhost non résolu"* ]] || false
}

@test "test-gitlab : étape 3 en échec (nom vers une autre adresse) → ✖, 127.0.0.1 attendu" {
    export FAUX_GETENT_AUTRE=1
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ 3. nom d'hôte"* ]] || false
    [[ "$output" == *"résolu vers 172.17.0.1, attendu 127.0.0.1"* ]] || false
}

@test "test-gitlab : étape 3 en échec (relais 2224 arrêté) → ✖ avec la raison" {
    rm -f "$DEVZONE_RACINE/workspace/.gitlab-2224/relais.pid"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ 3. nom d'hôte"* ]] || false
    [[ "$output" == *"relais gitlab arrêté sur 2224"* ]] || false
}

@test "test-gitlab : étape 3 en échec (aucun relais) → ✖ avec les deux ports" {
    rm -f "$DEVZONE_RACINE/workspace/.gitlab-8929/relais.pid"
    rm -f "$DEVZONE_RACINE/workspace/.gitlab-2224/relais.pid"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ 3. nom d'hôte"* ]] || false
    [[ "$output" == *"relais gitlab arrêté sur 8929 2224"* ]] || false
}

@test "test-gitlab : étape 4, création du pipeline impossible → ✖ avec la raison" {
    export FAUX_PIPELINE_CREATION_KO=1
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ 4. pipeline"* ]] || false
    [[ "$output" == *"création du pipeline"* ]] || false
}

@test "test-gitlab : étape 4, pipeline en échec → ✖ avec l'URL du pipeline" {
    export FAUX_PIPELINE_ETAT=failed
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ 4. pipeline"* ]] || false
    [[ "$output" == *"pipeline failed"* ]] || false
    [[ "$output" == *"/devzone/demo/-/pipelines/42"* ]] || false
}

@test "test-gitlab : étape 4, délai du pipeline dépassé → ✖ avec la raison" {
    export FAUX_PIPELINE_ETAT=running
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ 4. pipeline"* ]] || false
    [[ "$output" == *"délai 2 s dépassé"* ]] || false
}

@test "test-gitlab : étape 4, pipeline running puis success" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"✔ 4. pipeline"* ]] || false
}

@test "test-gitlab : étape 5, clone HTTP par assistant d'identifiants, jeton absent des arguments" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q 'credential.helper=!f()' "$BATS_TEST_TMPDIR/git.log" || false
    grep -q 'username=oauth2' "$BATS_TEST_TMPDIR/git.log" || false
    ! grep -q 'jeton-root-secret' "$BATS_TEST_TMPDIR/git.log" || false
    # Le script refuse un clone dont .git/config contient le jeton : le
    # succès de ce test prouve aussi que la doublure ne l'y a pas écrit.
}

@test "test-gitlab : étape 5, dépôt de la clé SSH impossible → ✖ avec la raison" {
    export FAUX_CLE_KO=1
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ 5. clones HTTP et SSH"* ]] || false
    [[ "$output" == *"dépôt de la clé SSH"* ]] || false
}

@test "test-gitlab : étape 5, clone SSH impossible → ✖ avec la raison" {
    export FAUX_CLONE_KO=ssh
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ 5. clones HTTP et SSH"* ]] || false
    [[ "$output" == *"clone SSH"* ]] || false
}

@test "test-gitlab : étape 5, clone HTTP impossible → ✖, clé retirée, jeton absent" {
    export FAUX_CLONE_KO=http
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ 5. clones HTTP et SSH"* ]] || false
    [[ "$output" == *"clone HTTP"* ]] || false
    [[ "$output" != *"jeton-root-secret"* ]] || false
    grep -q "DELETE" "$BATS_TEST_TMPDIR/curl.log" || false
    grep -q "/user/keys/7" "$BATS_TEST_TMPDIR/curl.log" || false
}

@test "test-gitlab : étape 5, jeton écrit dans .git/config du clone → ✖" {
    export FAUX_JETON_DANS_CONFIG=1
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ 5. clones HTTP et SSH"* ]] || false
    [[ "$output" == *"écrit dans .git/config"* ]] || false
    [[ "$output" != *"jeton-root-secret"* ]] || false
}

@test "test-gitlab : étape 6, changement de plateforme impossible → ✖" {
    export FAUX_PLATEFORME_KO=1
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ 6. plateforme"* ]] || false
    [[ "$output" == *"devzone plateforme gitlab a échoué"* ]] || false
}

@test "test-gitlab : étape 6, glab clone impossible → ✖, plateforme d'avant restaurée" {
    export FAUX_GLAB_CLONE_KO=1
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ 6. plateforme"* ]] || false
    [[ "$output" == *"glab repo clone devzone/demo a échoué"* ]] || false
    [ ! -e "$HOME/.local/bin/glab" ]
    [ ! -e "$HOME/.config/glab-cli" ]
    ! grep -q '^plateforme=' "$DEVZONE_ETAT" || false
}

@test "test-gitlab : étape 7, clone de repowarden impossible → ✖" {
    export FAUX_REPOWARDEN_CLONE_KO=1
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ 7. intégration repowarden"* ]] || false
    [[ "$output" == *"clone de repowarden"* ]] || false
}

@test "test-gitlab : étape 7, suite test/gitlab en échec → ✖" {
    export FAUX_SUITE_KO=1
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ 7. intégration repowarden"* ]] || false
    [[ "$output" == *"suite test/gitlab a échoué"* ]] || false
}

@test "test-gitlab : étape 7, journal conservé avec le jeton masqué" {
    export FAUX_SUITE_KO=1
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"devzone-test-gitlab-repowarden.log"* ]] || false
    [ -f "$TMPDIR/devzone-test-gitlab-repowarden.log" ]
    grep -q 'TOKEN_MASQUE' "$TMPDIR/devzone-test-gitlab-repowarden.log" || false
    ! grep -q 'jeton-root-secret' "$TMPDIR/devzone-test-gitlab-repowarden.log" || false
}

@test "test-gitlab : étape 7, test/gitlab absent à la réf → sauté, code 0" {
    export FAUX_REPOWARDEN_SANS_TEST=1
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sauté : test/gitlab absent à la réf. develop"* ]] || false
}

@test "test-gitlab : --complet désactive, contrôle qu'il ne reste rien, puis réinstalle" {
    run bash "$SCRIPT" --complet
    [ "$status" -eq 0 ]
    [[ "$output" == *"✔ 8. complet : désactivation"* ]] || false
    grep -q "devzone desactiver gitlab" "$BATS_TEST_TMPDIR/devzone.log" || false
    grep -q "label=devzone.instance=mon-devzone" "$BATS_TEST_TMPDIR/docker.log" || false
    grep -q "label=io.x-k8s.kind.cluster=gitlab-mon-devzone" "$BATS_TEST_TMPDIR/docker.log" || false
    [ -f "$BATS_TEST_TMPDIR/module_actif" ]
}

@test "test-gitlab : --complet, un reste (cluster de l'instance) → ✖ avec la raison" {
    export FAUX_DESACTIVER_LAISSE=cluster
    run bash "$SCRIPT" --complet
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ 8. complet : désactivation"* ]] || false
    [[ "$output" == *"cluster kind gitlab-mon-devzone"* ]] || false
}

@test "test-gitlab : --complet, un conteneur étiqueté de l'instance reste → ✖" {
    export FAUX_CONTENEURS_ETIQUETES=abc123
    run bash "$SCRIPT" --complet
    [ "$status" -ne 0 ]
    [[ "$output" == *"✖ 8. complet : désactivation"* ]] || false
    [[ "$output" == *"conteneur(s) étiqueté(s) devzone.instance=mon-devzone"* ]] || false
    grep -q "label=devzone.instance=mon-devzone" "$BATS_TEST_TMPDIR/docker.log" || false
}

@test "test-gitlab : --statut publie gitlab-integration sur HEAD par gh api" {
    run bash "$SCRIPT" --statut
    [ "$status" -eq 0 ]
    grep -q "gh api -X POST repos/SimBienvenueHoulBoumi/devzone/statuses/0123456789abcdef" "$BATS_TEST_TMPDIR/gh.log" || false
    grep -q "context=gitlab-integration" "$BATS_TEST_TMPDIR/gh.log" || false
    grep -q "state=success" "$BATS_TEST_TMPDIR/gh.log" || false
}

@test "test-gitlab : --statut en échec publie failure, code non nul" {
    export FAUX_CLONE_KO=http
    run bash "$SCRIPT" --statut
    [ "$status" -ne 0 ]
    grep -q "context=gitlab-integration" "$BATS_TEST_TMPDIR/gh.log" || false
    grep -q "state=failure" "$BATS_TEST_TMPDIR/gh.log" || false
}

@test "test-gitlab : --statut sans gh connecté → refus clair, code non nul" {
    export FAUX_GH_AUTH_KO=1
    run bash "$SCRIPT" --statut
    [ "$status" -ne 0 ]
    [[ "$output" == *"gh non connecté"* ]] || false
    ! grep -q "gh api" "$BATS_TEST_TMPDIR/gh.log" || false
}
