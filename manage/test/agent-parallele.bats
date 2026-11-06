#!/usr/bin/env bats
# Commande devzone agent : lancements simultanés, rang partagé pris sous verrou et
# écarts écrits fichier par fichier (#289). Rotation et reprise : agent.bats.

setup() {
    load commun
    relais_docker_isole
    kube_isole
    agent_isole
    export DEVZONE_AGENT_SILENCE=10
    mkdir -p "$DEVZONE_AGENT_ETAT"
    # Faux opencode qui dort 2 s avant de travailler : deux lancements vivent
    # réellement en même temps, comme deux `devzone agent` partis au même instant.
    mv "$BATS_TEST_TMPDIR/bin/opencode" "$BATS_TEST_TMPDIR/bin/opencode.reel"
    cat >"$BATS_TEST_TMPDIR/bin/opencode" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = run ]; then sleep 2; fi
exec "$BATS_TEST_TMPDIR/bin/opencode.reel" "$@"
FAKE
    chmod +x "$BATS_TEST_TMPDIR/bin/opencode"
}

# Lance devzone agent en arrière-plan sur un dossier ; le pid est dans AGENT_PID.
lancer_fond() {
    bash "$DEVZONE" agent "$1" "$DEVZONE_RACINE/workspace/consigne.txt" >"$2" 2>&1 &
    AGENT_PID=$!
}

# Premier modèle choisi dans le journal d'un dossier de lancement parallèle.
premier_modele() {
    grep -m1 -oE '^=== modèle opencode/[A-Za-z0-9._-]+' "$1" | sed 's#.*opencode/##'
}

# Affiche, sur la sortie de bats, les faits visibles au moment d'un echec :
# journaux complets des agents, rang et liste de l'etat, modeles du faux
# opencode, sorties de chaque lancement (un.out, deux.out...).
diagnostic() {
    echo "===== diagnostic agent-parallele =====" >&2
    echo "--- journaux des agents ---" >&2
    for j in "$DEVZONE_RACINE"/workspace/.agents/*.log; do
        [ -e "$j" ] || continue
        echo "### $j" >&2
        cat "$j" >&2
    done
    echo "--- rang ($DEVZONE_AGENT_ETAT/rang) ---" >&2
    [ -r "$DEVZONE_AGENT_ETAT/rang" ] && cat "$DEVZONE_AGENT_ETAT/rang" >&2
    echo "--- liste de $DEVZONE_AGENT_ETAT ---" >&2
    ls -la "$DEVZONE_AGENT_ETAT" >&2
    echo "--- modeles opencode ---" >&2
    opencode models opencode >&2
    echo "--- sorties des lancements ---" >&2
    for o in "$BATS_TEST_TMPDIR"/*.out; do
        [ -e "$o" ] || continue
        echo "### $o" >&2
        cat "$o" >&2
    done
    echo "===== fin diagnostic agent-parallele =====" >&2
}

@test "agent : deux lancements simultanes -> les deux demarrent sur deux modeles differents" {
    printf 'construis la feature\n' >"$DEVZONE_RACINE/workspace/consigne.txt"
    mkdir -p "$DEVZONE_RACINE/workspace/projet-un" "$DEVZONE_RACINE/workspace/projet-deux"
    j1="$DEVZONE_RACINE/workspace/.agents/projet-un.log"
    j2="$DEVZONE_RACINE/workspace/.agents/projet-deux.log"
    lancer_fond "$DEVZONE_RACINE/workspace/projet-un" "$BATS_TEST_TMPDIR/un.out"
    p1="$AGENT_PID"
    lancer_fond "$DEVZONE_RACINE/workspace/projet-deux" "$BATS_TEST_TMPDIR/deux.out"
    p2="$AGENT_PID"
    s1=0
    wait "$p1" || s1=$?
    s2=0
    wait "$p2" || s2=$?
    [ "$s1" -eq 0 ]
    [ "$s2" -eq 0 ]
    grep -q '^=== modèle opencode/' "$j1" || false
    grep -q '^=== modèle opencode/' "$j2" || false
    ! grep -q "aucun modèle gratuit disponible" "$j1" || false
    ! grep -q "aucun modèle gratuit disponible" "$j2" || false
    [ "$(premier_modele "$j1")" != "$(premier_modele "$j2")" ]
}

@test "agent : trois lancements simultanes -> aucun ne s'arrete faute de modele" {
    printf 'construis la feature\n' >"$DEVZONE_RACINE/workspace/consigne.txt"
    mkdir -p "$DEVZONE_RACINE/workspace/projet-trois" "$DEVZONE_RACINE/workspace/projet-quatre" \
        "$DEVZONE_RACINE/workspace/projet-cinq"
    lancer_fond "$DEVZONE_RACINE/workspace/projet-trois" "$BATS_TEST_TMPDIR/trois.out"
    p1="$AGENT_PID"
    lancer_fond "$DEVZONE_RACINE/workspace/projet-quatre" "$BATS_TEST_TMPDIR/quatre.out"
    p2="$AGENT_PID"
    lancer_fond "$DEVZONE_RACINE/workspace/projet-cinq" "$BATS_TEST_TMPDIR/cinq.out"
    p3="$AGENT_PID"
    s1=0
    wait "$p1" || s1=$?
    s2=0
    wait "$p2" || s2=$?
    s3=0
    wait "$p3" || s3=$?
    [ "$s1" -eq 0 ]
    [ "$s2" -eq 0 ]
    [ "$s3" -eq 0 ]
    for j in projet-trois projet-quatre projet-cinq; do
        journal="$DEVZONE_RACINE/workspace/.agents/$j.log"
        grep -q '^=== modèle opencode/' "$journal" || false
        ! grep -q "aucun modèle gratuit disponible" "$journal" || false
    done
}

@test "agent : tous ecartes sauf un -> les deux prennent ce modele, aucun seulement si tous ecartes" {
    printf 'construis la feature\n' >"$DEVZONE_RACINE/workspace/consigne.txt"
    mkdir -p "$DEVZONE_RACINE/workspace/projet-six" "$DEVZONE_RACINE/workspace/projet-sept" \
        "$DEVZONE_RACINE/workspace/projet-huit"
    for m in deepseek-v4.1-flash-free glm-5.3-flash-free nemotron-3.5-super-vl-free \
        nemotron-3.5-lightning-free mimo-v2.6-flash-free beam-free flint-40b-free \
        nemotron-3-ultra-free; do
        echo "$(date +%s) quota 3600" >"$DEVZONE_AGENT_ETAT/ecart-$m"
    done
    j1="$DEVZONE_RACINE/workspace/.agents/projet-six.log"
    j2="$DEVZONE_RACINE/workspace/.agents/projet-sept.log"
    lancer_fond "$DEVZONE_RACINE/workspace/projet-six" "$BATS_TEST_TMPDIR/six.out"
    p1="$AGENT_PID"
    lancer_fond "$DEVZONE_RACINE/workspace/projet-sept" "$BATS_TEST_TMPDIR/sept.out"
    p2="$AGENT_PID"
    s1=0
    wait "$p1" || s1=$?
    s2=0
    wait "$p2" || s2=$?
    [ "$s1" -eq 0 ]
    [ "$s2" -eq 0 ]
    [ "$(premier_modele "$j1")" = "big-pickle" ]
    [ "$(premier_modele "$j2")" = "big-pickle" ]
    ! grep -q "aucun modèle gratuit disponible" "$j1" || false
    ! grep -q "aucun modèle gratuit disponible" "$j2" || false
    echo "$(date +%s) quota 3600" >"$DEVZONE_AGENT_ETAT/ecart-big-pickle"
    j3="$DEVZONE_RACINE/workspace/.agents/projet-huit.log"
    lancer_fond "$DEVZONE_RACINE/workspace/projet-huit" "$BATS_TEST_TMPDIR/huit.out"
    p3="$AGENT_PID"
    s3=0
    wait "$p3" || s3=$?
    [ "$s3" -eq 3 ]
    grep -q "aucun modèle gratuit disponible" "$j3" || false
}

@test "agent : journal trace la prise du rang (=== rang debut/total)" {
    printf 'construis la feature\n' >"$DEVZONE_RACINE/workspace/consigne.txt"
    mkdir -p "$DEVZONE_RACINE/workspace/projet-rang"
    journal="$DEVZONE_RACINE/workspace/.agents/projet-rang.log"
    bash "$DEVZONE" agent "$DEVZONE_RACINE/workspace/projet-rang" "$DEVZONE_RACINE/workspace/consigne.txt" >"$BATS_TEST_TMPDIR/rang.out" 2>&1
    [ "$?" -eq 0 ] || false
    grep -qE '^=== rang [0-9]+/[0-9]+$' "$journal" || false
}

# Après un test en échec seulement (BATS_TEST_COMPLETED vide) : les faits
# visibles en CI (#385), sans changer les assertions.
teardown() {
    [ -n "${BATS_TEST_COMPLETED:-}" ] || diagnostic
}
