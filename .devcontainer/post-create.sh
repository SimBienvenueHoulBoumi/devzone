#!/usr/bin/env bash
# Outils sans feature officielle : uv (Python), k9s (K8s), outils de repowarden
set -euo pipefail

# Volumes nommés créés en root → rendre au user vscode
sudo chown -R vscode:vscode /home/vscode/.m2 /home/vscode/.local

# Binaire de release : version et empreinte sha256 figées ici (pas de « latest »),
# vérifiées avant d'installer quoi que ce soit dans /usr/local/bin
installer_binaire() { # nom url sha256
    local tmp
    tmp="$(mktemp -d)"
    curl -fsSL "$2" -o "$tmp/a.tar.gz"
    echo "$3  $tmp/a.tar.gz" | sha256sum -c --quiet
    tar -xzf "$tmp/a.tar.gz" -C "$tmp" "$1"
    sudo install -m 0755 "$tmp/$1" /usr/local/bin/"$1"
    rm -rf "$tmp"
}

# Architecture : arm64 sur Mac Apple Silicon, amd64 ailleurs
ARCH="$(dpkg --print-architecture)"

# uv (installateur officiel, sans droits root)
curl -LsSf https://astral.sh/uv/install.sh | sh

# k9s, actionlint (mêmes versions que la CI de repowarden), gitleaks
case "$ARCH" in
    arm64)
        installer_binaire k9s https://github.com/derailed/k9s/releases/download/v0.51.0/k9s_Linux_arm64.tar.gz \
            3ee05c82e5f9198928a4e86133608ba6a2c10a2244d6a7789e820f78319d640c
        installer_binaire actionlint https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_arm64.tar.gz \
            325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6
        installer_binaire gitleaks https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_arm64.tar.gz \
            e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080 ;;
    amd64)
        installer_binaire k9s https://github.com/derailed/k9s/releases/download/v0.51.0/k9s_Linux_amd64.tar.gz \
            c3752ad51a5a4015a113819c4eeb6e55a4d0e4b8e652494797532f6fc8161dd7
        installer_binaire actionlint https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_amd64.tar.gz \
            8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8
        installer_binaire gitleaks https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_x64.tar.gz \
            551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb ;;
    *)
        echo "Architecture non prise en charge : $ARCH" >&2
        exit 1 ;;
esac

# Contrôles shell de repowarden
sudo apt-get update -qq
sudo apt-get install -y -qq shellcheck bats >/dev/null

# Python : formatage et code mort (repowarden code-mort a besoin des deux)
"$HOME/.local/bin/uv" tool install ruff
"$HOME/.local/bin/uv" tool install vulture

# repowarden, version figée (il installe des hooks git globaux) ; mettre à jour
# en changeant la version ici, puis Rebuild Container
npm install -g repowarden@4.7.1
repowarden install --global --lang fr

echo "devzone prêt : java $(java -version 2>&1 | head -1 | cut -d'"' -f2), node $(node -v), python $(python3 --version | cut -d' ' -f2), repowarden $(repowarden --version)"
