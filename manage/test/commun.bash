#!/usr/bin/env bash
# The shell still present calls the commands ported to Go as « devzone … »: the
# tests resolve « devzone » to the launcher of the repository under test (and its
# Go binary in .devcontainer/bin, built by the CI), never to a devzone installed on
# the machine (#864). A fake devzone put in PATH by a test still comes first.
PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.devcontainer" && pwd):$PATH"
export PATH

# Common Kubernetes helper (#341): the kubeconfig, the HOME and the copy of the
# host kubeconfig stay under $BATS_TEST_TMPDIR, never the workstation ones.
kube_isole() {
    export HOME="$BATS_TEST_TMPDIR/home"
    export KUBECONFIG="$BATS_TEST_TMPDIR/kubeconfig"
    export DEVZONE_KUBE_HOST="$BATS_TEST_TMPDIR/hote.config"
    mkdir -p "$HOME" "$BATS_TEST_TMPDIR" "$HOME/.kube"
}

# Go program of the workstation commands (#884): manage/devzone and
# manage/workspace.sh call it through DEVZONE_HOST_BIN for the commands ported to
# Go, so every bats file that runs them calls this helper in its setup. The
# binary of the package (default ./cmd/devzone, or ./cmd/devzone-pod for the pod
# launcher) is built once per file in $BATS_FILE_TMPDIR/<package>-go: the guard
# keeps the later tests from building it again. DEVZONE_HOST_BIN is exported.
# Without go, the file is skipped.
devzone_go_pret() {
    local paquet="${1:-./cmd/devzone}" bin racine
    bin="$BATS_FILE_TMPDIR/${paquet##*/}-go"
    command -v go >/dev/null 2>&1 || skip "go is not installed"
    racine="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    if [ ! -x "$bin" ]; then
        (cd "$racine" && go build -o "$bin" "$paquet") || { echo "go build failed"; return 1; }
    fi
    export DEVZONE_HOST_BIN="$bin"
}

# Helper for tests that simulate a missing tool (#497): creates <folder> with
# links to the only tools called by the scripts and tests. Call it in setup,
# before reducing PATH to <folder>: never all of /usr/bin or /bin, so a kubectl
# or helm installed on the workstation or the runner is not reachable.
outils_isoles() {
    local folder="$1" outil chemin
    mkdir -p "$folder"
    for outil in bash env grep dirname mv cat rm mkdir; do
        chemin="$(command -v "$outil")" || return 1
        ln -s "$chemin" "$folder/$outil"
    done
}

# Helper for devzone <folder> in Kubernetes mode (#735, the host mode is gone):
# fake kubectl and helm under $BATS_TEST_TMPDIR/bin-cluster, reachable "devzone"
# cluster, no workspace installed. The real workstation cluster is never touched.
cluster_pret() {
    mkdir -p "$BATS_TEST_TMPDIR/bin-cluster"
    cat >"$BATS_TEST_TMPDIR/bin-cluster/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
case "$*" in
    *"get-contexts"* | *"current-context"*) echo devzone ;;
esac
exit 0
KUBECTL
    cat >"$BATS_TEST_TMPDIR/bin-cluster/helm" <<'HELM'
#!/usr/bin/env bash
exit 1
HELM
    chmod +x "$BATS_TEST_TMPDIR/bin-cluster/kubectl" "$BATS_TEST_TMPDIR/bin-cluster/helm"
    export PATH="$BATS_TEST_TMPDIR/bin-cluster:$PATH"
}

# Helper for the devzone summary (#396): fake kind under $BATS_TEST_TMPDIR/bin
# that lists no cluster, so a real kind-gitlab cluster of the workstation does
# not make the old-cluster warning appear in the tests.
kind_vide() {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat >"$BATS_TEST_TMPDIR/bin/kind" <<'KIND'
#!/usr/bin/env bash
echo "kind $*" >>"$BATS_TEST_TMPDIR/kind.log"
exit 0
KIND
    chmod +x "$BATS_TEST_TMPDIR/bin/kind"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# Helper for devzone agent (#328, agent.bats and agent-gaps.bats): fake npm,
# getent, curl and opencode under $BATS_TEST_TMPDIR/bin, isolated state and
# network, short delays. The fake opencode is driven by FAKE_OP_* (see below).
agent_isole() {
    kube_isole
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    export DEVZONE
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin"
    cd "$BATS_TEST_TMPDIR" || return 1
    export GIT_CONFIG_NOSYSTEM=1
    export DEVZONE_ROOT="$BATS_TEST_TMPDIR/racine"
    mkdir -p "$DEVZONE_ROOT/workspace"
    export DEVZONE_AGENT_STATE="$BATS_TEST_TMPDIR/etat"
    export RESEAU_COUPE="$BATS_TEST_TMPDIR/reseau.coupe"
    export DEVZONE_AGENT_NETWORK_STEP=1
    export DEVZONE_AGENT_SILENCE=2
    export DEVZONE_AGENT_STEP=0.2
    export DEVZONE_AGENT_FROZEN=2
    export FAKE_OP_LOG="$BATS_TEST_TMPDIR/opencode.log"
    export FAKE_OP_CONSIGNE_LOG="$BATS_TEST_TMPDIR/consignes.log"
    export FAKE_OP_CONFIG_LOG="$BATS_TEST_TMPDIR/config.log"
    export FAKE_OP_KUBECONFIG_LOG="$BATS_TEST_TMPDIR/kubeconfig.log"
    export FAKE_OP_ECHEC_MODELS="" FAKE_OP_MESSAGE="" FAKE_OP_RESEAU_MODELS=""
    export FAKE_OP_RESEAU_CHAQUE="" FAKE_OP_MUET_MODELS="" FAKE_OP_FIGEE_MODELS=""
    export FAKE_OP_TEXTE_MODELS="" FAKE_OP_ANCIEN_ERREUR_MODELS="" FAKE_OP_DUREE=30
    : >"$FAKE_OP_LOG"
    : >"$FAKE_OP_CONSIGNE_LOG"
    # Fake npm: enabling the ai module installs fake claude and opencode
    export NPM_LOG="$BATS_TEST_TMPDIR/npm.log"
    : >"$NPM_LOG"
    cat >"$BATS_TEST_TMPDIR/bin/npm" <<'NPM'
#!/usr/bin/env bash
echo "npm $*" >>"$NPM_LOG"
if [ "${1:-}" = install ]; then
    printf '#!/usr/bin/env bash\necho 1.0.0\n' >"$BATS_TEST_TMPDIR/bin/claude"
    printf '#!/usr/bin/env bash\necho 1.0.0\n' >"$BATS_TEST_TMPDIR/bin/opencode"
    chmod +x "$BATS_TEST_TMPDIR/bin/claude" "$BATS_TEST_TMPDIR/bin/opencode"
fi
NPM
    # Fake getent: fails while $RESEAU_COUPE exists; its number counts failed attempts
    cat >"$BATS_TEST_TMPDIR/bin/getent" <<'GETENT'
#!/usr/bin/env bash
f="${RESEAU_COUPE:?}"
[ -f "$f" ] || exit 0
n="$(cat "$f")"
if [ "$n" -le 1 ]; then rm -f "$f"; else echo $(( n - 1 )) >"$f"; fi
exit 2
GETENT
    printf '#!/usr/bin/env bash\nexit 0\n' >"$BATS_TEST_TMPDIR/bin/curl"
    chmod +x "$BATS_TEST_TMPDIR/bin/npm" "$BATS_TEST_TMPDIR/bin/getent" "$BATS_TEST_TMPDIR/bin/curl"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    bash "$DEVZONE" enable ai >/dev/null 2>&1 || true
    cat >"$BATS_TEST_TMPDIR/bin/opencode" <<'OPCODEFAKE'
#!/usr/bin/env bash
# Fake opencode. FAKE_OP_ECHEC_MODELS: error $FAKE_OP_MESSAGE; FAKE_OP_RESEAU_MODELS:
# ENOTFOUND while $RESEAU_COUPE exists; FAKE_OP_RESEAU_CHAQUE: ENOTFOUND and the
# network cut at each launch; FAKE_OP_MUET_MODELS, FAKE_OP_FIGEE_MODELS: silence, frozen.
case "${1:-}" in
    models)
        printf '%s\n' \
            'opencode/big-pickle' \
            'opencode/deepseek-v4.1-flash-free' \
            'opencode/hy4-flash-free' \
            'opencode/nemotron-3.5-super-vl-free' \
            'opencode/nemotron-3.5-lightning-free' \
            'opencode/mimo-v2.6-flash-free' \
            'opencode/beam-free' \
            'opencode/flint-40b-free' \
            'opencode/longcat-2.5-free'
        ;;
    run)
        modele=""
        for a in "$@"; do
            case "$a" in opencode/*) modele="${a#opencode/}" ;; esac
        done
        if [ "$#" -gt 0 ]; then consigne="${!#}"; else consigne=""; fi
        echo "$modele" >>"${FAKE_OP_LOG:?}"
        printf '%s\n---\n' "$consigne" >>"${FAKE_OP_CONSIGNE_LOG:?}"
        printf '%s\n' "${OPENCODE_CONFIG_CONTENT:-}" >"${FAKE_OP_CONFIG_LOG:?}"
        printf '%s\n' "${KUBECONFIG:-}" >"${FAKE_OP_KUBECONFIG_LOG:?}"
        case " ${FAKE_OP_ANCIEN_ERREUR_MODELS:-} " in
            *" $modele "*)
                echo "Free usage limit"
                for _ in $(seq 1 40); do echo "output line without error"; done
                exit 1
                ;;
        esac
        case " ${FAKE_OP_ECHEC_MODELS:-} " in
            *" $modele "*)
                echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%S.000Z) level=ERROR run=8b522c10 message=\"stream error\" providerID=opencode modelID=$modele error.error=\"AI_APICallError: ${FAKE_OP_MESSAGE:-Free usage limit}\"" >&2
                exit 1
                ;;
        esac
        case " ${FAKE_OP_RESEAU_CHAQUE:-} " in
            *" $modele "*)
                echo 1 >"${RESEAU_COUPE:?}"
                echo "Error: ENOTFOUND opencode.ai" >&2
                exit 1
                ;;
        esac
        case " ${FAKE_OP_RESEAU_MODELS:-} " in
            *" $modele "*)
                if [ -f "${RESEAU_COUPE:?}" ]; then
                    echo "Error: ENOTFOUND opencode.ai" >&2
                    exit 1
                fi
                ;;
        esac
        case " ${FAKE_OP_MUET_MODELS:-} " in
            *" $modele "*)
                sleep "${FAKE_OP_DUREE:-30}"
                exit 0
                ;;
        esac
        case " ${FAKE_OP_TEXTE_MODELS:-} " in
            *" $modele "*) echo "code excerpt: Free usage limit and not available in your country" ;;
        esac
        echo "session $modele: instruction read, work starting"
        echo "the model $modele handled the instruction, the matching tests pass"
        echo "end of session $modele: no error, no permission refusal"
        case " ${FAKE_OP_FIGEE_MODELS:-} " in
            *" $modele "*) sleep "${FAKE_OP_DUREE:-30}" ;;
        esac
        exit 0
        ;;
esac
OPCODEFAKE
    chmod +x "$BATS_TEST_TMPDIR/bin/opencode"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# Test instruction and folder, devzone agent launch and project journal.
agent_consigne() {
    printf 'construis la feature\n' >"$DEVZONE_ROOT/workspace/consigne.txt"
    mkdir -p "$DEVZONE_ROOT/workspace/projet"
}

# Runs devzone agent on the test instruction; the result is in $status and $output (run).
agent_lance() {
    run bash "$DEVZONE" agent "$DEVZONE_ROOT/workspace/projet" "$DEVZONE_ROOT/workspace/consigne.txt"
}

# Path of the test project journal, where devzone agent writes its lines.
agent_journal() {
    echo "$DEVZONE_ROOT/workspace/.agents/projet.log"
}
