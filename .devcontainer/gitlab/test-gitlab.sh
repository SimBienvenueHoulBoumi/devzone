#!/usr/bin/env bash
# devzone test-gitlab : essai de bout en bout du module gitlab et de la
# plateforme GitLab, dans le conteneur. Chaque étape est chronométrée ; le
# résumé final dit ✔/✖/sauté et le code de sortie n'est 0 que sans ✖.
#
# Pourquoi un script à part : la CI GitHub n'a pas les 8 Go de RAM du module
# gitlab. Cet essai rejoue donc à la main, sur le poste, ce que la CI ne peut
# pas faire, et publie éventuellement son résultat comme statut de commit.
#
# Options : --complet (désactive puis réinstalle), --statut (publie le statut
# gitlab-integration sur HEAD par gh).
# Les étapes sont appelées indirectement par lancer_etape : shellcheck ne peut
# pas le voir et les croirait inatteignables (SC2317).
# shellcheck disable=SC2317
set -uo pipefail

ICI="$(cd "$(dirname "$0")" && pwd)"
# Même racine que gitlab.sh : DEVZONE_RACINE pour les tests
RACINE="${DEVZONE_RACINE:-$(dirname "$(dirname "$ICI")")}"
GITLAB="$ICI/gitlab.sh"
SECRETS="$RACINE/workspace/.gitlab"
FICHIER_JETON="$SECRETS/root-token"
ETAT="${DEVZONE_ETAT:-$RACINE/.devzone.modules}"
HOSTS="${DEVZONE_HOSTS:-/etc/hosts}"
URL="${GITLAB_TEST_URL:-http://gitlab.localhost:8929}"
# Délai d'attente du pipeline : 600 s par défaut, court dans les tests
DELAI_PIPELINE="${GITLAB_TEST_PIPELINE:-600}"
# Réf. de la suite d'intégration repowarden (#533)
REF_REPOWARDEN="${REPOWARDEN_TEST_REF:-develop}"

# devzone lui-même : la commande du PATH (lien posé par post-create.sh), sinon
# le script du dépôt. DEVZONE_TEST_DEVZONE permet une doublure de test.
DEVZONE_BIN="${DEVZONE_TEST_DEVZONE:-}"
if [ -z "$DEVZONE_BIN" ]; then
    if command -v devzone >/dev/null 2>&1; then
        DEVZONE_BIN=devzone
    else
        DEVZONE_BIN="$RACINE/.devcontainer/devzone"
    fi
fi
# Même chemin que devzone : glab vit dans ~/.local/bin, jamais dans le PATH
GLAB="$HOME/.local/bin/glab"

COMPLET=0
STATUT=0
JETON=""
CLE_ID=""
ECHEC=0
TOTAL=0
RAISON=""
PLATEFORME_CHANGEE=0
TMP_DIRS=()
NOMS=()
SYMBOLES=()
DUREES=()
SUFFIXES=()

# Plateforme d'avant, lue dans le même fichier d'état que devzone : le trap
# doit pouvoir la remettre même si l'étape 6 échoue en cours de route.
PLATEFORME_AVANT="$(grep -E '^plateforme=' "$ETAT" 2>/dev/null | tail -1 | cut -d= -f2 || true)"
[ "$PLATEFORME_AVANT" = gitlab ] || PLATEFORME_AVANT=github
URL_AVANT="$(grep -E '^gitlab_url=' "$ETAT" 2>/dev/null | tail -1 | cut -d= -f2- || true)"

usage() {
    cat <<'USAGE'
devzone test-gitlab [--complet] [--statut]

Essai de bout en bout du module gitlab et de la plateforme GitLab.
  --complet   désactive gitlab, contrôle que rien ne reste, puis réinstalle
  --statut    publie le résultat comme statut gitlab-integration sur HEAD (gh)
USAGE
}

# Appel API GitLab : le jeton ne sort jamais dans un message ni dans un fichier
# du clone. curl le reçoit en en-tête, comme le seed de gitlab.sh.
api() {
    local methode="$1" chemin="$2"
    shift 2
    curl -sS --fail --request "$methode" --header "PRIVATE-TOKEN: ${JETON:-}" \
        "${URL}/api/v4${chemin}" "$@"
}

lire_jeton() {
    if [ ! -f "$FICHIER_JETON" ]; then
        RAISON="jeton root absent ($FICHIER_JETON) : devzone activer gitlab"
        return 1
    fi
    JETON="$(cat "$FICHIER_JETON")"
    if [ -z "$JETON" ]; then
        RAISON="jeton root vide ($FICHIER_JETON)"
        return 1
    fi
    return 0
}

# Remet la plateforme d'avant (github par défaut, ou l'instance GitLab avec son
# URL). Le trap l'appelle aussi : une étape 6 interrompue ne laisse pas la
# plateforme de l'utilisateur changée.
restaurer_plateforme() {
    if [ "$PLATEFORME_AVANT" = gitlab ] && [ -n "$URL_AVANT" ]; then
        "$DEVZONE_BIN" plateforme gitlab --url "$URL_AVANT" >/dev/null 2>&1
    else
        "$DEVZONE_BIN" plateforme github >/dev/null 2>&1
    fi
}

# Nettoyage garanti : clé SSH jetable retirée de GitLab, dossiers temporaires
# supprimés, plateforme d'avant restaurée. Même quand une étape a échoué.
nettoyer() {
    local code=$? d
    trap - EXIT
    if [ -n "${CLE_ID:-}" ]; then
        api DELETE "/user/keys/$CLE_ID" >/dev/null 2>&1 || true
    fi
    if [ "$PLATEFORME_CHANGEE" = 1 ]; then
        restaurer_plateforme || true
    fi
    for d in ${TMP_DIRS[@]+"${TMP_DIRS[@]}"}; do
        [ -n "$d" ] && rm -rf "$d"
    done
    exit "$code"
}
trap nettoyer EXIT

# ---- Les étapes, une fonction par étape ----

# 1. Module : actif, sinon activé (l'activation installe aussi si besoin).
etape_module() {
    if "$DEVZONE_BIN" actif gitlab >/dev/null 2>&1; then
        return 0
    fi
    if ! "$DEVZONE_BIN" activer gitlab >/dev/null 2>&1; then
        RAISON="devzone activer gitlab a échoué"
        return 1
    fi
    return 0
}

# 2. État : le module doit être prêt et son runner en ligne (sans runner, le
# pipeline resterait en attente).
etape_etat() {
    local etat
    etat="$(bash "$GITLAB" etat 2>&1 || true)"
    if [[ "$etat" != *"prêt"* ]]; then
        RAISON="état : ${etat:-illisible}"
        return 1
    fi
    if [[ "$etat" != *"runner en ligne"* ]]; then
        RAISON="runner hors ligne ($etat)"
        return 1
    fi
    return 0
}

# 3. Nom : ssh et glab passent par le résolveur système, pas par curl ; sans
# gitlab.localhost dans /etc/hosts, le clone SSH et glab échouent (#273).
etape_nom() {
    local hote
    hote="$(getent hosts gitlab.localhost 2>/dev/null || true)"
    case "$hote" in
        *127.0.0.1*) return 0 ;;
    esac
    RAISON="gitlab.localhost non résolu vers 127.0.0.1 (getent hosts)"
    return 1
}

# 4. Pipeline : relance celui de devzone/demo sur main et attend success.
etape_pipeline() {
    local reponse id web_url etat debut
    lire_jeton || return 1
    reponse="$(api POST "/projects/devzone%2Fdemo/pipeline" --data "ref=main" 2>/dev/null)" || {
        RAISON="création du pipeline de devzone/demo impossible"
        return 1
    }
    id="$(printf '%s' "$reponse" | jq -r '.id // empty' 2>/dev/null || true)"
    web_url="$(printf '%s' "$reponse" | jq -r '.web_url // empty' 2>/dev/null || true)"
    if [ -z "$id" ]; then
        RAISON="réponse de création du pipeline sans identifiant"
        return 1
    fi
    debut="$(date +%s)"
    while :; do
        reponse="$(api GET "/projects/devzone%2Fdemo/pipelines/$id" 2>/dev/null || true)"
        etat="$(printf '%s' "$reponse" | jq -r '.status // empty' 2>/dev/null || true)"
        case "$etat" in
            success) return 0 ;;
            failed | canceled | skipped)
                RAISON="pipeline $etat : ${web_url:-$URL/devzone/demo/-/pipelines/$id}"
                return 1
                ;;
        esac
        if [ $(( $(date +%s) - debut )) -ge "$DELAI_PIPELINE" ]; then
            RAISON="délai ${DELAI_PIPELINE} s dépassé (état ${etat:-inconnu}) : ${web_url:-$URL/devzone/demo/-/pipelines/$id}"
            return 1
        fi
        sleep 1
    done
}

# 5. Clones HTTP et SSH : clé ed25519 jetable déposée sur root, puis retirée
# par le trap. Le clone HTTP porte le jeton dans un en-tête git, jamais dans
# l'URL ni dans .git/config.
etape_clones() {
    local d pub reponse
    lire_jeton || return 1
    d="$(mktemp -d "${TMPDIR:-/tmp}/devzone-test-gitlab-clones.XXXXXX")" || {
        RAISON="dossier temporaire impossible"
        return 1
    }
    TMP_DIRS+=("$d")
    if ! ssh-keygen -q -t ed25519 -N '' -f "$d/id_ed25519" >/dev/null 2>&1; then
        RAISON="génération de la clé ed25519 impossible"
        return 1
    fi
    pub="$(cat "$d/id_ed25519.pub" 2>/dev/null || true)"
    reponse="$(api POST "/user/keys" --data-urlencode "title=devzone test-gitlab" \
        --data-urlencode "key=$pub" 2>/dev/null)" || {
        RAISON="dépôt de la clé SSH sur GitLab impossible"
        return 1
    }
    CLE_ID="$(printf '%s' "$reponse" | jq -r '.id // empty' 2>/dev/null || true)"
    if [ -z "$CLE_ID" ]; then
        RAISON="réponse de dépôt de clé sans identifiant"
        return 1
    fi
    if ! git clone -q \
        -c "core.sshCommand=ssh -i $d/id_ed25519 -o UserKnownHostsFile=$d/known_hosts -o StrictHostKeyChecking=accept-new" \
        "ssh://git@gitlab.localhost:2224/devzone/demo.git" "$d/ssh-demo" >/dev/null 2>&1; then
        RAISON="clone SSH (ssh://git@gitlab.localhost:2224/devzone/demo.git) impossible"
        return 1
    fi
    if ! git -c "http.extraHeader=PRIVATE-TOKEN: $JETON" clone -q \
        "$URL/devzone/demo.git" "$d/http-demo" >/dev/null 2>&1; then
        RAISON="clone HTTP de devzone/demo impossible"
        return 1
    fi
    if grep -qF "$JETON" "$d/http-demo/.git/config" 2>/dev/null; then
        RAISON="le jeton a été écrit dans .git/config du clone"
        return 1
    fi
    return 0
}

# 6. Plateforme : gitlab (glab clone), puis retour à la plateforme d'avant ;
# au retour à github, glab et sa configuration ne doivent plus être là.
etape_plateforme() {
    local d
    d="$(mktemp -d "${TMPDIR:-/tmp}/devzone-test-gitlab-plateforme.XXXXXX")" || {
        RAISON="dossier temporaire impossible"
        return 1
    }
    TMP_DIRS+=("$d")
    PLATEFORME_CHANGEE=1
    if ! "$DEVZONE_BIN" plateforme gitlab >/dev/null 2>&1; then
        RAISON="devzone plateforme gitlab a échoué"
        return 1
    fi
    if ! "$GLAB" repo clone devzone/demo "$d/demo" >/dev/null 2>&1; then
        RAISON="glab repo clone devzone/demo a échoué"
        return 1
    fi
    if ! restaurer_plateforme; then
        RAISON="retour à la plateforme $PLATEFORME_AVANT impossible"
        return 1
    fi
    if [ "$PLATEFORME_AVANT" = github ]; then
        if [ -e "$GLAB" ] || [ -e "$HOME/.config/glab-cli" ]; then
            RAISON="glab ou sa configuration reste après le retour à github"
            return 1
        fi
    fi
    PLATEFORME_CHANGEE=0
    return 0
}

# 7. Intégration repowarden : suite test/gitlab/ (#533) contre l'instance du
# module, avec l'URL et le jeton en variables d'environnement. Absente à la
# réf choisie → étape sautée, pas en échec.
etape_repowarden() {
    local d
    lire_jeton || return 1
    d="$(mktemp -d "${TMPDIR:-/tmp}/devzone-test-gitlab-repowarden.XXXXXX")" || {
        RAISON="dossier temporaire impossible"
        return 1
    }
    TMP_DIRS+=("$d")
    if ! git clone -q --depth 1 --branch "$REF_REPOWARDEN" \
        https://github.com/simdevWarden/repowarden.git "$d/repowarden" >/dev/null 2>&1; then
        RAISON="clone de repowarden (réf. $REF_REPOWARDEN) impossible"
        return 1
    fi
    if [ ! -d "$d/repowarden/test/gitlab" ]; then
        RAISON="test/gitlab absent à la réf. $REF_REPOWARDEN"
        return 2
    fi
    if ! command -v bats >/dev/null 2>&1; then
        RAISON="bats introuvable"
        return 1
    fi
    if ! REPOWARDEN_IT_GITLAB_URL="$URL" REPOWARDEN_IT_GITLAB_TOKEN="$JETON" \
        bats "$d/repowarden/test/gitlab/" >/dev/null 2>&1; then
        RAISON="la suite test/gitlab a échoué"
        return 1
    fi
    return 0
}

# 8. --complet : désactivation d'abord, puis contrôle qu'il ne reste ni
# cluster, ni contexte, ni secrets, ni ligne /etc/hosts. Les étapes 1 à 7
# réinstallent ensuite.
etape_complet() {
    local restes=""
    if ! "$DEVZONE_BIN" desactiver gitlab >/dev/null 2>&1; then
        restes="$restes désactivation en échec;"
    fi
    if kind get clusters 2>/dev/null | grep -qx gitlab; then
        restes="$restes cluster kind gitlab;"
    fi
    if kubectl config get-contexts -o name 2>/dev/null | grep -qx kind-gitlab; then
        restes="$restes contexte kind-gitlab;"
    fi
    if [ -e "$SECRETS" ]; then
        restes="$restes $SECRETS;"
    fi
    if grep -q '# devzone:gitlab' "$HOSTS" 2>/dev/null; then
        restes="$restes ligne /etc/hosts;"
    fi
    if [ -n "$restes" ]; then
        RAISON="reste :$restes"
        return 1
    fi
    return 0
}

# ---- Cadre commun : chronomètre, mémorise ✔/✖/sauté + raison ----

lancer_etape() {
    local nom="$1" fonction="$2" debut fin duree code symbole suffixe
    RAISON=""
    printf '▶ %s…\n' "$nom"
    debut="$(date +%s)"
    "$fonction"
    code=$?
    fin="$(date +%s)"
    duree=$((fin - debut))
    case "$code" in
        0) symbole="✔"; suffixe="" ;;
        2) symbole="–"; suffixe=" — sauté : ${RAISON:-sans raison}" ;;
        *) symbole="✖"; ECHEC=1; suffixe=" — ${RAISON:-échec}" ;;
    esac
    NOMS+=("$nom")
    SYMBOLES+=("$symbole")
    DUREES+=("$duree")
    SUFFIXES+=("$suffixe")
    printf '  %s %s (%d s)%s\n' "$symbole" "$nom" "$duree" "$suffixe"
}

# Résumé court pour le statut : jamais de jeton, une description < 140 signes.
resume_court() {
    local i ok=0 ko=0 saute=0 premier_ko=""
    for i in "${!SYMBOLES[@]}"; do
        case "${SYMBOLES[$i]}" in
            ✔) ok=$((ok + 1)) ;;
            ✖) ko=$((ko + 1)); [ -n "$premier_ko" ] || premier_ko="${NOMS[$i]}" ;;
            *) saute=$((saute + 1)) ;;
        esac
    done
    if [ "$ko" -gt 0 ]; then
        printf '%d ✔, %d ✖ (%s), %d sauté — %d s' "$ok" "$ko" "$premier_ko" "$saute" "$TOTAL"
    else
        printf '%d ✔, %d sauté — %d s' "$ok" "$saute" "$TOTAL"
    fi
}

resume() {
    local i ok=0 ko=0 saute=0
    echo
    echo "devzone test-gitlab : résumé"
    for i in "${!SYMBOLES[@]}"; do
        printf '  %s %-28s %3d s%s\n' "${SYMBOLES[$i]}" "${NOMS[$i]}" "${DUREES[$i]}" "${SUFFIXES[$i]}"
        case "${SYMBOLES[$i]}" in
            ✔) ok=$((ok + 1)) ;;
            ✖) ko=$((ko + 1)) ;;
            *) saute=$((saute + 1)) ;;
        esac
    done
    printf '  total : %d étape(s), %d s, %d ✔, %d ✖, %d sauté\n' \
        "${#NOMS[@]}" "$TOTAL" "$ok" "$ko" "$saute"
}

# --statut : publie le résultat sur le commit HEAD du dépôt courant, par l'API
# GitHub de gh (jeton du mainteneur). Refus clair si gh n'est pas connecté.
publier_statut() {
    local depot sha etat description
    if ! gh auth status >/dev/null 2>&1; then
        echo "devzone test-gitlab : gh non connecté, statut gitlab-integration non publié (gh auth login -s workflow)" >&2
        return 1
    fi
    depot="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
    if [ -z "$depot" ]; then
        echo "devzone test-gitlab : dépôt GitHub courant introuvable, statut non publié" >&2
        return 1
    fi
    sha="$(git rev-parse HEAD 2>/dev/null || true)"
    if [ -z "$sha" ]; then
        echo "devzone test-gitlab : commit HEAD introuvable, statut non publié" >&2
        return 1
    fi
    if [ "$ECHEC" -eq 0 ]; then etat=success; else etat=failure; fi
    description="$(resume_court)"
    if ! gh api -X POST "repos/$depot/statuses/$sha" \
        -f state="$etat" -f context=gitlab-integration -f description="$description" >/dev/null; then
        echo "devzone test-gitlab : publication du statut gitlab-integration impossible" >&2
        return 1
    fi
    echo "devzone test-gitlab : statut gitlab-integration ($etat) publié sur $depot@$sha"
}

# ---- Options et déroulement ----

for arg in "$@"; do
    case "$arg" in
        --complet) COMPLET=1 ;;
        --statut) STATUT=1 ;;
        -h | --help) usage; exit 0 ;;
        *)
            echo "devzone test-gitlab : option inconnue : $arg" >&2
            usage >&2
            exit 2
            ;;
    esac
done

DEBUT="$(date +%s)"

if [ "$COMPLET" = 1 ]; then
    lancer_etape "8. complet : désactivation" etape_complet
fi
lancer_etape "1. module" etape_module
lancer_etape "2. état" etape_etat
lancer_etape "3. nom d'hôte" etape_nom
lancer_etape "4. pipeline" etape_pipeline
lancer_etape "5. clones HTTP et SSH" etape_clones
lancer_etape "6. plateforme" etape_plateforme
lancer_etape "7. intégration repowarden" etape_repowarden

TOTAL=$(( $(date +%s) - DEBUT ))
resume

CODE=0
[ "$ECHEC" -eq 0 ] || CODE=1
if [ "$STATUT" = 1 ]; then
    publier_statut || CODE=1
fi
exit "$CODE"
