#!/usr/bin/env bash
# Aide commune de Kubernetes (#341) : le kubeconfig, le HOME et la copie du
# kubeconfig de l'hôte restent sous $BATS_TEST_TMPDIR, jamais ceux du poste.
kube_isole() {
    export HOME="$BATS_TEST_TMPDIR/home"
    export KUBECONFIG="$BATS_TEST_TMPDIR/kubeconfig"
    export DEVZONE_KUBE_HOST="$BATS_TEST_TMPDIR/hote.config"
    mkdir -p "$HOME" "$BATS_TEST_TMPDIR" "$HOME/.kube"
}

# Aide des tests qui simulent un outil absent (#497) : crée <dossier> avec des
# liens vers les seuls outils que les scripts et les tests appellent. À appeler
# dans setup, avant de réduire PATH à <dossier> : jamais /usr/bin ni /bin entiers,
# donc un kubectl ou un helm installé sur le poste ou le runner n'est pas joignable.
outils_isoles() {
    local dossier="$1" outil chemin
    mkdir -p "$dossier"
    for outil in bash env grep dirname mv cat rm mkdir; do
        chemin="$(command -v "$outil")" || return 1
        ln -s "$chemin" "$dossier/$outil"
    done
}

# Aide de devzone <dossier> en mode Kubernetes (#735, le poste Docker est retiré) :
# faux kubectl et helm sous $BATS_TEST_TMPDIR/bin-cluster, cluster « devzone »
# joignable, aucun workspace installé. Le cluster réel du poste n'est jamais touché.
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

# Aide du récapitulatif devzone (#396) : faux kind sous $BATS_TEST_TMPDIR/bin qui
# ne liste aucun cluster, pour qu'un vrai cluster kind-gitlab du poste ne fasse
# pas apparaître l'avertissement d'ancien cluster dans les tests.
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

# Aide de devzone agent (#328, tests agent.bats et agent-gaps.bats) : faux
# npm, getent, curl et opencode sous $BATS_TEST_TMPDIR/bin, état et réseau
# isolés, délais réduits. Le faux opencode se pilote par FAKE_OP_* (voir ci-dessous).
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
    # npm simulé : l'activation du module ai installe de faux claude et opencode
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
    # Faux getent : échoue tant que $RESEAU_COUPE existe ; son nombre compte les essais ratés
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
# Faux opencode. FAKE_OP_ECHEC_MODELS : erreur $FAKE_OP_MESSAGE ; FAKE_OP_RESEAU_MODELS :
# ENOTFOUND tant que $RESEAU_COUPE existe ; FAKE_OP_RESEAU_CHAQUE : ENOTFOUND et réseau
# coupé à chaque lancement ; FAKE_OP_MUET_MODELS, FAKE_OP_FIGEE_MODELS : silence, figée.
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
                for _ in $(seq 1 40); do echo "ligne de sortie sans erreur"; done
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
            *" $modele "*) echo "extrait de code : Free usage limit et not available in your country" ;;
        esac
        echo "session $modele : consigne lue, travail commence"
        echo "le modele $modele a traite la consigne, les tests correspondants passent"
        echo "fin de session $modele : aucune erreur, aucun refus de permission"
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

# Consigne et dossier de test, lancement de devzone agent et journal du projet.
agent_consigne() {
    printf 'construis la feature\n' >"$DEVZONE_ROOT/workspace/consigne.txt"
    mkdir -p "$DEVZONE_ROOT/workspace/projet"
}

# Lance devzone agent sur la consigne de test ; le résultat est dans $status et $output (run).
agent_lance() {
    run bash "$DEVZONE" agent "$DEVZONE_ROOT/workspace/projet" "$DEVZONE_ROOT/workspace/consigne.txt"
}

# Chemin du journal du projet de test, où devzone agent écrit ses lignes.
agent_journal() {
    echo "$DEVZONE_ROOT/workspace/.agents/projet.log"
}
