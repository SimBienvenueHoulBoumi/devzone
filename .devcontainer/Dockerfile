# Image de base de devzone : outils sans feature officielle, versions figées.
# Java, Node, Python, Docker, kubectl, helm et gh sont ajoutés par les features
# de devcontainer.json, par-dessus cette image.

# uv : binaire de l'image officielle (pas de script curl | sh)
ARG UV_VERSION=0.13.1
FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv

FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

# Versions : pour mettre à jour, changer la version ET l'empreinte sha256,
# puis Rebuild Container
ARG K9S_VERSION=0.51.0
ARG ACTIONLINT_VERSION=1.7.12
ARG GITLEAKS_VERSION=8.30.1
ARG KIND_VERSION=0.33.0
ARG RUFF_VERSION=0.17.0
ARG VULTURE_VERSION=2.16

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Contrôles shell de repowarden
RUN apt-get update \
    && apt-get install -y --no-install-recommends shellcheck bats \
    && rm -rf /var/lib/apt/lists/*

# k9s, actionlint (mêmes versions que la CI de repowarden), gitleaks, kind :
# installer <nom> <url> <sha256> : empreinte vérifiée avant d'installer quoi que ce soit dans /usr/local/bin
# (kind est un binaire seul, sans archive : installé à part, même vérification)
RUN set -eu; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
        arm64) gl_arch=arm64; \
               k9s_sha=3ee05c82e5f9198928a4e86133608ba6a2c10a2244d6a7789e820f78319d640c; \
               al_sha=325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6; \
               gl_sha=e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080; \
               kind_sha=20022bee6cfcd5086cb7234d218e3454e6090022f2a8f55d1fa7fcf42c3867a2 ;; \
        amd64) gl_arch=x64; \
               k9s_sha=c3752ad51a5a4015a113819c4eeb6e55a4d0e4b8e652494797532f6fc8161dd7; \
               al_sha=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8; \
               gl_sha=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb; \
               kind_sha=aee6151561422756b764a4ae28e7f44cda5af5a9eead3cc9985112b1de8d8e0d ;; \
        *) echo "Architecture non prise en charge : $arch" >&2; exit 1 ;; \
    esac; \
    installer() { \
        tmp="$(mktemp -d)"; \
        curl -fsSL "$2" -o "$tmp/a.tar.gz"; \
        echo "$3  $tmp/a.tar.gz" | sha256sum -c --quiet; \
        tar -xzf "$tmp/a.tar.gz" -C "$tmp" "$1"; \
        install -m 0755 "$tmp/$1" /usr/local/bin/"$1"; \
        rm -rf "$tmp"; \
    }; \
    installer k9s "https://github.com/derailed/k9s/releases/download/v${K9S_VERSION}/k9s_Linux_${arch}.tar.gz" "$k9s_sha"; \
    installer actionlint "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_${arch}.tar.gz" "$al_sha"; \
    installer gitleaks "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_${gl_arch}.tar.gz" "$gl_sha"; \
    curl -fsSL "https://github.com/kubernetes-sigs/kind/releases/download/v${KIND_VERSION}/kind-linux-${arch}" -o /tmp/kind; \
    echo "$kind_sha  /tmp/kind" | sha256sum -c --quiet; \
    install -m 0755 /tmp/kind /usr/local/bin/kind; \
    rm -f /tmp/kind

COPY --from=uv /uv /uvx /usr/local/bin/

# ruff et vulture (repowarden code-mort a besoin des deux), installés pour
# tous les utilisateurs, avec un Python géré par uv hors du home
# (variables limitées au build : uv tool install reste dans ~/.local pour vscode)
RUN export UV_TOOL_DIR=/opt/uv/tools UV_TOOL_BIN_DIR=/usr/local/bin \
        UV_PYTHON_INSTALL_DIR=/opt/uv/python \
    && uv tool install "ruff==${RUFF_VERSION}" \
    && uv tool install "vulture==${VULTURE_VERSION}"
