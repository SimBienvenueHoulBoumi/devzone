#!/usr/bin/env bats
# Isolement network et autorisation d'acces entre namespaces devzone (#396 etape A).
# Tests avec faux kubectl, kind : aucun cluster touche.
# Les aides de manage/test/commun.bash : relais_docker_isole, kube_isole.

# Source des fonctions d'isolation
source /workspaces/devzone/workspace/wt/dz-396/.devcontainer/isolement.sh

source /workspaces/devzone/workspace/wt/dz-396/manage/test/commun.bash

setup() {
    relais_docker_isole
    kube_isole
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    POSTGRES="$BATS_TEST_DIRNAME/../../.devcontainer/postgres/postgres.sh"
    export HOME="$BATS_TEST_TMPDIR/home"
    export DEVZONE_RACINE="$BATS_TEST_TMPDIR/racine"
    export DEVZONE_ETAT="$BATS_TEST_TMPDIR/modules"
    export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
    mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin" "$DEVZONE_RACINE/workspace"
    : >"$DEVZONE_KUBE_HOTE"
    : >"$DEVZONE_ETAT"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    actif_sur() {
        local c="${1:-}"
        [ -n "$c" ] || return 2
        printf 'postgres=on\ncluster=%s\n' "$c" >"$DEVZONE_ETAT"
    }
}

faux_kubectl_isole() {
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
echo "kubectl $*" >>"$BATS_TEST_TMPDIR/kubectl.log"
T="$BATS_TEST_TMPDIR"
case "$*" in
    *"config get-contexts -o name"*)
        echo "docker-desktop"
        ;;
    *"config current-context"*) cat "$T/ctx" 2>/dev/null ;;
    *"config use-context"*) echo "${@: -1}" >"$T/ctx" ;;
    *"config unset current-context"*) : >"$T/ctx" ;;
    *"config view"*)
        nom=""
        for c in docker-desktop; do
            if [[ "$*" == *\"$c\"* ]]; then nom="$c"; break; fi
        done
        if [[ "$*" == *'.cluster.server'* ]]; then echo "https://127.0.0.1:6443"; else echo "$nom"; fi
        ;;
    *"get --raw /readyz"*)
        case "$*" in *"--context ${FAUX_INJOIGNABLE:-aucun} "*) exit 1 ;; esac ;;
    *"create namespace"*) printf 'kind: Namespace\nmetadata:\n  name: devzone-postgres\n' ;;
    *"get namespace devzone-postgres"*) [ -f "$T/ns" ]; exit $? ;;
    *"get namespaces -l"*) ;;
    *"apply -f -"*)
        # Manifeste reçu sur stdin : journalisé dans np (lu par le test) et apply.log
        tee -a "$T/apply.log" >>"$T/np"
        touch "$T/ns" ;;
    *"get secret postgres-admin -o jsonpath"*) printf 'YWRtaW4tZXhpc3RhbnQ=' ;;
    *"get secret"*) [ -f "$T/secret" ]; exit $? ;;
    *"create secret"*) touch "$T/secret" ;;
    *"rollout status"*) ;;
    *"readyReplicas"*) echo 1 ;;
    *"exec -i postgres-0"*"-c SELECT count"*) echo 2 ;;
    *"exec -i postgres-0"*"-c SELECT datname"*) printf 'taskmanager taskmanager\n' ;;
    *"exec -i postgres-0"*) cat >>"$T/sql.log" ;;
    *"delete namespace devzone-postgres"*) rm -f "$T/ns" "$T/secret" ;;
    *"port-forward"*) exit 0 ;;
esac
exit 0
KUBE
    chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
    : >"$BATS_TEST_TMPDIR/kubectl.log"
}

faux_kind_isole() {
    printf '#!/usr/bin/env bash\necho "kind $*" >>"$BATS_TEST_TMPDIR/kind.log"\nexit 0\n' >"$BATS_TEST_TMPDIR/bin/kind"
    chmod +x "$BATS_TEST_TMPDIR/bin/kind"
    : >"$BATS_TEST_TMPDIR/kind.log"
}

@test "isolement : namespace isolé avec NetworkPolicy devzone-meme-namespace" {
    faux_kubectl_isole
    faux_kind_isole
    printf 'kind-devzone\n' >"$BATS_TEST_TMPDIR/hote.contexts"
    printf 'kind-devzone\thttps://127.0.0.1:6443\n' >"$BATS_TEST_TMPDIR/hote.servers"

    # Test la fonction namespace_isoler directement
    namespace_isoler devzone-postgres
    [ "$?" -eq 0 ]

    # Vérifier que apply a été appelé
    grep -q 'devzone-meme-namespace' "$BATS_TEST_TMPDIR/apply.log"

    # Vérifier le contenu de la NetworkPolicy
    grep -q 'podSelector' "$BATS_TEST_TMPDIR/np" 
}

@test "isolement : autoriser puis interdire l'accès depuis un namespace vers PostgreSQL" {
    faux_kubectl_isole
    faux_kind_isole
    printf 'kind-devzone\n' >"$BATS_TEST_TMPDIR/hote.contexts"
    printf 'kind-devzone\thttps://127.0.0.1:6443\n' >"$BATS_TEST_TMPDIR/hote.servers"

    # Tester la fonction autoriser
    actif_sur kind-devzone
    run autoriser devzone-postgres
    [ "$status" -eq 0 ]
    [[ "$output" == *"règle autorisée vers devzone-postgres"* ]] || false
    # Le patch envoyé par autoriser : JSON valide, avec le namespaceSelector
    p="$(grep 'patch networkpolicy' "$BATS_TEST_TMPDIR/kubectl.log" | head -n 1 | sed 's/^.*-p //')"
    python3 -c 'import json,sys; json.loads(sys.argv[1])' "$p"
    [[ "$p" == *namespaceSelector* ]] || false

    # Tester la fonction interdire
    run interdire devzone-postgres
    [ "$status" -eq 0 ]
    [[ "$output" == *"règle interdite vers devzone-postgres"* ]] || false
    # Le patch d'interdire : JSON valide, sans namespaceSelector
    p="$(grep 'patch networkpolicy' "$BATS_TEST_TMPDIR/kubectl.log" | tail -n 1 | sed 's/^.*-p //')"
    python3 -c 'import json,sys; json.loads(sys.argv[1])' "$p"
    [[ "$p" != *namespaceSelector* ]] || false
}

@test "isolement : contexte de travail inchangé après devzone cluster" {
    faux_kubectl_isole
    faux_kind_isole
    printf 'kind-devzone\n' >"$BATS_TEST_TMPDIR/hote.contexts"
    printf 'kind-devzone\thttps://127.0.0.1:6443\n' >"$BATS_TEST_TMPDIR/hote.servers"

    # Faux nohup et faux sleep : le relais et les attentes ne partent jamais en arrière-plan
    cat >"$BATS_TEST_TMPDIR/bin/nohup" <<'NOHUP'
#!/usr/bin/env bash
echo "nohup $*" >>"$BATS_TEST_TMPDIR/nohup.log"
exit 0
NOHUP
    cat >"$BATS_TEST_TMPDIR/bin/sleep" <<'SLEEP'
#!/usr/bin/env bash
echo "sleep $*" >>"$BATS_TEST_TMPDIR/sleep.log"
exit 0
SLEEP
    chmod +x "$BATS_TEST_TMPDIR/bin/nohup" "$BATS_TEST_TMPDIR/bin/sleep"

    # Contexte kubectl courant : kind-devzone (tenu par le faux kubectl dans $BATS_TEST_TMPDIR/ctx)
    printf 'kind-devzone\n' >"$BATS_TEST_TMPDIR/ctx"
    actif_sur kind-devzone

    run bash "$DEVZONE" cluster docker-desktop --oui </dev/null
    [ "$status" -eq 0 ]
    # Le choix de cluster est enregistré
    grep -qx 'cluster=docker-desktop' "$DEVZONE_ETAT"
    # L'installation dans le nouveau cluster passe par le contexte devzone
    grep -q 'kubectl config set-context devzone --cluster=docker-desktop --user=docker-desktop' "$BATS_TEST_TMPDIR/kubectl.log"
    grep -q 'kubectl --context devzone apply -f -' "$BATS_TEST_TMPDIR/kubectl.log"
    # Le contexte utilisateur n'a pas été basculé : aucun use-context, ni unset
    ! grep -q 'config use-context' "$BATS_TEST_TMPDIR/kubectl.log" || false
    ! grep -q 'config unset current-context' "$BATS_TEST_TMPDIR/kubectl.log" || false
    [ "$(cat "$BATS_TEST_TMPDIR/ctx")" = "kind-devzone" ]
    [ "$(kubectl config current-context)" = "kind-devzone" ]
}