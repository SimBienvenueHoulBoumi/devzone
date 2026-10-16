# devzone

Zone de dev conteneurisée : Java 21 + Maven, Node LTS + pnpm, Python 3.12 + uv, Docker (in-docker), kubectl, helm, k9s, kind (cluster de l'hôte s'il existe, sinon kind dans le conteneur), gh, repowarden (hooks git globaux) et ses outils : shellcheck, bats, actionlint, gitleaks, ruff, vulture, pytest ; assistants IA : Claude Code et opencode.

## Prérequis

Fonctionne sur Mac (Apple Silicon ou Intel), Linux et Windows :

- **Docker** : Docker Desktop (Mac, Windows, Linux) ou Docker Engine (Linux)
- **VS Code** + extension *Dev Containers*, **ou** Node (pour `npx @devcontainers/cli`) et `make`
- **Cluster Kubernetes sur l'hôte** (recommandé) : devzone n'installe pas de cluster, il fournit les outils (`kubectl`, `helm`, `k9s`, `kind`) et se connecte au cluster de l'hôte. Avec Docker Desktop : *Settings → Kubernetes → Enable Kubernetes*. Sans cluster sur l'hôte, en créer un dans le conteneur : `kind create cluster` (voir [Kubernetes](#kubernetes)).
- **Windows** : cloner avec Git for Windows ; les scripts restent en fins de ligne LF (`.gitattributes`). Sans `make`, utiliser VS Code ou les commandes `npx` ci-dessous.

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

Sans `make` (Windows) :

```bash
npx @devcontainers/cli up --workspace-folder .                              # make up
npx @devcontainers/cli exec --workspace-folder . bash                       # make shell
npx @devcontainers/cli up --workspace-folder . --remove-existing-container  # make rebuild
```

`make` seul affiche cette liste. Les logs de `up`/`rebuild` vont dans `.devzone.log` ; seule la fin s'affiche en cas d'échec.

> Ne pas lancer `make up` pendant que VS Code ouvre ou reconstruit le conteneur : deux lancements simultanés créent des conteneurs en double.

## Utilisation

### Premier lancement

1. `make shell` (ou *Reopen in Container* dans VS Code). Le premier build prend quelques minutes. Pour vérifier les outils : `java -version`, `node -v`, `python3 --version`, `repowarden --version`, `kubectl get nodes`.
2. Dans le conteneur, une seule fois (conservé dans des volumes : survit à `make rebuild` et `make down`) :
   ```bash
   gh auth login -s workflow           # GitHub : tickets, PR, repowarden, git push/pull
   bash .devcontainer/git-identite.sh  # identité git (sinon : au prochain démarrage)
   ```
   **Permission `workflow`** : sans elle, GitHub refuse tout push qui modifie `.github/workflows/` (fréquent avec repowarden). Compte déjà connecté : `gh auth refresh -h github.com -s workflow`.
   **Identité git** : déduite du compte `gh` de chacun, écrite dans `~/.config/git/config` (volume) : nom du profil GitHub (sinon login), email noreply `<id>+<login>@users.noreply.github.com` (commits rattachés au compte, email personnel non exposé). Une identité déjà définie n'est jamais remplacée ; pour un autre email : `git config --file ~/.config/git/config user.email "<email>"`. `post-create.sh` rappelle ce qui manque. Git passe par le jeton de `gh` (https, même pour les remotes en `git@github.com:`), sans clé ssh à recopier, et les dépôts de `/workspaces/devzone` sont déclarés sûrs (`safe.directory`).
3. Se connecter aux assistants IA, une seule fois : `claude` (puis `/login`), `opencode auth login`. Leur connexion et leurs réglages sont dans des volumes (`devzone-claude`, `devzone-opencode-*`) : ils survivent à `make rebuild` et `make down`.

### Travailler sur un projet

```bash
cd /workspaces/devzone/workspace
git clone https://github.com/<compte>/<projet>.git
cd <projet>
```

Les hooks git de repowarden sont installés **globalement** (`repowarden install --global --lang fr`) : ils s'appliquent à tout dépôt cloné dans le conteneur, sans rien faire de plus. Ensuite, suivre les règles du projet (`AGENTS.md`, `CONTRIBUTING.md`) : `repowarden ticket <n>`, `repowarden cc …`.

**Bots repowarden** d'un projet (CI, releases, tickets, GitHub App, protection) : `repowarden bots` dans le projet, chaque bot avec ton accord. Sans GitHub App (`repowarden app init`), les workflows agissent sous le bot `github-actions`, dont les actions ne déclenchent aucun autre workflow (PR brouillon sans CI, merge automatique sans préversion…).

**CI « en attente d'approbation »** (run `action_required`, bandeau dans la PR) : la PR a été ouverte ou poussée par le bot `github-actions` (PR brouillon d'un ticket, PR de livraison). GitHub ne lance alors les workflows `pull_request` (`opened`, `synchronize`, `reopened`) qu'après l'accord d'une personne ayant les droits d'écriture ([doc GitHub](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow)) :
- **débloquer la PR** : l'ouvrir, vérifier ses changements (surtout `.github/workflows/`), puis *Approve workflows to run* ;
- **ne plus avoir à le faire** : `repowarden app init` dans le projet ; les workflows passent par le jeton de la GitHub App, dont les PR lancent la CI d'elles-mêmes.

Les vérifications de la CI de repowarden se lancent telles quelles dans le conteneur (`shellcheck`, `actionlint`, `bats test/`). actionlint est à la même version que la CI ; shellcheck et bats sont ceux d'Ubuntu 24.04 et peuvent différer légèrement.

### Kubernetes

devzone fournit les outils, pas le cluster. Au démarrage, le conteneur se connecte au cluster de l'hôte s'il existe et qu'il est joignable (Docker Desktop sur Mac, Windows ou Linux). Sinon, ou en plus, créer un cluster dans le conteneur :

```bash
kind create cluster          # ~2 min la première fois (image gardée entre rebuilds)
kubectl config get-contexts  # clusters de l'hôte + clusters kind
kubectl config use-context <nom>
```

- **Cluster actif par défaut** : celui de l'hôte ; un choix fait avec `use-context` est gardé aux redémarrages.
- **Clusters kind** : tournent dans le Docker interne, redémarrent avec le conteneur (contexte remis par `kube-config.sh`) ; supprimés par `kind delete cluster`.
- **CPU/RAM dans k9s** (`kubectl top`) : au démarrage, metrics-server est installé sur les clusters locaux joignables (Docker Desktop, kind…) qui ne l'ont pas, jamais sur un cluster distant (Docker Desktop et kind ne l'ont pas d'office). Après un `kind create cluster` : `bash .devcontainer/metrics-server.sh`.
- Messages de démarrage (`kube-config : …`) : dans le terminal VS Code de création, ou relancer `bash .devcontainer/kube-config.sh`.
- `~/.kube` de l'hôte est monté en lecture seule, jamais modifié ; sa copie adaptée est `~/.kube/hote.config` (`127.0.0.1` remplacé par `host.docker.internal`). Après un changement de cluster sur l'hôte : `make stop && make up`.

Cas sans cluster de l'hôte joignable (kind fonctionne quand même) :
- **Codespaces / machine distante** : pas de `~/.kube` local.
- **Linux avec Docker Engine** : un cluster kind ou minikube de l'hôte écoute sur `127.0.0.1`, invisible du conteneur. Un cluster qui écoute sur toutes les interfaces (k3s, kubeadm) est joignable.

### Mettre à jour un outil

| Outil | Où | Puis |
|---|---|---|
| k9s, actionlint, gitleaks, kind | `.devcontainer/Dockerfile` : `ARG …_VERSION` **et** les empreintes `sha256` (arm64 + amd64) | `make rebuild` |
| uv, ruff, vulture, pytest | `.devcontainer/Dockerfile` : `ARG …_VERSION` | `make rebuild` |
| repowarden | `.devcontainer/post-create.sh` : `repowarden@x.y.z` | `make rebuild` |
| Claude Code, opencode | `.devcontainer/post-create.sh` : `@anthropic-ai/claude-code@x.y.z`, `opencode-ai@x.y.z` | `make rebuild` |
| Java, Node, Python, Docker, kubectl, helm, gh | `.devcontainer/devcontainer.json` (features), versions des features figées dans `devcontainer-lock.json` | `npx @devcontainers/cli upgrade --workspace-folder .` puis `make rebuild` |

Empreinte d'une archive : `curl -fsSL <url> | shasum -a 256`.

## Versions

Flux `develop` → `main`, géré par repowarden : le travail entre dans `develop` (branche par défaut) ; **seul `develop` entre dans `main`**, par la PR de livraison (une PR de travail ouverte vers `main` est reciblée vers `develop` par la CI). Une préversion `vX.Y.Z-next.N` est publiée le soir si `develop` a changé ; le vendredi matin (ou *Actions → release → Run workflow* sur `develop`), la PR de livraison `develop` → `main` est ouverte ; son merge, après revue, publie le tag `vX.Y.Z` et la [release GitHub](https://github.com/SimBienvenueHoulBoumi/devzone/releases). La version suit les Conventional Commits : `fix` → correctif, `feat` → mineure.

**Rythme, au choix du projet** (`.github/workflows/release.yml`, job `release`, bloc `with:`) :

| Rythme | Préversion | Demande de livraison | Réglage |
|---|---|---|---|
| **Regroupé** (défaut, celui de devzone) | le soir, si `develop` a changé | fenêtre du vendredi matin, ou à la main, ou merge étiqueté « urgent » | rien à ajouter |
| **À chaque ticket** | à chaque merge sur `develop` | à chaque merge sur `develop` | `preversion-on-push: true` et `delivery-on-push: true` |

Dans les deux cas, la livraison sur `main` reste une décision humaine : le merge de la PR de livraison.

## Organisation

```
devzone/
├── .devcontainer/
│   ├── Dockerfile         # image de base + outils figés (versions et sha256)
│   ├── devcontainer-lock.json  # versions figées des features
│   ├── devcontainer.json  # features (langages, Docker, k8s, gh), volumes, extensions
│   ├── kube-config.sh     # à chaque démarrage : cluster de l'hôte + contextes kind
│   └── post-create.sh     # au premier démarrage : droits des volumes, repowarden, Claude Code, opencode
├── .github/workflows/
│   ├── repowarden.yml     # vérifications repowarden de chaque PR (PR mal visée reciblée vers develop)
│   ├── release.yml        # préversions sur develop, livraison develop → main (repowarden)
│   └── nettoyage.yml      # branches mergées supprimées, main et develop conservées
├── .repowarden.conf       # réglages repowarden partagés : flux develop → main
├── Makefile               # pilotage sans VS Code
└── workspace/             # tes projets (ignorés par git, chacun son dépôt)
```

## Notes

- Docker-in-Docker : démon isolé, ses images ne sont pas partagées avec Docker Desktop.
- Caches Maven (`~/.m2`) et pnpm stockés dans des volumes Docker (`devzone-m2`, `devzone-pnpm`) → conservés entre rebuilds.
- Sans `~/.kube` sur l'hôte, Docker le crée vide au démarrage : le conteneur démarre quand même. Sous Linux avec Docker Engine, ce dossier créé appartient à root.
- Windows : si la variable `HOME` est définie (Git Bash, MSYS), le chemin de `~/.kube` est faux (`HOME` et `USERPROFILE` sont concaténés) ; lancer depuis VS Code ou PowerShell.
