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
DEVZONE_RELAIS_REEL=oui bash "$ICI/docker-relais.sh" || echo "démarrage : relais Docker non corrigé (devzone reparer)"
bash "$ICI/git-identite.sh" || echo "démarrage : identité git non traitée (devzone demarrer)"
bash "$ICI/kube-config.sh" || echo "démarrage : clusters non traités (devzone demarrer)"
# Module gitlab actif : /etc/hosts est un montage Docker régénéré à chaque
# démarrage, gitlab.localhost doit être re-pose (ssh, glab et getent passent
# par le résolveur système) ; hote-poser n'échoue jamais (avertissement seul)
if bash "$ICI/devzone" actif gitlab; then
    bash "$ICI/gitlab/gitlab.sh" hote-poser || echo "démarrage : nom gitlab.localhost non posé (devzone reparer)"
    # Relais TCP 8929/2224 : curl et git en HTTP passent par la boucle locale
    # pour *.localhost, le relais doit être relancé après chaque démarrage
    bash "$ICI/gitlab/gitlab.sh" relais-lancer || echo "démarrage : relais gitlab non lancé (devzone reparer)"
fi
# Module postgres actif : le relais (port-forward vers 127.0.0.1:5432) ne
# survit pas à l'arrêt du conteneur, relancé ici après les clusters
if bash "$ICI/devzone" actif postgres; then
    bash "$ICI/postgres/postgres.sh" relais-lancer || echo "démarrage : relais postgres non lancé (devzone reparer)"
fi
# Module argocd actif : relais (port-forward vers 127.0.0.1:8443), relancé
# après les clusters comme celui de postgres
if bash "$ICI/devzone" actif argocd; then
    bash "$ICI/argocd/argocd.sh" relais-lancer || echo "démarrage : relais argocd non lancé (devzone reparer)"
fi
# Relais de ports vers le poste (#290) : l'IP du conteneur change à chaque
# démarrage, chaque relais de l'état est recréé ; un échec n'empêche rien
bash "$ICI/ports.sh" relancer || echo "démarrage : relais de ports non relancés (devzone reparer)"
# Veilleur de ports automatiques vers le poste (#394, garde #293) : une seule
# instance en arrière-plan, contexte réel posé pour cet appel seulement
DEVZONE_PORTS_AUTO_REEL=oui bash "$ICI/ports-auto.sh" demarrer >/dev/null 2>&1 || echo "démarrage : veilleur de ports auto non lancé (devzone reparer)"

# Vue regroupée des identifiants (#332), regénérée à chaque démarrage ; un
# échec n'empêche rien et le contenu n'est jamais affiché
bash "$ICI/password.sh" regenerer || echo "démarrage : identifiants regroupés non mis à jour (devzone reparer)"
echo
bash "$ICI/devzone"
