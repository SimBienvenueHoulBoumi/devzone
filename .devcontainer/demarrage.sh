#!/usr/bin/env bash
# À chaque démarrage, dans l'ordre : identité git (déduite du compte gh),
# clusters Kubernetes, nom gitlab.localhost si le module gitlab est actif,
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
echo
bash "$ICI/devzone"
