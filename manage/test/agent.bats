#!/usr/bin/env bats
# Commande devzone agent : lancement, rotation, reprise, configuration (#221, #328).
# Les causes d'écart, le réseau, l'état et liberer sont dans agent-ecarts.bats.

setup() {
    load commun
    agent_isole
}

@test "agent : appelant sans git push -> accepté, deny fourni par devzone" {
    agent_consigne
    export OPENCODE_CONFIG_CONTENT='{"permission":{"bash":{"*":"ask"}}}'
    agent_lance
    [ "$status" -eq 0 ]
    [ -s "$FAKE_OP_LOG" ]
    jq -e '.permission.bash["git push*"] == "deny"' "$FAKE_OP_CONFIG_LOG"
}

@test "agent : appelant avec * allow -> les deny de devzone restent et gagnent" {
    agent_consigne
    export OPENCODE_CONFIG_CONTENT='{"permission":{"bash":{"*":"allow"}}}'
    agent_lance
    [ "$status" -eq 0 ]
    for r in 'git push*' 'gh api*' 'repowarden ticket nouveau*' 'git checkout*' 'git reset*' 'git restore*' 'git stash*' 'git clean*' 'git branch -D*' 'repowarden proteger*' 'repowarden run*'; do
        jq -e --arg r "$r" '.permission.bash[$r] == "deny"' "$FAKE_OP_CONFIG_LOG" || { echo "deny perdu : $r"; false; }
    done
    jq -e '.permission.bash["*"] == "allow"' "$FAKE_OP_CONFIG_LOG"
    jq -e '(.permission.bash | keys_unsorted | index("*")) < (.permission.bash | keys_unsorted | index("git push*"))' "$FAKE_OP_CONFIG_LOG"
}

@test "agent : configuration fournie completee (git commit permis, bash32 protege)" {
    agent_consigne
    export OPENCODE_CONFIG_CONTENT='{"permission":{"bash":{"*":"ask","git push*":"deny"}}}'
    agent_lance
    [ "$status" -eq 0 ]
    grep -q '"git commit\*":"allow"' "$FAKE_OP_CONFIG_LOG" || false
    grep -q '"ln \*bash32\*":"deny"' "$FAKE_OP_CONFIG_LOG" || false
    grep -q '"git push\*":"deny"' "$FAKE_OP_CONFIG_LOG" || false
}

@test "agent : lance opencode sur la consigne, journal ecrit, fin de session" {
    agent_consigne
    agent_lance
    [ "$status" -eq 0 ]
    [ -f "$(agent_journal)" ]
    grep -q "fin avec opencode/" "$(agent_journal)" || false
    grep -qx "big-pickle" "$FAKE_OP_LOG" || false
    grep -q "construis la feature" "$FAKE_OP_CONSIGNE_LOG" || false
}

@test "agent : deux lancements -> deux modeles differents" {
    agent_consigne
    agent_lance
    [ "$status" -eq 0 ]
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(grep -c . "$FAKE_OP_LOG")" -eq 2 ]
    [ "$(sed -n '1p' "$FAKE_OP_LOG")" != "$(sed -n '2p' "$FAKE_OP_LOG")" ]
}

@test "agent : Free usage limit dans le code affiche, fin normale -> fin avec" {
    agent_consigne
    export FAKE_OP_TEXTE_MODELS="big-pickle"
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(grep -c . "$FAKE_OP_LOG")" -eq 1 ]
    grep -q "fin avec opencode/big-pickle" "$(agent_journal)" || false
    ! grep -q "écarté" "$(agent_journal)" || false
}

@test "agent : erreur ancienne hors des 30 dernieres lignes -> arrete en erreur, pas refus" {
    agent_consigne
    export FAKE_OP_ANCIEN_ERREUR_MODELS="big-pickle"
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(grep -c . "$FAKE_OP_LOG")" -eq 2 ]
    grep -q "arrêté en erreur (code 1)" "$(agent_journal)" || false
    ! grep -q "écarté" "$(agent_journal)" || false
}

@test "agent : session figee -> relancee, consigne de reprise" {
    agent_consigne
    export FAKE_OP_FIGEE_MODELS="big-pickle"
    agent_lance
    [ "$status" -eq 0 ]
    [ "$(grep -c . "$FAKE_OP_LOG")" -eq 2 ]
    [ "$(sed -n '2p' "$FAKE_OP_LOG")" = "deepseek-v4.1-flash-free" ]
    grep -q "REPRISE" "$FAKE_OP_CONSIGNE_LOG" || false
    grep -q "git log" "$FAKE_OP_CONSIGNE_LOG" || false
    grep -q "figé" "$(agent_journal)" || false
}

@test "agent : tous les modeles ecartes -> code 3" {
    agent_consigne
    export FAKE_OP_ECHEC_MODELS="big-pickle deepseek-v4.1-flash-free glm-5.3-flash-free nemotron-3.5-super-vl-free nemotron-3.5-lightning-free mimo-v2.6-flash-free beam-free flint-40b-free nemotron-3-ultra-free"
    agent_lance
    [ "$status" -eq 3 ]
    grep -q "aucun modèle gratuit disponible" "$(agent_journal)" || false
}

@test "agent : ia désactivé → refuse de lancer, code 2, message pour l'activer" {
    bash "$DEVZONE" desactiver ia
    agent_consigne
    agent_lance
    [ "$status" -eq 2 ]
    [[ "$output" == *"devzone activer ia"* ]] || false
}

@test "agent : session opencode avec KUBECONFIG dédié, sans hote.config" {
    mkdir -p "$HOME/.kube"
    printf 'current-context: docker-desktop\n' >"$HOME/.kube/config"
    agent_consigne
    agent_lance
    [ "$status" -eq 0 ]
    [ -f "$FAKE_OP_KUBECONFIG_LOG" ] || false
    grep -qx "$DEVZONE_AGENT_ETAT/kubeconfig" "$FAKE_OP_KUBECONFIG_LOG" || false
    ! grep -q 'hote.config' "$FAKE_OP_KUBECONFIG_LOG" || false
}

# Faux kubectl : « config view --minify --flatten --context devzone » ne rend que
# le contexte devzone de $KUBECONFIG, et échoue s'il n'existe pas (#470)
faux_kubectl_devzone() {
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
[ "$*" = "config view --minify --flatten --context devzone" ] || exit 1
grep -q 'name: devzone' "$KUBECONFIG" 2>/dev/null || { echo "error: context was not found" >&2; exit 1; }
grep -v 'kind-x' "$KUBECONFIG"
KUBECTL
    chmod +x "$BATS_TEST_TMPDIR/bin/kubectl"
}

@test "agent : kubeconfig de session sans les autres contextes, en 600 (#470)" {
    faux_kubectl_devzone
    printf 'contexts:\n- name: devzone\n- name: kind-x\n' >"$HOME/.kube/config"
    agent_consigne
    agent_lance
    [ "$status" -eq 0 ]
    grep -q 'name: devzone' "$DEVZONE_AGENT_ETAT/kubeconfig" || false
    ! grep -q 'kind-x' "$DEVZONE_AGENT_ETAT/kubeconfig" || false
    [ "$(stat -c %a "$DEVZONE_AGENT_ETAT/kubeconfig")" = 600 ]
}

@test "agent : sans contexte devzone -> kubeconfig vide et ligne de journal (#470)" {
    faux_kubectl_devzone
    printf 'contexts:\n- name: kind-x\n' >"$HOME/.kube/config"
    agent_consigne
    agent_lance
    [ "$status" -eq 0 ]
    [ ! -s "$DEVZONE_AGENT_ETAT/kubeconfig" ]
    [ "$(stat -c %a "$DEVZONE_AGENT_ETAT/kubeconfig")" = 600 ]
    grep -q "=== kubernetes : aucun contexte devzone, session sans accès" "$(agent_journal)" || false
}

@test "agent : verrou recent sans pid -> pas repris, attente puis refus" {
    # Un verrou sans pid n'est volé que si son âge dépasse 30 s (#377)
    source "$BATS_TEST_DIRNAME/../../.devcontainer/agent-session.sh"
    AGENT_ETAT="$DEVZONE_AGENT_ETAT"
    export DEVZONE_AGENT_VERROU_MAX=2
    mkdir -p "$AGENT_ETAT/verrou"
    debut="$(date +%s)"
    run verrou_prendre
    [ "$status" -eq 1 ] || false
    [ $(( $(date +%s) - debut )) -ge 1 ] || false
    [ $(( $(date +%s) - debut )) -le 5 ] || false
    [ -d "$AGENT_ETAT/verrou" ] || false
    [ ! -e "$AGENT_ETAT/verrou/pid" ] || false
}

@test "agent : verrou recent avec pid inconnu (autre conteneur) -> pas repris" {
    # Pid absent de cet espace de pids : seul l'âge du verrou décide (#377)
    source "$BATS_TEST_DIRNAME/../../.devcontainer/agent-session.sh"
    AGENT_ETAT="$DEVZONE_AGENT_ETAT"
    export DEVZONE_AGENT_VERROU_MAX=2
    mkdir -p "$AGENT_ETAT/verrou"
    echo 999999 >"$AGENT_ETAT/verrou/pid"
    debut="$(date +%s)"
    run verrou_prendre
    [ "$status" -eq 1 ] || false
    [ $(( $(date +%s) - debut )) -ge 1 ] || false
    grep -qx 999999 "$AGENT_ETAT/verrou/pid" || false
}

@test "agent : verrou de plus de 30 s -> repris aussitôt, verrou laché nettoyé" {
    # Verrou abandonné par un arrêt : âge de plus de 30 s, repris sans attendre
    # même si son pid est encore vivant, l'âge seul décide (#377)
    source "$BATS_TEST_DIRNAME/../../.devcontainer/agent-session.sh"
    AGENT_ETAT="$DEVZONE_AGENT_ETAT"
    mkdir -p "$AGENT_ETAT/verrou"
    echo "$$" >"$AGENT_ETAT/verrou/pid"
    touch -d '-60 seconds' "$AGENT_ETAT/verrou" 2>/dev/null || touch -t 200001010000 "$AGENT_ETAT/verrou" || false
    debut="$(date +%s)"
    run verrou_prendre
    [ "$status" -eq 0 ] || false
    [ $(( $(date +%s) - debut )) -le 5 ] || false
    [ -s "$AGENT_ETAT/verrou/pid" ] || false
    verrou_lacher
    [ ! -e "$AGENT_ETAT/verrou" ] || false
}
