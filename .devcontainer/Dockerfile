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
ARG KUBECTX_VERSION=0.11.0
ARG RUFF_VERSION=0.17.0
ARG VULTURE_VERSION=2.16
# pytest : même version que la CI de repowarden (ci/requirements/e2e-python.in)
ARG PYTEST_VERSION=9.1.1

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Contrôles shell de repowarden ; jq : lu par son garde-fou des agents IA
# (repowarden garde, module ia), qui sans lui ne vérifie rien
# Python 3.12 d Ubuntu 24.04, paquets signés par apt, aucun serveur de clés (#464)
RUN apt-get -o Acquire::Retries=5 update \
    && apt-get -o Acquire::Retries=5 install -y --no-install-recommends shellcheck bats jq python3 python3-venv python3-pip python-is-python3 \
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
    install -m 0755 /tmp/kind /usr/local/bin/kind-reel; \
    rm -f /tmp/kind

# kubectx et kubens : binaires officiels ahmetb/kubectx, versions figees avec
# empreinte sha256 par architecture (comme k9s)
RUN set -eu; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
        arm64) rel_arch=arm64; kctx_sha=1dac2072216689e773325cb7587b858ea7415706ebcf04e23bf80e7e70555340; kns_sha=37058abe82ef20c93b44f3dc8ca2382dbb95d416cec958fbf7b8f79f011be86c ;; \
        amd64) rel_arch=x86_64; kctx_sha=08e031c54fbffb3f100e904e4eae94bba2730fedf4869921fda79e4d7a8f5d4c; kns_sha=326c021c7b35468ed9a187b361198d0f22ae32828139c65eb6670c0d8301cc09 ;; \
        *) echo "Architecture non prise en charge : $arch" >&2; exit 1 ;; \
    esac; \
    installer() { \
        tmp="$(mktemp -d)"; \
        curl -fsSL "https://github.com/ahmetb/kubectx/releases/download/v${KUBECTX_VERSION}/$1_v${KUBECTX_VERSION}_linux_${rel_arch}.tar.gz" -o "$tmp/a.tar.gz"; \
        echo "$2  $tmp/a.tar.gz" | sha256sum -c --quiet; \
        tar -xzf "$tmp/a.tar.gz" -C "$tmp" "$1"; \
        install -m 0755 "$tmp/$1" /usr/local/bin/"$1"; \
        rm -rf "$tmp"; \
    }; \
    installer kubectx "$kctx_sha"; \
    installer kubens "$kns_sha"

# kind passe par une enveloppe (#291) : avec le Docker de l'hôte, un cluster
# créé à la main doit être rendu joignable depuis le conteneur (kube-joignable.sh)
COPY kube-joignable.sh /usr/local/lib/devzone/kube-joignable.sh
COPY kind-enveloppe.sh /usr/local/bin/kind
RUN chmod 0644 /usr/local/lib/devzone/kube-joignable.sh && chmod 0755 /usr/local/bin/kind

COPY --from=uv /uv /uvx /usr/local/bin/

# ruff, vulture (repowarden code-mort a besoin des deux) et pytest, installés pour
# tous les utilisateurs, avec un Python géré par uv hors du home
# (variables limitées au build : uv tool install reste dans ~/.local pour vscode)
RUN export UV_TOOL_DIR=/opt/uv/tools UV_TOOL_BIN_DIR=/usr/local/bin \
        UV_PYTHON_INSTALL_DIR=/opt/uv/python \
    && uv tool install "ruff==${RUFF_VERSION}" \
    && uv tool install "vulture==${VULTURE_VERSION}" \
    && uv tool install "pytest==${PYTEST_VERSION}"

# devzone scripts inside the image: the Kubernetes workspace pod has no
# /workspaces/devzone checkout (#503). The Docker devcontainer relinks
# /usr/local/bin/devzone to the mounted repository in post-create.sh.
COPY . /usr/local/share/devzone/.devcontainer
RUN ln -sf /usr/local/share/devzone/.devcontainer/devzone /usr/local/bin/devzone
