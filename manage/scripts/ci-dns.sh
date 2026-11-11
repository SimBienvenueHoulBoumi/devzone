#!/usr/bin/env bash
# DNS publics pour le Docker d'un runner GitHub Actions (#468) : le DNS des
# runners ubuntu échoue parfois à résoudre archive.ubuntu.com pendant la
# construction du conteneur. Ajoute 1.1.1.1 et 8.8.8.8 à daemon.json (les clés
# existantes sont gardées), redémarre Docker et attend qu'il réponde.
# Garde-fou : refuse hors CI, jamais lancé sur un poste.
set -euo pipefail

if [ "${CI:-}" != true ] || [ "${GITHUB_ACTIONS:-}" != true ]; then
    echo "ci-dns.sh : réservé à GitHub Actions (CI et GITHUB_ACTIONS doivent valoir true)" >&2
    exit 1
fi

# Chemin surchargeable pour les tests
daemon="${DEVZONE_CI_DOCKER_DAEMON:-/etc/docker/daemon.json}"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# Fusion avec le fichier existant, ou création s'il n'existe pas
if [ -s "$daemon" ]; then
    jq '. + {"dns": ["1.1.1.1", "8.8.8.8"]}' "$daemon" >"$tmp"
else
    jq -n '{"dns": ["1.1.1.1", "8.8.8.8"]}' >"$tmp"
fi
sudo mkdir -p "$(dirname "$daemon")"
sudo cp "$tmp" "$daemon"

sudo systemctl restart docker

# Attente de Docker : 20 secondes au plus
for _ in $(seq 1 20); do
    if docker info >/dev/null 2>&1; then
        exit 0
    fi
    sleep 1
done
echo "ci-dns.sh : Docker ne répond pas après 20 s" >&2
exit 1
