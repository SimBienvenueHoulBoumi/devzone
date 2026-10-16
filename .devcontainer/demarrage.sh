#!/usr/bin/env bash
# À chaque démarrage, dans l'ordre : identité git (déduite du compte gh),
# clusters Kubernetes, puis récapitulatif de ce qui reste à faire (devzone).
# Séquentiel : le récapitulatif voit l'identité tout juste posée ; l'échec
# d'une étape n'empêche pas les suivantes.
ICI="$(dirname "$0")"
bash "$ICI/git-identite.sh" || echo "démarrage : identité git non traitée (bash $ICI/git-identite.sh)"
bash "$ICI/kube-config.sh" || echo "démarrage : clusters non traités (bash $ICI/kube-config.sh)"
echo
bash "$ICI/devzone"
