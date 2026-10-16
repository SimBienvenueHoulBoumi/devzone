#!/usr/bin/env bash
# Tests fonctionnels de devzone : construit un devzone isolé, joue les
# scénarios d'un utilisateur, puis supprime tout, même en cas d'échec.
#   make test-fonctionnel     (ou bash test/fonctionnel.sh)
# Isolation : copie du dépôt dans un dossier temporaire (autre conteneur,
# autre image, autre Docker interne) et volumes propres au test
# (DEVZONE_VOLUMES). Le cluster de l'hôte n'est jamais touché : les commandes
# Kubernetes lisent DEVZONE_KUBE_SOURCE, orienté vers un fichier absent.
# Prérequis : Docker, Node (npx). Durée : 5 à 10 min (plus sans cache).
set -uo pipefail

RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVZONE_VOLUMES="devzone-test-$$"
TMP="$(mktemp -d)"
COPIE="$TMP/devzone"
DC=(npx -y @devcontainers/cli)
WS=(--workspace-folder "$COPIE")
JOURNAL="$TMP/journal.log"
reussis=0
echecs=0

nettoyer() {
    local ids image dind
    ids="$(docker ps -aq --filter "label=devcontainer.local_folder=$COPIE")"
    for id in $ids; do
        image="$(docker inspect "$id" --format '{{.Config.Image}}')"
        dind="$(docker inspect "$id" --format '{{range .Mounts}}{{if eq .Destination "/var/lib/docker"}}{{.Name}}{{end}}{{end}}')"
        docker rm -f "$id" >/dev/null
        [ -z "$dind" ] || docker volume rm "$dind" >/dev/null 2>&1 || true
        [ -z "$image" ] || docker rmi "$image" >/dev/null 2>&1 || true
    done
    local volume
    for volume in $(docker volume ls -q | grep "^${DEVZONE_VOLUMES}-" || true); do
        docker volume rm "$volume" >/dev/null 2>&1 || true
    done
    rm -rf "$TMP"
}
trap nettoyer EXIT

# Commande dans le conteneur (shell de connexion, comme un utilisateur)
dz() {
    "${DC[@]}" exec "${WS[@]}" env DEVZONE_KUBE_SOURCE=/nexiste/pas bash -lc "$1" 2>&1
}

ok() { reussis=$((reussis + 1)); echo "  ✔ $1"; }
ko() { echecs=$((echecs + 1)); echo "  ✖ $1"; printf '%s\n' "$2" | tail -5 | sed 's/^/      /'; }

# reussit <nom> <commande> [motif attendu dans la sortie]
reussit() {
    local sortie
    if sortie="$(dz "$2")" && { [ -z "${3:-}" ] || grep -qE -- "$3" <<<"$sortie"; }; then ok "$1"; else ko "$1" "$sortie"; fi
}
# echoue <nom> <commande> [motif attendu dans la sortie]
echoue() {
    local sortie
    if ! sortie="$(dz "$2")" && { [ -z "${3:-}" ] || grep -qE -- "$3" <<<"$sortie"; }; then ok "$1"; else ko "$1" "$sortie"; fi
}

demarrer() {
    if ! "${DC[@]}" up "${WS[@]}" "$@" >>"$JOURNAL" 2>&1; then
        echo "✖ démarrage du conteneur impossible ; fin du journal :"
        tail -20 "$JOURNAL"
        exit 1
    fi
}

echo "▶ Copie du dépôt et construction (volumes $DEVZONE_VOLUMES-*)"
mkdir -p "$COPIE/workspace"
(cd "$RACINE" && git ls-files -co --exclude-standard | grep -v '^workspace/' | tar -cf - -T -) | tar -xf - -C "$COPIE"
demarrer

echo "▶ Outils"
for outil in java mvn node pnpm python3 uv docker kubectl helm k9s kind gh repowarden shellcheck bats actionlint gitleaks ruff vulture pytest; do
    reussit "$outil présent" "command -v $outil"
done

echo "▶ Premier démarrage"
reussit "modules désactivés par défaut" "devzone" "ia +off"
reussit "kubernetes désactivé par défaut" "devzone" "kubernetes +off"
echoue "assistants IA absents" "command -v claude"
for message in "gh auth login -s workflow" "modules désactivés : ia kubernetes"; do
    if grep -q "$message" "$JOURNAL"; then ok "message : $message"; else ko "message : $message" "$(tail -5 "$JOURNAL")"; fi
done

echo "▶ Module ia"
reussit "activer ia" "devzone activer ia && claude --version && opencode --version" "Claude Code"
reussit "désactiver ia" "devzone desactiver ia && ! command -v claude"
echoue "module inconnu refusé" "devzone activer nexistepas" "module inconnu"

echo "▶ Module kubernetes (cluster kind, jamais celui de l'hôte)"
reussit "kind create cluster" "kind create cluster --name test"
reussit "activer kubernetes : metrics-server sur kind" "devzone activer kubernetes" "metrics-server : installé .*kind-test"
reussit "métriques disponibles" "for i in \$(seq 1 36); do kubectl --context kind-test top nodes >/dev/null 2>&1 && exit 0; sleep 5; done; exit 1"
echoue "metrics-server.sh : contexte inconnu" "bash .devcontainer/metrics-server.sh nexistepas" "contexte inconnu"
reussit "désactiver kubernetes" "devzone desactiver kubernetes" "kubernetes désactivé"
reussit "cluster kind toujours utilisable" "kubectl --context kind-test get nodes" "Ready"

echo "▶ Git et hooks repowarden"
echoue "commit sans identité refusé" "cd /tmp && rm -rf t1 && git init -q t1 && cd t1 && echo x >f && git add f && git commit -qm 'feat: x'" "tell me who you are|unable to auto-detect"
G="cd /tmp && rm -rf t2 && git init -q -b develop t2 && cd t2 && git config user.name Test && git config user.email test@example.invalid"
echoue "message non conventionnel refusé" "$G && echo a >a && git add a && git commit -m 'truc'"
reussit "message conventionnel accepté" "$G && echo a >a && git add a && git commit -m 'feat: premier fichier'"
echoue "jeton GitHub refusé (gitleaks)" "$G && echo \"T='ghp_\$(head -c 300 /dev/urandom | tr -dc A-Za-z0-9 | head -c 36)'\" >c.py && git add c.py && git commit -m 'feat: config'" "Secret"

echo "▶ Persistance"
dz "devzone activer ia >/dev/null; echo témoin >~/.config/git/temoin" >/dev/null
docker stop "$(docker ps -q --filter "label=devcontainer.local_folder=$COPIE")" >/dev/null
demarrer
reussit "redémarrage : modules gardés" "devzone" "ia +on"
reussit "redémarrage : volume gardé" "cat ~/.config/git/temoin" "témoin"
demarrer --remove-existing-container
reussit "rebuild : modules gardés" "devzone" "ia +on"
reussit "rebuild : ia réinstallé" "claude --version" "Claude Code"
reussit "rebuild : volume gardé" "cat ~/.config/git/temoin" "témoin"
reussit "rebuild : cluster kind conservé" "kind get clusters" "^test$"

echo
echo "Résultat : $reussis réussi(s), $echecs échec(s)"
[ "$echecs" -eq 0 ]
