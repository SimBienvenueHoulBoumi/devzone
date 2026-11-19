#!/usr/bin/env bats
# devzone workspace services (#528): temporary administrator created and
# removed by the workstation, installer run inside the pod with the token on
# stdin. Fake kubectl in $BATS_TEST_TMPDIR/bin: no cluster is touched.

setup() {
    load commun
    relais_docker_isole
    kube_isole
    RACINE="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CLI="$RACINE/manage/devzone"
    T="$BATS_TEST_TMPDIR"
    mkdir -p "$T/bin"
    : >"$T/kubectl.log"
    cat >"$T/bin/kubectl" <<'KUBE'
#!/usr/bin/env bash
T="$BATS_TEST_TMPDIR"
echo "kubectl $*" >>"$T/kubectl.log"
case "$*" in
    "config get-contexts -o name") echo "${FAUX_CONTEXTES:-docker-desktop}" ;;
    *"get pod devzone-workspace-0 "*) echo "${FAUX_POD:-Running}" ;;
    *"apply -f -"*) cat >>"$T/apply.yaml" ;;
    *"create token "*) echo "TOKEN-123" ;;
    *"exec -i "*)
        cat >"$T/exec.stdin"
        [ "${FAUX_EXEC_ECHEC:-0}" = 1 ] && exit 3
        ;;
    *"get namespace "*)
        ns="${!#}"
        case " ${FAUX_NS:-} " in *" $ns "*) exit 0 ;; esac
        exit 1
        ;;
esac
exit 0
KUBE
    chmod +x "$T/bin/kubectl"
    export PATH="$T/bin:$PATH"
    # Devzone folder of the workstation: its own state, Argo CD off (#516)
    cd "$T" || return 1
    printf 'workspace=kubernetes\nargocd=off\n' >"$T/.devzone.modules"
}

@test "services enable gitlab: administrator applied, token on stdin only, installer in the pod, administrator removed" {
    export FAUX_CONTEXTES="devzone"
    run bash "$CLI" workspace services enable gitlab
    [ "$status" -eq 0 ]
    [[ "$output" == *"✔ enable gitlab done"* ]] || false
    grep -q 'kind: ClusterRoleBinding' "$T/apply.yaml"
    grep -q 'name: cluster-admin' "$T/apply.yaml"
    grep -q 'name: devzone-services-admin' "$T/apply.yaml"
    grep -q -- '--context devzone create token devzone-services-admin --namespace devzone-workspace --duration 1h' "$T/kubectl.log"
    grep -q -- 'exec -i devzone-workspace-0 --namespace devzone-workspace -c workspace -- bash /usr/local/share/devzone/.devcontainer/services-admin.sh enable gitlab$' "$T/kubectl.log"
    [ "$(cat "$T/exec.stdin")" = "TOKEN-123" ]
    ! grep -q 'TOKEN-123' "$T/kubectl.log" || false
    [[ "$output" != *"TOKEN-123"* ]] || false
    grep -q 'delete clusterrolebinding devzone-services-admin --ignore-not-found' "$T/kubectl.log"
    grep -q 'delete serviceaccount devzone-services-admin --namespace devzone-workspace --ignore-not-found' "$T/kubectl.log"
    # Order: apply, token, exec, delete
    [ "$(grep -n 'apply -f -' "$T/kubectl.log" | head -1 | cut -d: -f1)" -lt "$(grep -n 'create token' "$T/kubectl.log" | cut -d: -f1)" ]
    [ "$(grep -n 'exec -i' "$T/kubectl.log" | cut -d: -f1)" -lt "$(grep -n 'delete clusterrolebinding' "$T/kubectl.log" | cut -d: -f1)" ]
}

@test "services disable postgres --oui: the options reach the installer" {
    run bash "$CLI" workspace services disable postgres --oui
    [ "$status" -eq 0 ]
    grep -q 'services-admin.sh disable postgres --oui$' "$T/kubectl.log"
}

@test "services disable postgres --yes: reaches the installer as --yes, no deprecation (#557)" {
    run --separate-stderr bash "$CLI" workspace services disable postgres --yes
    [ "$status" -eq 0 ]
    grep -q 'services-admin.sh disable postgres --yes$' "$T/kubectl.log"
    [[ "$stderr" != *"deprecated"* ]] || false
}

@test "services seed gitlab: the seed runs in the pod through services-admin.sh seed (#538)" {
    export FAUX_CONTEXTES="devzone"
    run bash "$CLI" workspace services seed gitlab
    [ "$status" -eq 0 ]
    grep -q 'services-admin.sh seed gitlab$' "$T/kubectl.log"
}

@test "services seed postgres: refused, nothing run in the pod (#538)" {
    run bash "$CLI" workspace services seed postgres
    [ "$status" -eq 1 ]
    [[ "$output" == *"seed: only gitlab"* ]] || false
    ! grep -q 'exec -i' "$T/kubectl.log" || false
}

@test "services enable: pod not running, nothing applied" {
    export FAUX_POD=Pending
    run bash "$CLI" workspace services enable gitlab
    [ "$status" -eq 1 ]
    [[ "$output" == *"not running: devzone workspace start"* ]] || false
    [ ! -f "$T/apply.yaml" ]
    ! grep -q 'create token' "$T/kubectl.log" || false
}

@test "services enable: installer failure, code kept, administrator still removed" {
    export FAUX_EXEC_ECHEC=1
    run bash "$CLI" workspace services enable postgres
    [ "$status" -eq 3 ]
    [[ "$output" == *"failed (code 3)"* ]] || false
    grep -q 'delete clusterrolebinding devzone-services-admin' "$T/kubectl.log"
    grep -q 'delete serviceaccount devzone-services-admin' "$T/kubectl.log"
}

@test "services enable: unknown service refused" {
    run bash "$CLI" workspace services enable redis
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown service: redis"* ]] || false
    ! grep -q 'apply' "$T/kubectl.log" || false
}

@test "services status: installed or not, by namespace" {
    export FAUX_NS="devzone-postgres"
    run bash "$CLI" workspace services status
    [ "$status" -eq 0 ]
    [[ "$output" == *"✔ postgres installed (namespace devzone-postgres)"* ]] || false
    [[ "$output" == *"○ gitlab not installed: devzone workspace services enable gitlab"* ]] || false
    [[ "$output" == *"○ argocd not installed"* ]] || false
    [[ "$output" == *"○ mysql not installed: devzone workspace services enable mysql"* ]] || false
}

@test "services: unknown subcommand and help" {
    run bash "$CLI" workspace services foo
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown subcommand: foo"* ]] || false
    run bash "$CLI" workspace --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"services enable|disable <service>"* ]] || false
}

@test "services enable gitlab: gitlab=on written in .devzone.modules (#605)" {
    run bash "$CLI" workspace services enable gitlab
    [ "$status" -eq 0 ]
    grep -qx 'gitlab=on' "$T/.devzone.modules"
}

@test "services disable postgres: postgres=off written in .devzone.modules (#605)" {
    run bash "$CLI" workspace services disable postgres
    [ "$status" -eq 0 ]
    grep -qx 'postgres=off' "$T/.devzone.modules"
}

@test "services enable: installer failure, .devzone.modules untouched (#605)" {
    run env FAUX_EXEC_ECHEC=1 bash "$CLI" workspace services enable gitlab
    [ "$status" -eq 3 ]
    ! grep -q '^gitlab=' "$T/.devzone.modules" || false
    [ "$(cat "$T/.devzone.modules")" = "$(printf 'workspace=kubernetes\nargocd=off')" ]
}

@test "services enable postgres: the other lines of .devzone.modules are kept (#605)" {
    printf 'workspace=kubernetes\nfoo=bar\nargocd=off\n' >"$T/.devzone.modules"
    run bash "$CLI" workspace services enable postgres
    [ "$status" -eq 0 ]
    grep -qx 'postgres=on' "$T/.devzone.modules"
    grep -qx 'foo=bar' "$T/.devzone.modules"
    grep -qx 'workspace=kubernetes' "$T/.devzone.modules"
    grep -qx 'argocd=off' "$T/.devzone.modules"
}

@test "services disable mysql: an absent .devzone.modules is created (#605)" {
    rm -f "$T/.devzone.modules"
    run bash "$CLI" workspace services disable mysql
    [ "$status" -eq 0 ]
    [ -f "$T/.devzone.modules" ]
    grep -qx 'mysql=off' "$T/.devzone.modules"
}

@test "services seed and status leave .devzone.modules untouched (#605)" {
    run bash "$CLI" workspace services seed gitlab
    [ "$status" -eq 0 ]
    run bash "$CLI" workspace services status
    [ "$status" -eq 0 ]
    ! grep -q '^gitlab=' "$T/.devzone.modules" || false
}
