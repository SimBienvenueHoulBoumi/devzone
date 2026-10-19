#!/usr/bin/env bash
# Tests de la CLI de devzone dans un vrai terminal (pseudo-terminal), comme un
# humain : chaque commande a un délai maximal ; une commande qui attend une
# entrée au lieu de finir échoue (« attend une entrée »). Ticket #109.
#   make test-cli     (ou bash test/cli-terminal.sh)
# Couvre : cibles make (help, up, shell, status, stop, down, rebuild,
# desinstaller), commande npm (bin/devzone <dossier>, desinstaller, --version,
# --help), commande devzone du conteneur (état, modules, module inconnu),
# scripts de démarrage (post-create.sh, demarrage.sh).
# Isolation, comme fonctionnel.sh : devzone créé dans un dossier temporaire
# (autre conteneur, autre image, autre Docker interne), volumes propres au
# test (DEVZONE_VOLUMES), tout supprimé à la fin même en cas d'échec. Les
# clusters de l'hôte ne sont jamais touchés : KUBECONFIG vide sur l'hôte,
# DEVZONE_KUBE_SOURCE vers un fichier absent dans le conteneur, module
# kubernetes désactivé avant chaque démarrage.
# Prérequis : Docker, Node (npx), Python 3. Durée : 10 à 15 min.
set -uo pipefail

RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVZONE_VOLUMES="devzone-test-cli-$$"
# Désinstallation : aucun cluster de l'hôte examiné
export KUBECONFIG=/nexiste/pas
# Chemin physique : make (CURDIR) voit /private/var/… sous macOS, pas /var/…
TMP="$(cd "$(mktemp -d)" && pwd -P)"
# Nommé autrement que « devzone » (npx devzone <dossier>)
COPIE="$TMP/mon-devzone-cli"
TERMINAL=(python3 -I "$RACINE/test/terminal.py")
DC=(npx -y @devcontainers/cli)
reussis=0
echecs=0

nettoyer() {
    local ids id image dind volume
    ids="$(docker ps -aq --filter "label=devcontainer.local_folder=$COPIE")"
    for id in $ids; do
        image="$(docker inspect "$id" --format '{{.Config.Image}}')"
        dind="$(docker inspect "$id" --format '{{range .Mounts}}{{if eq .Destination "/var/lib/docker"}}{{.Name}}{{end}}{{end}}')"
        docker rm -f "$id" >/dev/null
        [ -z "$dind" ] || docker volume rm "$dind" >/dev/null 2>&1 || true
        [ -z "$image" ] || docker rmi "$image" >/dev/null 2>&1 || true
    done
    # Après make down : image et Docker interne notés dans .devzone.etat
    if [ -f "$COPIE/.devzone.etat" ]; then
        image="$(sed -n 's/^IMAGE=//p' "$COPIE/.devzone.etat")"
        dind="$(sed -n 's/^DIND=//p' "$COPIE/.devzone.etat")"
        [ -z "$dind" ] || docker volume rm "$dind" >/dev/null 2>&1 || true
        [ -z "$image" ] || docker rmi "$image" >/dev/null 2>&1 || true
    fi
    for volume in $(docker volume ls -q | grep "^${DEVZONE_VOLUMES}-" || true); do
        docker volume rm "$volume" >/dev/null 2>&1 || true
    done
    rm -rf "$TMP"
}
trap nettoyer EXIT

ok() { reussis=$((reussis + 1)); echo "  ✔ $1"; }
ko() { echecs=$((echecs + 1)); echo "  ✖ $1"; printf '%s\n' "$2" | tail -8 | sed 's/^/      /'; }

ESC="$(printf '\033')"
# humain <nom> <délai s> <code attendu> <motif attendu dans la sortie, ou "">
#        [--envoyer MOTIF TEXTE]... -- commande…
# Lance la commande sous terminal ; SORTIE garde sa sortie (sans couleurs)
humain() {
    local nom="$1" delai="$2" attendu="$3" motif="$4" code
    shift 4
    SORTIE="$("${TERMINAL[@]}" "$delai" "$@" 2>&1)"
    code=$?
    SORTIE="$(printf '%s\n' "$SORTIE" | sed "s/${ESC}\[[0-9;?]*[A-Za-z]//g" | tr -d '\r')"
    if [ "$code" -eq 124 ]; then
        ko "$nom : attend une entrée (délai de $delai s dépassé)" "$SORTIE"
    elif [ "$code" -eq "$attendu" ] && { [ -z "$motif" ] || grep -qE -- "$motif" <<<"$SORTIE"; }; then
        ok "$nom"
    else
        ko "$nom (code $code, attendu $attendu ; motif : $motif)" "$SORTIE"
    fi
}
# Commande du conteneur tapée dans un terminal (devcontainer exec, avec tty)
conteneur() {
    local nom="$1" delai="$2" attendu="$3" motif="$4"
    humain "$nom" "$delai" "$attendu" "$motif" -- "${DC[@]}" exec --workspace-folder "$COPIE" \
        env DEVZONE_KUBE_SOURCE=/nexiste/pas bash -lc "$5"
}
# Cible make lancée dans le dossier du devzone
mk() {
    local nom="$1" delai="$2" attendu="$3" motif="$4"
    shift 4
    humain "make $nom" "$delai" "$attendu" "$motif" "$@" -- make -C "$COPIE" "$nom"
}
# verifier <nom> commande… : réussi si la commande réussit (sinon SORTIE affichée)
verifier() {
    local nom="$1"
    shift
    if "$@"; then ok "$nom"; else ko "$nom" "$SORTIE"; fi
}
volumes() { docker volume ls -q | grep -c "^${DEVZONE_VOLUMES}-" || true; }

echo "▶ Sans conteneur (volumes $DEVZONE_VOLUMES-*)"
humain "make help" 30 0 "make up .*Lance le conteneur" -- make -C "$RACINE" help
humain "devzone --version" 30 0 "^$(node -p "require('$RACINE/package.json').version")$" -- bash "$RACINE/bin/devzone" --version
humain "devzone --help" 30 0 "devzone <dossier>" -- bash "$RACINE/bin/devzone" --help
cd "$TMP" || exit 1
humain "devzone desinstaller hors d'un dossier devzone : refusé" 30 1 "dossier devzone" -- bash "$RACINE/bin/devzone" desinstaller
# Question posée pendant le lancement (CLI devcontainer simulé) : make up
# doit la montrer et s'arrêter, pas attendre en silence
FAUX="$TMP/faux-devzone"
DEVZONE_SANS_DEMARRER=1 bash "$RACINE/bin/devzone" "$FAUX" >/dev/null
mkdir -p "$TMP/faux-bin"
printf '#!/usr/bin/env bash\nprintf "Running the postCreateCommand from devcontainer.json...\\r\\nConfigurer les bots de ce dépôt ? [o/N] "\nsleep 600\n' >"$TMP/faux-bin/npx"
chmod +x "$TMP/faux-bin/npx"
# (code 2 : celui de make quand la recette échoue)
humain "make up : question dans le conteneur signalée au lieu d'attendre" 90 2 "pose une question" \
    -- env PATH="$TMP/faux-bin:$PATH" DEVZONE_ATTENTE_QUESTION=5 make -C "$FAUX" up

echo "▶ Création et lancement : devzone <dossier> (npm)"
humain "devzone <dossier> : créé et lancé, avancement affiché" 1800 0 "▶ Installation dans le conteneur" -- bash "$RACINE/bin/devzone" "$COPIE"
if ! grep -q "devzone lancé" <<<"$SORTIE" || [ -z "$(docker ps -q --filter "label=devcontainer.local_folder=$COPIE")" ]; then
    echo "✖ devzone non lancé : suite arrêtée"
    exit 1
fi
mk status 60 0 "^Up "
mk shell 180 0 "○ module ia" --envoyer '\$ ' $'devzone\nexit\n'

echo "▶ Commande devzone du conteneur"
conteneur "devzone : état" 60 0 "○ module kubernetes" "devzone"
conteneur "devzone --help" 60 0 "devzone activer <module>" "devzone --help"
conteneur "devzone activer ia" 600 0 "ia actif" "devzone activer ia"
conteneur "devzone desactiver ia" 300 0 "ia désactivé" "devzone desactiver ia"
conteneur "devzone activer kubernetes (aucun cluster de l'hôte)" 180 0 "aucun cluster joignable" "devzone activer kubernetes"
conteneur "devzone desactiver kubernetes" 60 0 "kubernetes désactivé" "devzone desactiver kubernetes"
conteneur "devzone activer <module inconnu> : refusé" 60 1 "module inconnu" "devzone activer nexistepas"
conteneur "devzone <commande inconnue> : refusée" 60 1 "commande inconnue" "devzone nexistepas"

echo "▶ Scripts de démarrage, sous terminal"
conteneur "demarrage.sh : sans question" 180 0 "devzone : état" "bash .devcontainer/demarrage.sh"
# Conditions de make rebuild figé : dépôt GitHub, gh connecté et administrateur
# (simulé) ; repowarden install proposait alors les bots et attendait
git -C "$COPIE" init -q
git -C "$COPIE" remote add origin https://github.com/exemple/mon-devzone.git
FAUX_GH='mkdir -p /tmp/faux && printf "%s\n" "#!/bin/sh" "case \"\$*\" in" "\"auth status\"*) exit 0 ;;" "\"repo view\"*) echo exemple/mon-devzone ;;" "*permissions.admin*) echo true ;;" "esac" >/tmp/faux/gh && chmod +x /tmp/faux/gh'
conteneur "post-create.sh : sans question (dépôt GitHub, gh administrateur)" 600 0 "devzone prêt" \
    "$FAUX_GH && PATH=/tmp/faux:\$PATH bash .devcontainer/post-create.sh"
# Scénario réel atteint : repowarden aurait posé la question avec un terminal
verifier "post-create.sh : bots proposés plus tard, sans attendre" grep -q "pas de terminal pour répondre" <<<"$SORTIE"
rm -rf "$COPIE/.git"

echo "▶ Arrêt, redémarrage, reconstruction"
mk stop 120 0 "devzone arrêté"
mk status 60 0 "^Exited"
mk up 600 0 "devzone lancé"
verifier "make up : avancement affiché" grep -q "▶ Démarrage" <<<"$SORTIE"
mk rebuild 1800 0 "devzone reconstruit"
verifier "make rebuild : avancement affiché" grep -q "▶ Installation dans le conteneur" <<<"$SORTIE"
mk down 120 0 "devzone supprimé"
mk status 60 0 "aucun conteneur"

echo "▶ Désinstallation, confirmation tapée"
avant="$(volumes)"
mk desinstaller 300 0 "Abandon" --envoyer 'Taper oui' $'non\n'
SORTIE="volumes : $avant → $(volumes)"
verifier "réponse non : rien supprimé" test "$(volumes)" = "$avant" -a "$avant" -gt 0
cd "$COPIE" || exit 1
humain "devzone desinstaller : réponse oui" 300 0 "volume supprimé" --envoyer 'Taper oui' $'oui\n' -- bash "$RACINE/bin/devzone" desinstaller
cd "$RACINE" || exit 1
SORTIE="volumes restants : $(volumes)"
verifier "réponse oui : volumes supprimés" test "$(volumes)" = 0

echo
echo "Résultat : $reussis réussi(s), $echecs échec(s)"
[ "$echecs" -eq 0 ]
