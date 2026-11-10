#!/usr/bin/env bash
# Docker du poste non partagé (option docker-hote=off, #432). post-create.sh
# installe ce script comme commande docker quand la feature
# docker-outside-of-docker est absente : au lieu d'un « command not found »,
# un message clair renvoie au workspace Kubernetes.
cat >&2 <<'MESSAGE'
✖ Docker du poste non partagé (option docker-hote=off) : docker n'est pas disponible ici.
  Pour lancer des conteneurs, utilise le workspace Kubernetes : devzone workspace
  (docker et Testcontainers y parlent à kubedock, les images sont construites par BuildKit).
  Pour partager le socket Docker de l'hôte : devzone activer docker-hote, puis make rebuild sur le poste.
MESSAGE
exit 1
