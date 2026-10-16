# devzone

Environnement de développement complet dans un conteneur (devcontainer) : les mêmes outils, aux mêmes versions, sur Mac, Linux et Windows. Rien à installer sur ta machine à part Docker.

| Domaine | Outils |
|---|---|
| Langages | Java 21 + Maven, Node LTS + pnpm, Python 3.12 + uv |
| Conteneurs, Kubernetes | Docker (Docker-in-Docker), kubectl, helm, k9s, kind |
| GitHub, qualité | gh, repowarden (hooks git globaux), shellcheck, bats, actionlint, gitleaks, ruff, vulture, pytest |
| Assistants IA (facultatifs) | Claude Code, opencode |

**Kubernetes est optionnel** : il ne sert qu'aux projets qui l'utilisent. devzone fournit les outils, pas de cluster : il se connecte à celui de ta machine s'il existe ; sinon, aucun cluster n'est créé, tu en crées un si besoin avec `kind create cluster` (voir [Kubernetes](#kubernetes)).

## Démarrage rapide

1. **Prérequis** : Docker (Docker Desktop, ou Docker Engine sous Linux), puis **soit** VS Code + extension *Dev Containers*, **soit** Node (pour `npx`) et `make`. Facultatif, pour Kubernetes : activer le cluster de Docker Desktop (*Settings → Kubernetes → Enable Kubernetes*). Sous Windows : cloner avec Git for Windows (les scripts restent en fins de ligne LF grâce à `.gitattributes`).
2. **Lancer** depuis le dossier `devzone/` : `make shell` (ou, dans VS Code, *Dev Containers: Reopen in Container*). Le premier build prend quelques minutes (4 à 5 min mesurées, plus le téléchargement des images de base sur une machine neuve).
3. **Se connecter à GitHub, une seule fois** (gardé ensuite, même après `make rebuild`) : `gh auth login -s workflow`. Donne aussi l'identité git ; nécessaire pour pousser, ouvrir des PR et utiliser les tickets repowarden.
   **Facultatif** : les assistants IA sont installés mais rien n'en dépend ; s'en servir demande une connexion : `claude` (puis `/login`), `opencode auth login`.
4. **Vérifier** : `java -version`, `node -v`, `python3 --version`, `repowarden --version` ; avec un cluster : `kubectl get nodes`.

Le premier démarrage rappelle ce qui manque (connexion GitHub, permission `workflow`) et indique si un cluster Kubernetes est joignable ; sans cluster, tout le reste fonctionne.

## Commandes

| Action | VS Code (`Cmd+Shift+P`) | `make` | Sans `make` (Windows) |
|---|---|---|---|
| Lancer | *Dev Containers: Reopen in Container* | `make up` | `npx @devcontainers/cli up --workspace-folder .` |
| Ouvrir un shell | terminal de VS Code | `make shell` | `npx @devcontainers/cli exec --workspace-folder . bash` |
| Arrêter | *Remote: Close Remote Connection* (le conteneur s'arrête avec la fenêtre) | `make stop` | — |
| Supprimer le conteneur | — | `make down` | — |
| Reconstruire (après une modification de `.devcontainer/`) | *Dev Containers: Rebuild Container* | `make rebuild` | `npx @devcontainers/cli up --workspace-folder . --remove-existing-container` |
| État | — | `make status` | — |

`make` seul affiche la liste. Les journaux de `up` et `rebuild` vont dans `.devzone.log` ; seule la fin s'affiche en cas d'échec.

> Ne pas lancer `make up` pendant que VS Code ouvre ou reconstruit le conteneur : deux lancements simultanés créent des conteneurs en double.

## Connexions et identité

**GitHub (`gh`)** : `gh auth login -s workflow`. Git passe par le jeton de `gh` (https, même pour les remotes en `git@github.com:`), sans clé ssh à recopier. Les dépôts de `/workspaces/devzone` sont déclarés sûrs (`safe.directory`).
- **Permission `workflow`** : sans elle, GitHub refuse tout push qui modifie `.github/workflows/` (fréquent avec repowarden). Compte déjà connecté : `gh auth refresh -h github.com -s workflow`.
- **Depuis `make shell`**, aucun navigateur ne s'ouvre depuis le conteneur : copier le code affiché par `gh` et ouvrir https://github.com/login/device à la main. L'avertissement « No clipboard utilities available » est sans conséquence.

**Identité git** : déduite du compte `gh` à chaque démarrage, tant qu'elle manque (`git-identite.sh`) :
- nom du profil GitHub (sinon le login) ;
- email noreply `<id>+<login>@users.noreply.github.com` : les commits sont rattachés au compte, l'email personnel n'est pas exposé.

Une identité déjà définie n'est jamais remplacée. Pour un autre email : `git config --file ~/.config/git/config user.email "<email>"`. Après un `gh auth login` en cours de session : `bash .devcontainer/git-identite.sh`.

**Assistants IA (facultatifs)** : installés, mais rien dans devzone n'en dépend. Pour s'en servir : `claude` (puis `/login`), `opencode auth login`.

Chaque connexion est **propre à l'utilisateur** : elle vit dans les volumes Docker de sa machine (voir [Données conservées](#données-conservées)). Le dépôt ne contient aucun identifiant.

## Travailler sur un projet

```bash
cd /workspaces/devzone/workspace
git clone https://github.com/<compte>/<projet>.git
cd <projet>
```

- **Hooks repowarden** : installés globalement (`repowarden install --global --lang fr`), ils s'appliquent à tout dépôt cloné dans le conteneur (messages de commit, secrets, formatage, tests). Ensuite, suivre les règles du projet (`AGENTS.md`, `CONTRIBUTING.md`) : `repowarden ticket <n>`, `repowarden cc …`.
- **Bots repowarden** d'un projet (CI, releases, tickets, GitHub App, protection) : `repowarden bots` dans le projet, chaque bot avec ton accord. Sans GitHub App (`repowarden app init`), les workflows agissent sous le bot `github-actions`, dont les actions ne déclenchent aucun autre workflow (PR brouillon sans CI, merge automatique sans préversion…).
- **Vérifications de la CI de repowarden** en local : `shellcheck`, `actionlint`, `bats test/`. actionlint est à la même version que la CI ; shellcheck et bats sont ceux d'Ubuntu 24.04 et peuvent différer légèrement.

## Kubernetes

devzone fournit les outils, pas le cluster, et n'en crée jamais tout seul. Au démarrage, il se connecte au cluster de l'hôte s'il existe et répond (Docker Desktop sur Mac, Windows ou Linux). Sinon, ou en plus, créer un cluster dans le conteneur :

```bash
kind create cluster          # ~2 min la première fois
kubectl config get-contexts  # clusters de l'hôte + clusters kind
kubectl config use-context <nom>
```

- **Cluster actif** : celui de l'hôte par défaut ; un choix fait avec `use-context` est gardé aux redémarrages.
- **Clusters kind** : tournent dans le Docker interne, redémarrent avec le conteneur, sont conservés par `make rebuild` et `make down` ; supprimés seulement par `kind delete cluster`.
- **CPU et RAM dans k9s** (`kubectl top`) : au démarrage, metrics-server est installé sur les clusters **locaux** qui ne l'ont pas (Docker Desktop, kind…), jamais sur un cluster distant. Après un `kind create cluster` : `bash .devcontainer/metrics-server.sh` (ou `… metrics-server.sh <contexte>` pour un cluster précis).
- **Cluster de l'hôte** : `~/.kube` est monté en lecture seule, jamais modifié ; sa copie adaptée est `~/.kube/hote.config` (`127.0.0.1` remplacé par `host.docker.internal`). Après un changement de cluster sur l'hôte : `make stop && make up`.
- **Messages de démarrage** (`kube-config : …`, `metrics-server : …`) : dans le terminal de création, ou en relançant `bash .devcontainer/kube-config.sh`.

Le cluster de l'hôte n'est pas joignable dans deux cas (kind fonctionne quand même) :
- **Codespaces, machine distante** : pas de `~/.kube` local ;
- **Linux avec Docker Engine** : un cluster kind ou minikube de l'hôte écoute sur `127.0.0.1`, invisible du conteneur. Un cluster qui écoute sur toutes les interfaces (k3s, kubeadm) est joignable.

## Données conservées

Le conteneur est jetable ; ce qui compte vit dans des volumes Docker, sur ta machine.

| Volume | Contenu | `make stop` | `make down` | `make rebuild` |
|---|---|---|---|---|
| `devzone-gh` | connexion GitHub (`gh`) | gardé | gardé | gardé |
| `devzone-git` | identité git (`~/.config/git/config`) | gardé | gardé | gardé |
| `devzone-claude` | connexion et réglages de Claude Code | gardé | gardé | gardé |
| `devzone-opencode-config`, `devzone-opencode-data` | connexion et réglages d'opencode | gardé | gardé | gardé |
| `devzone-m2`, `devzone-pnpm` | caches Maven (`~/.m2`) et pnpm | gardé | gardé | gardé |
| volume du Docker interne | images Docker et clusters kind du conteneur | gardé | gardé | gardé |
| `workspace/` (dossier de l'hôte) | tes projets | gardé | gardé | gardé |

Tout le reste du conteneur (paquets installés à la main, fichiers hors de ces emplacements) est perdu à `make down` et `make rebuild`. Le Docker interne est isolé : ses images ne sont pas partagées avec Docker Desktop.

## Mettre à jour un outil

| Outil | Où | Puis |
|---|---|---|
| k9s, actionlint, gitleaks, kind | `.devcontainer/Dockerfile` : `ARG …_VERSION` **et** les empreintes `sha256` (arm64 + amd64) | `make rebuild` |
| uv, ruff, vulture, pytest | `.devcontainer/Dockerfile` : `ARG …_VERSION` | `make rebuild` |
| repowarden | `.devcontainer/post-create.sh` : `repowarden@x.y.z` | `make rebuild` |
| Claude Code, opencode | `.devcontainer/post-create.sh` : `@anthropic-ai/claude-code@x.y.z`, `opencode-ai@x.y.z` | `make rebuild` |
| metrics-server | `.devcontainer/metrics-server.sh` : `VERSION` | `bash .devcontainer/metrics-server.sh` sur un nouveau cluster |
| Java, Node, Python, Docker, kubectl, helm, gh | `.devcontainer/devcontainer.json` (features), versions figées dans `devcontainer-lock.json` | `npx @devcontainers/cli upgrade --workspace-folder .` puis `make rebuild` |

Empreinte d'une archive : `curl -fsSL <url> | shasum -a 256`.

## Versions et livraison

Flux `develop` → `main`, géré par repowarden :
1. Le travail entre dans `develop` (branche par défaut), par une PR liée à un ticket. Une PR de travail ouverte vers `main` est reciblée vers `develop` par la CI.
2. Une **préversion** `vX.Y.Z-next.N` est publiée depuis `develop`.
3. La **PR de livraison** `develop` → `main` exige cette préversion (vérification `livraison`). Son merge est une **décision humaine**, sans approbation exigée par ailleurs, et publie le tag `vX.Y.Z` et la [release GitHub](https://github.com/SimBienvenueHoulBoumi/devzone/releases).

La version suit les Conventional Commits : `fix` → correctif, `feat` → mineure.

**Rythme, au choix du projet** (`.github/workflows/release.yml`, job `release`, bloc `with:`) :

| Rythme | Préversion | Demande de livraison | Réglage |
|---|---|---|---|
| **Regroupé** (défaut, celui de devzone) | le soir, si `develop` a changé | fenêtre du vendredi matin, à la main (*Actions → release → Run workflow* sur `develop`), ou merge étiqueté « urgent » | rien à ajouter |
| **À chaque ticket** | à chaque merge sur `develop` | à chaque merge sur `develop` | `preversion-on-push: true` et `delivery-on-push: true` |

## Dépannage

| Symptôme | Cause | Solution |
|---|---|---|
| `git push` refusé : « refusing to allow an OAuth App to create or update workflow … without `workflow` scope » | jeton `gh` sans la permission `workflow` | `gh auth refresh -h github.com -s workflow` |
| PR bloquée, run `action_required`, bandeau « Approve workflows to run » | PR ouverte ou poussée par le bot `github-actions` : pour les événements `pull_request` `opened`, `synchronize` et `reopened`, GitHub attend l'accord d'une personne ayant l'écriture ([doc GitHub](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow)) | vérifier les changements (surtout `.github/workflows/`), puis *Approve workflows to run* ; pour ne plus avoir à le faire : `repowarden app init` dans le projet |
| PR de livraison bloquée : « aucune préversion vX.Y.Z-next.N » | la préversion n'est pas encore publiée (rythme regroupé) | attendre celle du soir, ou *Actions → release → Run workflow* sur `develop` |
| `git commit` : « Please tell me who you are » | identité git absente (`gh` non connecté) | `gh auth login -s workflow` puis `bash .devcontainer/git-identite.sh` |
| `gh auth login` : « Press Enter to open … in your browser », rien ne s'ouvre | pas de navigateur dans le conteneur (`make shell`) | ouvrir https://github.com/login/device à la main et saisir le code |
| `k9s` : `Error: exit status 1` puis son aide ; `kubectl` : `localhost:8080` … `connection refused` | aucun cluster actif | `kind create cluster`, ou `kubectl config use-context <nom>` |
| CPU et RAM vides dans k9s | metrics-server absent du cluster | `bash .devcontainer/metrics-server.sh` |
| Deux conteneurs devzone | `make up` lancé pendant que VS Code ouvrait le conteneur | `make down`, puis un seul lancement |
| Windows (Git Bash, MSYS) : `~/.kube` introuvable | `HOME` et `USERPROFILE` concaténés dans le chemin monté | lancer depuis VS Code ou PowerShell |
| Pas de `~/.kube` sur l'hôte | Docker le crée vide au démarrage (sous Linux avec Docker Engine, il appartient à root) | rien à faire : le conteneur démarre quand même |

## Organisation

```text
devzone/
├── .devcontainer/
│   ├── Dockerfile              # image de base + outils figés (versions et sha256)
│   ├── devcontainer.json       # features (langages, Docker, Kubernetes, gh), volumes, extensions VS Code
│   ├── devcontainer-lock.json  # versions figées des features
│   ├── post-create.sh          # premier démarrage : droits des volumes, git, repowarden, Claude Code, opencode
│   ├── kube-config.sh          # chaque démarrage : cluster de l'hôte, contextes kind, puis metrics-server
│   ├── metrics-server.sh       # metrics-server sur les clusters locaux (CPU et RAM dans k9s)
│   └── git-identite.sh         # chaque démarrage : identité git déduite du compte gh si elle manque
├── .github/workflows/
│   ├── repowarden.yml          # vérifications repowarden de chaque PR (PR mal visée reciblée vers develop)
│   ├── tickets.yml             # suivi des tickets : branche, PR brouillon, statuts jusqu'à la production
│   ├── release.yml             # préversions sur develop, livraison develop → main
│   └── nettoyage.yml           # branches mergées supprimées (main et develop conservées)
├── .repowarden.conf            # réglages repowarden : flux develop → main
├── Makefile                    # pilotage sans VS Code
└── workspace/                  # tes projets (ignorés par git, chacun son dépôt)
```
