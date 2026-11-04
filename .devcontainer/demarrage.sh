#!/usr/bin/env bash
# À chaque démarrage, dans l'ordre : identité git (déduite du compte gh),
# clusters Kubernetes, nom gitlab.localhost si le module gitlab est actif,
# relais du module postgres s'il est actif, relais de ports vers le poste,
# puis récapitulatif de ce qui reste à faire (devzone).
# Séquentiel : le récapitulatif voit l'identité tout juste posée ; l'échec
# d'une étape n'empêche pas les suivantes.
# Jamais de question (gh, kubectl et ses plugins d'authentification) : sortie
# invisible derrière make, une attente bloquerait (voir post-create.sh)
exec </dev/null
ICI="$(dirname "$0")"
bash "$ICI/git-identite.sh" || echo "démarrage : identité git non traitée (bash $ICI/git-identite.sh)"
bash "$ICI/kube-config.sh" || echo "démarrage : clusters non traités (bash $ICI/kube-config.sh)"
# Module gitlab actif : /etc/hosts est un montage Docker régénéré à chaque
# démarrage, gitlab.localhost doit être re-pose (ssh, glab et getent passent
# par le résolveur système) ; hote-poser n'échoue jamais (avertissement seul)
if bash "$ICI/devzone" actif gitlab; then
    bash "$ICI/gitlab/gitlab.sh" hote-poser || echo "démarrage : nom gitlab.localhost non posé (bash $ICI/gitlab/gitlab.sh hote-poser)"
fi
# Module postgres actif : le relais (port-forward vers 127.0.0.1:5432) ne
# survit pas à l'arrêt du conteneur, relancé ici après les clusters
if bash "$ICI/devzone" actif postgres; then
    bash "$ICI/postgres/postgres.sh" relais-lancer || echo "démarrage : relais postgres non lancé (devzone appliquer)"
fi
# Relais de ports vers le poste (#290) : l'IP du conteneur change à chaque
# démarrage, chaque relais de l'état est recréé ; un échec n'empêche rien
bash "$ICI/ports.sh" relancer || echo "démarrage : relais de ports non relancés (devzone port <n>)"
echo
bash "$ICI/devzone"
