#!/usr/bin/env bash
# Aide commune des tests du relais Docker (#346) : isolation du relais sous
# $BATS_TEST_TMPDIR, jamais sur le vrai socket ni ses fichiers.

relais_docker_isole() {
    export DEVZONE_RELAIS_SOCKET="$BATS_TEST_TMPDIR/docker.sock"
    export DEVZONE_RELAIS_SOURCE="$BATS_TEST_TMPDIR/docker-host.sock"
    export DEVZONE_RELAIS_PID="$BATS_TEST_TMPDIR/socat.pid"
    export DEVZONE_RELAIS_LOG="$BATS_TEST_TMPDIR/socat.log"
    export DEVZONE_RELAIS_MARQUE="$BATS_TEST_TMPDIR/relais.echec"
    export DEVZONE_RELAIS_SUDO=""
}

# Aide commune de Kubernetes (#341) : le kubeconfig, le HOME et la copie du
# kubeconfig de l'hôte restent sous $BATS_TEST_TMPDIR, jamais ceux du poste.
kube_isole() {
    export HOME="$BATS_TEST_TMPDIR/home"
    export KUBECONFIG="$BATS_TEST_TMPDIR/kubeconfig"
    export DEVZONE_KUBE_HOTE="$BATS_TEST_TMPDIR/hote.config"
    mkdir -p "$HOME" "$BATS_TEST_TMPDIR" "$HOME/.kube"
}

# Aide de devzone agent (#328, tests agent.bats et agent-ecarts.bats) : faux
# npm, getent, curl et opencode sous $BATS_TEST_TMPDIR/bin, état et réseau
# isolés, délais réduits. Le faux opencode se pilote par FAKE_OP_* (voir ci-dessous).
agent_isole() {
    relais_docker_isole
    kube_isole
    DEVZONE="$BATS_TEST_DIRNAME/../../.devcontainer/devzone"
    export DEVZONE
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin"
    cd "$BATS_TEST_TMPDIR" || return 1
    export GIT_CONFIG_NOSYSTEM=1
    export DEVZONE_RACINE="$BATS_TEST_TMPDIR/racine"
    mkdir -p "$DEVZONE_RACINE/workspace"
    export DEVZONE_AGENT_ETAT="$BATS_TEST_TMPDIR/etat"
    export RESEAU_COUPE="$BATS_TEST_TMPDIR/reseau.coupe"
    export DEVZONE_AGENT_RESEAU_PAS=1
    export DEVZONE_AGENT_SILENCE=2
    export DEVZONE_AGENT_PAS=0.2
    export DEVZONE_AGENT_FIGEE=2
    export FAKE_OP_LOG="$BATS_TEST_TMPDIR/opencode.log"
    export FAKE_OP_CONSIGNE_LOG="$BATS_TEST_TMPDIR/consignes.log"
    export FAKE_OP_CONFIG_LOG="$BATS_TEST_TMPDIR/config.log"
    export FAKE_OP_ECHEC_MODELS="" FAKE_OP_MESSAGE="" FAKE_OP_RESEAU_MODELS=""
    export FAKE_OP_RESEAU_CHAQUE="" FAKE_OP_MUET_MODELS="" FAKE_OP_FIGEE_MODELS=""
    export FAKE_OP_TEXTE_MODELS="" FAKE_OP_ANCIEN_ERREUR_MODELS="" FAKE_OP_DUREE=30
    : >"$FAKE_OP_LOG"
    : >"$FAKE_OP_CONSIGNE_LOG"
    # npm simulé : l'activation du module ia installe de faux claude et opencode
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
    bash "$DEVZONE" activer ia >/dev/null 2>&1 || true
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
            'opencode/glm-5.3-flash-free' \
            'opencode/nemotron-3.5-super-vl-free' \
            'opencode/nemotron-3.5-lightning-free' \
            'opencode/mimo-v2.6-flash-free' \
            'opencode/beam-free' \
            'opencode/flint-40b-free' \
            'opencode/nemotron-3-ultra-free'
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
        case " ${FAKE_OP_ANCIEN_ERREUR_MODELS:-} " in
            *" $modele "*)
                echo "Free usage limit"
                for _ in $(seq 1 40); do echo "ligne de sortie sans erreur"; done
                exit 1
                ;;
        esac
        case " ${FAKE_OP_ECHEC_MODELS:-} " in
            *" $modele "*)
                echo "Error: ${FAKE_OP_MESSAGE:-Free usage limit}" >&2
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
            *" $modele "*) echo "extrait de code : Free usage limit (exemple)" ;;
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
    printf 'construis la feature\n' >"$DEVZONE_RACINE/workspace/consigne.txt"
    mkdir -p "$DEVZONE_RACINE/workspace/projet"
}

# Lance devzone agent sur la consigne de test ; le résultat est dans $status et $output (run).
agent_lance() {
    run bash "$DEVZONE" agent "$DEVZONE_RACINE/workspace/projet" "$DEVZONE_RACINE/workspace/consigne.txt"
}

# Chemin du journal du projet de test, où devzone agent écrit ses lignes.
agent_journal() {
    echo "$DEVZONE_RACINE/workspace/.agents/projet.log"
}
