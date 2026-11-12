#!/usr/bin/env bash
# Pourquoi : hors du pod, devzone agent lance opencode dans le workspace
# Kubernetes deja demarre (projets et journaux du pod), ou localement avec
# --local ; le journal du pod est rapatrie dans celui du poste (#431).
# Bibliothèque sourcée par agent.sh : aucune commande n'est lancée ici.

# Vrai dans le conteneur workspace du cluster, qui porte le repere du chart.
agent_dans_pod() {
    [ "${DEVZONE_WORKSPACE:-}" = kubernetes ]
}

# kubectl du poste : contexte devzone s'il existe, puis namespace du workspace.
agent_kc() {
    if kubectl config get-contexts -o name 2>/dev/null | grep -qx devzone; then
        kubectl --context devzone --namespace devzone-workspace "$@"
    else
        kubectl --namespace devzone-workspace "$@"
    fi
}

# Pourquoi : lancer opencode est commun à chaque tentative de modèle, et la
# préparation de la kubeconfig dépend du workspace Kubernetes ; ce bloc vit ici
# avec le reste du pod (#431), agent.sh ne garde que la boucle des modèles.
opencode_lancer() {
    local dossier="$1" m="$2" consigne="$3" journal="$4" etat="$5"
    local agent_kube="$etat/kubeconfig"
    if agent_dans_pod; then
        # Dans le pod, le compte de service limité est le seul accès : aucun
        # kubeconfig du poste n'entre dans l'environnement d'opencode.
        (cd "$dossier" && env -u KUBECONFIG DEVZONE_AGENT_SESSION=1 opencode run --print-logs --log-level ERROR --auto -m "opencode/$m" "$(cat "$consigne")" </dev/null >>"$journal" 2>&1) &
    else
        if [ -f "$HOME/.kube/config" ]; then
            (umask 077; KUBECONFIG="$HOME/.kube/config" kubectl config view --minify --flatten --context devzone >"$agent_kube") 2>/dev/null || : >"$agent_kube"
            chmod 600 "$agent_kube"
            [ -s "$agent_kube" ] || echo "=== kubernetes : aucun contexte devzone, session sans accès" >>"$journal"
        else
            : >"$agent_kube"
        fi
        (cd "$dossier" && KUBECONFIG="$agent_kube" DEVZONE_AGENT_SESSION=1 opencode run --print-logs --log-level ERROR --auto -m "opencode/$m" "$(cat "$consigne")" </dev/null >>"$journal" 2>&1) &
    fi
}

# Vrai si le pod du workspace tourne et que la commande vient du poste.
workspace_disponible() {
    if agent_dans_pod; then return 1; fi
    local phase
    phase="$(agent_kc get pod devzone-workspace-0 -o jsonpath='{.status.phase}' --request-timeout=5s 2>/dev/null)" || return 1
    [ "$phase" = Running ]
}

# Lance la consigne dans le pod, puis rapatrie son journal même en échec.
agent_workspace() {
    local dossier="$1" consigne="$2" nom journal code=0
    local racine_pod=/home/vscode/.local/share/devzone
    [ -d "$dossier" ] || refuse "dossier introuvable : $dossier (cherché depuis $(pwd))"
    nom="$(basename "$(cd "$dossier" && pwd -P)")"
    if ! agent_kc exec devzone-workspace-0 -c workspace -- test -d "/workspaces/projets/$nom" 2>/dev/null; then
        refuse "projet $nom absent du workspace Kubernetes : devzone workspace copier-vers $dossier (sur la machine), ou --local"
    fi
    echo "devzone agent : workspace Kubernetes (pod devzone-workspace-0, /workspaces/projets/$nom) ; --local pour le conteneur"
    agent_kc cp "$consigne" "devzone-workspace-0:/tmp/devzone-agent-$nom.md" -c workspace
    agent_kc exec devzone-workspace-0 -c workspace -- env DEVZONE_RACINE="$racine_pod" bash -lc 'devzone agent "$1" "$2"' _ "/workspaces/projets/$nom" "/tmp/devzone-agent-$nom.md" || code=$?
    journal="$(journal_de "$dossier")"
    mkdir -p "$(dirname "$journal")"
    if ! agent_kc exec devzone-workspace-0 -c workspace -- cat "$racine_pod/workspace/.agents/$nom.log" >>"$journal"; then
        echo "=== journal du pod introuvable" >>"$journal"
    fi
    return "$code"
}

agent_aide() {
    cat <<'AGENTEOF2'
usage : devzone agent [--local] <dossier> <fichier-consigne>
        lance opencode sur la consigne, modèles gratuits en rotation
        workspace Kubernetes d'abord s'il tourne ; --local : ce conteneur
        devzone agent etat
        sessions connues et modèles écartés
        devzone agent liberer [<modèle>|--tous]
        lève un écart de modèle
AGENTEOF2
}
