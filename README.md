# devzone

Zone de dev conteneurisée : Java 21 + Maven, Node LTS + pnpm, Python 3.12 + uv, Docker (in-docker), kubectl, helm, k9s (reliés au cluster Kubernetes de Docker Desktop), gh, repowarden (hooks git globaux) et ses outils : shellcheck, bats, actionlint, gitleaks, ruff, vulture.

## Prérequis (sur le Mac)

- Docker Desktop lancé
- VS Code + extension *Dev Containers*, **ou** `make` et Node (pour `npx @devcontainers/cli`)

## VS Code

| Action | Commande (`Cmd+Shift+P`) |
|---|---|
| Lancer | *Dev Containers: Reopen in Container* |
| Arrêter | *Remote: Close Remote Connection* — le conteneur s'arrête à la fermeture de la fenêtre |
| Reconstruire | *Dev Containers: Rebuild Container* (après modif de `.devcontainer/`) |

## CLI (sans VS Code)

Depuis le dossier `devzone/` :

| Commande | Action |
|---|---|
| `make up` | Lance le conteneur (le crée si absent) |
| `make shell` | Ouvre un shell dedans (lance si besoin) |
| `make stop` | Arrête le conteneur, état conservé |
| `make down` | Supprime le conteneur (caches Maven/pnpm conservés dans leurs volumes) |
| `make rebuild` | Reconstruit de zéro (après modif de `.devcontainer/`) |
| `make status` | État du conteneur |

`make` seul affiche cette liste. Les logs de `up`/`rebuild` vont dans `.devzone.log` ; seule la fin s'affiche en cas d'échec.

> Ne pas lancer `make up` pendant que VS Code ouvre ou reconstruit le conteneur : deux lancements simultanés créent des conteneurs en double.

## Utilisation

### Premier lancement

1. `make shell` (ou *Reopen in Container* dans VS Code). Le premier build prend quelques minutes. Pour vérifier les outils : `java -version`, `node -v`, `python3 --version`, `repowarden --version`, `kubectl get nodes`.
2. Dans le conteneur, se connecter à GitHub (tickets, PR, `repowarden`) :
   ```bash
   gh auth login
   gh auth setup-git      # git push/pull via gh
   ```
   À refaire après `make down` ou `make rebuild` (la session gh n'est pas dans un volume).
3. Vérifier l'identité git (`git config --global user.name`). Si elle est vide (cas avec `make`), la définir ; à refaire après `make down` ou `make rebuild` :
   ```bash
   git config --global user.name "<nom>"
   git config --global user.email "<email>"
   ```

### Travailler sur un projet

```bash
cd /workspaces/devzone/workspace
git clone https://github.com/<compte>/<projet>.git
cd <projet>
```

Les hooks git de repowarden sont installés **globalement** (`repowarden install --global --lang fr`) : ils s'appliquent à tout dépôt cloné dans le conteneur, sans rien faire de plus. Ensuite, suivre les règles du projet (`AGENTS.md`, `CONTRIBUTING.md`) : `repowarden ticket <n>`, `repowarden cc …`.

Les vérifications de la CI de repowarden se lancent telles quelles dans le conteneur (`shellcheck`, `actionlint`, `bats test/`). actionlint est à la même version que la CI ; shellcheck et bats sont ceux d'Ubuntu 24.04 et peuvent différer légèrement.

### Mettre à jour un outil

| Outil | Où | Puis |
|---|---|---|
| k9s, actionlint, gitleaks | `.devcontainer/Dockerfile` : `ARG …_VERSION` **et** les empreintes `sha256` (arm64 + amd64) | `make rebuild` |
| uv, ruff, vulture | `.devcontainer/Dockerfile` : `ARG …_VERSION` | `make rebuild` |
| repowarden | `.devcontainer/post-create.sh` : `repowarden@x.y.z` | `make rebuild` |
| Java, Node, Python, Docker, kubectl, helm, gh | `.devcontainer/devcontainer.json` (features), versions des features figées dans `devcontainer-lock.json` | `npx @devcontainers/cli upgrade --workspace-folder .` puis `make rebuild` |

Empreinte d'une archive : `curl -fsSL <url> | shasum -a 256`.

## Organisation

```
devzone/
├── .devcontainer/
│   ├── Dockerfile         # image de base + outils figés (versions et sha256)
│   ├── devcontainer-lock.json  # versions figées des features
│   ├── devcontainer.json  # features (langages, Docker, k8s, gh), volumes, extensions
│   ├── kube-config.sh     # à chaque démarrage : kubectl relié au cluster de Docker Desktop
│   └── post-create.sh     # au premier démarrage : droits des volumes, repowarden
├── Makefile               # pilotage sans VS Code
└── workspace/             # tes projets (ignorés par git, chacun son dépôt)
```

## Notes

- Docker-in-Docker : démon isolé, ses images ne sont pas partagées avec Docker Desktop.
- Caches Maven (`~/.m2`) et pnpm stockés dans des volumes Docker (`devzone-m2`, `devzone-pnpm`) → conservés entre rebuilds.
- Kubernetes : `kubectl`, `helm` et `k9s` utilisent le cluster de Docker Desktop (Settings → Kubernetes). À chaque démarrage, `kube-config.sh` recopie `~/.kube/config` du Mac (monté en lecture seule) en remplaçant `127.0.0.1` par `host.docker.internal` ; la config du Mac n'est jamais modifiée. Après un changement de cluster côté Mac : redémarrer le conteneur (`make stop && make up`).
- `~/.kube` doit exister sur le Mac (Docker Desktop le crée), sinon le conteneur ne démarre pas.
