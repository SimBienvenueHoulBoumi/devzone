#!/usr/bin/env bash
# Lance le conteneur sur l'hôte, sans jamais rester muet :
#   bash core/scripts/lancer.sh up [dossier]        (make up)
#   bash core/scripts/lancer.sh rebuild [dossier]   (make rebuild : reconstruit de zéro)
# Sortie complète du CLI devcontainer dans <dossier>/.devzone.log ; dans le
# terminal : les étapes clés, un signe de vie au plus toutes les
# DEVZONE_SIGNE_DE_VIE secondes (30), et une question posée dans le conteneur
# (dernière ligne du journal restée sans réponse DEVZONE_ATTENTE_QUESTION
# secondes, 20) est affichée et le lancement arrêté : personne ne peut y
# répondre (le CLI tourne sans entrée), attendre serait bloquer indéfiniment.
# Portable : bash 3.2 (macOS) et Linux.
set -uo pipefail

mode="${1:-}"
DOSSIER="${2:-$PWD}"
case "$mode" in
    up) options=() fini="devzone lancé" ;;
    rebuild) options=(--remove-existing-container) fini="devzone reconstruit" ;;
    *)
        echo "usage : bash core/scripts/lancer.sh up|rebuild [dossier]" >&2
        exit 2
        ;;
esac
LOG="$DOSSIER/.devzone.log"
VIE="${DEVZONE_SIGNE_DE_VIE:-30}"
QUESTION="${DEVZONE_ATTENTE_QUESTION:-20}"
ESC="$(printf '\033')"

# Ligne du journal lisible : sans codes de couleur ni retours chariot
propre() { sed "s/${ESC}\[[0-9;?]*[A-Za-z]//g" | tr -d '\r'; }
# Dernière ligne non vide du journal, raccourcie
derniere() { tail -c 2000 "$LOG" | propre | grep -v '^[[:space:]]*$' | tail -1 | cut -c1-110; }

# Question en attente : dernière ligne inachevée (sans retour à la ligne,
# comme une invite) qui finit par [o/N], [y/N], ? ou une demande de mot de passe
motif='(\[[^]]*/[^]]*\]|\?|[Pp]assword[^:]*:|[Mm]ot de passe[^:]*:)[[:space:]]*$'
question() {
    local ligne
    # Dernier octet : vide après $( ) si c'est un retour à la ligne
    [ -n "$(tail -c 1 "$LOG")" ] || return 1
    ligne="$(tail -c 600 "$LOG" | propre | tail -1)"
    [[ "$ligne" =~ $motif ]] || return 1
    printf '%s\n' "$ligne" | cut -c1-200
}

# Étapes clés, chacune affichée une fois ; état de devzone recopié tel quel
vus=" "
lues=0
etapes() {
    local total ligne
    total="$(wc -l <"$LOG" | tr -d ' ')"
    [ "$total" -gt "$lues" ] || return 0
    while IFS= read -r ligne; do
        case "$ligne" in
            *"Start: Run: docker buildx build"* | *"Start: Run: docker build"*) annoncer image "Construction de l'image (plusieurs minutes la première fois)" ;;
            *"Start: Run: docker run"*) annoncer conteneur "Création du conteneur" ;;
            *"Running the postCreateCommand"*) annoncer postcreate "Installation dans le conteneur (repowarden, modules)" ;;
            *"Running the postStartCommand"*) annoncer poststart "Démarrage (identité git, clusters, état)" ;;
            "devzone prêt"* | "devzone : "* | "  ✔ "* | "  ✖ "* | "  ○ "* | "  ⚠ "* | "                    "[!\ ]* | "git-identite : "* | "kube-config : "* | "metrics-server : "*)
                echo "  $ligne"
                derniere_annonce="$(date +%s)"
                ;;
        esac
    done < <(sed -n "$((lues + 1)),${total}p" "$LOG" | propre)
    lues="$total"
}
annoncer() {
    case "$vus" in *" $1 "*) return 0 ;; esac
    vus="$vus$1 "
    echo "▶ $2"
    derniere_annonce="$(date +%s)"
}

arreter() {
    [ -n "${pid:-}" ] || return 0
    pkill -TERM -P "$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    pid=""
}
trap 'arreter; echo; echo "interrompu — journal : .devzone.log"; exit 130' INT TERM

: >"$LOG"
debut="$(date +%s)"
derniere_annonce="$debut"
echo "▶ Lancement de devzone (journal complet : .devzone.log)"
# Entrée vide : le CLI ne relaie rien ; une question posée dans le conteneur
# resterait sans réponse, d'où sa détection ci-dessous
npx -y @devcontainers/cli up --workspace-folder "$DOSSIER" ${options[@]+"${options[@]}"} </dev/null >"$LOG" 2>&1 &
pid=$!

taille=0
calme=0
while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    t="$(wc -c <"$LOG" | tr -d ' ')"
    if [ "$t" != "$taille" ]; then
        taille="$t"
        calme=0
        etapes
    else
        calme=$((calme + 1))
    fi
    if [ "$calme" -ge "$QUESTION" ] && q="$(question)"; then
        arreter
        echo "✖ Une étape du conteneur pose une question et attend une réponse (journal immobile depuis $calme s) :" >&2
        echo "    $q" >&2
        echo "  Personne ne peut y répondre ici : lancement arrêté au lieu d'attendre indéfiniment." >&2
        echo "  Journal complet : .devzone.log ; signale-le : https://github.com/SimBienvenueHoulBoumi/devzone/issues" >&2
        echo "  Le conteneur est peut-être incomplet : make rebuild pour repartir de zéro." >&2
        exit 1
    fi
    maintenant="$(date +%s)"
    if [ $((maintenant - derniere_annonce)) -ge "$VIE" ]; then
        ecoule=$((maintenant - debut))
        info="en cours depuis $((ecoule / 60)) min $((ecoule % 60)) s"
        [ "$calme" -lt "$VIE" ] || info="$info, aucune nouvelle ligne depuis $calme s"
        echo "  … $info : $(derniere)"
        derniere_annonce="$maintenant"
    fi
done
wait "$pid"
code=$?
pid=""
etapes
if [ "$code" -eq 0 ]; then
    echo "$fini"
else
    tail -15 "$LOG" | propre
    echo "échec — log complet : .devzone.log"
    exit 1
fi
