#!/usr/bin/env bash
# À chaque démarrage, dans l'ordre : relais du socket Docker (#293), identité git
# (déduite du compte gh), clusters Kubernetes, nom gitlab.localhost et relais
# 8929/2224 du module gitlab s'il est actif, relais des modules postgres et
# argocd s'ils sont actifs, relais de ports vers le poste, identifiants
# regroupés (.password), puis
# récapitulatif de ce qui reste à faire (devzone).
# Séquentiel : le récapitulatif voit l'identité tout juste posée ; l'échec
# d'une étape n'empêche pas les suivantes.
# Jamais de question (gh, kubectl et ses plugins d'authentification) : sortie
# invisible derrière make, une attente bloquerait (voir post-create.sh)
exec </dev/null
ICI="$(dirname "$0")"
# Relais du socket Docker d'abord (#293) : sans lui, les docker exec longs
# (kind, modules) sont coupés au bout de 0,5 s sous Docker Desktop
DEVZONE_RELAIS_REEL=oui bash "$ICI/docker-relay.sh" || echo "démarrage : relais Docker non corrigé (devzone repair)"
bash "$ICI/git-identite.sh" || echo "démarrage : identité git non traitée (devzone start)"
bash "$ICI/kube-config.sh" || echo "démarrage : clusters non traités (devzone start)"
# Jeton du compte Kubernetes limité (#430) : 24 h, renouvelé à chaque
# démarrage ; compte posé au passage s'il manque. Sans cluster des services
# choisi, rien à faire
bash "$ICI/kube-account.sh" jeton || echo "démarrage : jeton du compte kubernetes non renouvelé (devzone repair)"
# Module gitlab actif : /etc/hosts est un montage Docker régénéré à chaque
# démarrage, gitlab.localhost doit être re-pose (ssh, glab et getent passent
# par le résolveur système) ; hote-poser n'échoue jamais (avertissement seul)
if bash "$ICI/devzone" is-enabled gitlab; then
    bash "$ICI/gitlab/gitlab.sh" hote-poser || echo "démarrage : nom gitlab.localhost non posé (devzone repair)"
    # Relais TCP 8929/2224 : curl et git en HTTP passent par la boucle locale
    # pour *.localhost, le relais doit être relancé après chaque démarrage
    bash "$ICI/gitlab/gitlab.sh" relay-start || echo "démarrage : relais gitlab non lancé (devzone repair)"
fi
# Module postgres actif : le relais (port-forward vers 127.0.0.1:5432) ne
# survit pas à l'arrêt du conteneur, relancé ici après les clusters
if bash "$ICI/devzone" is-enabled postgres; then
    bash "$ICI/postgres/postgres.sh" relay-start || echo "démarrage : relais postgres non lancé (devzone repair)"
fi
# Module argocd actif : relais (port-forward vers 127.0.0.1:8443), relancé
# après les clusters comme celui de postgres
if bash "$ICI/devzone" is-enabled argocd; then
    bash "$ICI/argocd/argocd.sh" relay-start || echo "démarrage : relais argocd non lancé (devzone repair)"
fi
# Module mysql actif : le relais 127.0.0.1:3306, relancé comme celui de
# postgres après chaque démarrage
if bash "$ICI/devzone" is-enabled mysql; then
    bash "$ICI/catalog/mysql/mysql.sh" relay-start || echo "démarrage : relais mysql non lancé (devzone repair)"
fi
# Relais de ports vers le poste (#290) : l'IP du conteneur change à chaque
# démarrage, chaque relais de l'état est recréé ; un échec n'empêche rien
bash "$ICI/ports.sh" restart || echo "démarrage : relais de ports non relancés (devzone repair)"
# Veilleur de ports automatiques vers le poste (#394, garde #293) : une seule
# instance en arrière-plan, contexte réel posé pour cet appel seulement.
# Kubernetes workspace (#517): no watcher, ports go through devzone workspace ports
if [ "${DEVZONE_WORKSPACE:-}" != kubernetes ]; then
    DEVZONE_PORTS_AUTO_REEL=oui bash "$ICI/ports-auto.sh" demarrer >/dev/null 2>&1 || echo "démarrage : veilleur de ports auto non lancé (devzone repair)"
fi
# Catalogue d'applications : une ligne <app>=off par application absente,
# écrite une fois, jamais une ligne existante modifiée (#414)
bash "$ICI/catalog.sh" sync || echo "démarrage : catalogue non synchronisé (devzone repair)"
# Veilleur du catalogue : réapplique à chaud dès que .devzone.modules change
DEVZONE_CATALOGUE_REEL=oui bash "$ICI/catalog/catalog-watcher.sh" demarrer >/dev/null 2>&1 || echo "démarrage : veilleur catalogue non lancé (devzone repair)"

# Vue regroupée des identifiants (#332), regénérée à chaque démarrage ; un
# échec n'empêche rien et le contenu n'est jamais affiché
bash "$ICI/password.sh" regenerer || echo "démarrage : identifiants regroupés non mis à jour (devzone repair)"
echo
bash "$ICI/devzone"
