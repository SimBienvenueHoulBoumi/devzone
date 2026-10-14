#!/usr/bin/env bash
# Outils sans feature officielle : uv (Python), k9s (K8s), outils de repowarden
set -euo pipefail

# Volumes nommés créés en root → rendre au user vscode
sudo chown -R vscode:vscode /home/vscode/.m2 /home/vscode/.local

# uv
curl -LsSf https://astral.sh/uv/install.sh | sh

# k9s (arch détectée : arm64 sur Mac Apple Silicon, amd64 ailleurs)
ARCH="$(dpkg --print-architecture)"
curl -fsSL "https://github.com/derailed/k9s/releases/latest/download/k9s_Linux_${ARCH}.tar.gz" \
  | sudo tar -xz -C /usr/local/bin k9s

# Outils de repowarden (contrôles des commits et de la CI, mêmes versions qu'en CI)
sudo apt-get update -qq
sudo apt-get install -y -qq shellcheck bats >/dev/null

# Binaire de release : version et empreinte sha256 figées ici (pas de « latest »)
installer_binaire() { # nom url sha256
    local tmp
    tmp="$(mktemp -d)"
    curl -fsSL "$2" -o "$tmp/a.tar.gz"
    echo "$3  $tmp/a.tar.gz" | sha256sum -c --quiet
    tar -xzf "$tmp/a.tar.gz" -C "$tmp" "$1"
    sudo install -m 0755 "$tmp/$1" /usr/local/bin/"$1"
    rm -rf "$tmp"
}
case "$ARCH" in
    arm64)
        installer_binaire actionlint https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_arm64.tar.gz \
            325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6
        installer_binaire gitleaks https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_arm64.tar.gz \
            e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080 ;;
    amd64)
        installer_binaire actionlint https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_amd64.tar.gz \
            8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8
        installer_binaire gitleaks https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_x64.tar.gz \
            551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb ;;
esac

# Python : formatage et code mort (repowarden code-mort a besoin des deux)
"$HOME/.local/bin/uv" tool install ruff
"$HOME/.local/bin/uv" tool install vulture

# repowarden : hooks actifs pour tous les projets du workspace
npm install -g repowarden
repowarden install --global --lang fr

echo "devzone prêt : java $(java -version 2>&1 | head -1 | cut -d'"' -f2), node $(node -v), python $(python3 --version | cut -d' ' -f2)"
