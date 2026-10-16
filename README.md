# devzone

Environnement de développement complet dans un conteneur (devcontainer) : les mêmes outils, aux mêmes versions, sur Mac, Linux et Windows. Rien à installer sur ta machine à part Docker.

| Domaine | Outils |
|---|---|
| Langages | Java 21 + Maven, Node LTS + pnpm, Python 3.12 + uv |
| Conteneurs, Kubernetes | Docker (Docker-in-Docker), kubectl, helm, k9s, kind ; connexion au cluster de l'hôte : [module](#modules) `kubernetes` |
| GitHub, qualité | gh, repowarden (hooks git globaux), shellcheck, bats, actionlint, gitleaks, ruff, vulture, pytest |
| Assistants IA | Claude Code, opencode : [module](#modules) `ia`, désactivé par défaut |

**Ce qui est facultatif est désactivé par défaut** et s'active à la demande, sans rebuild (voir [Modules](#modules)) : les assistants IA (`devzone activer ia`) et la connexion au cluster Kubernetes de ta machine (`devzone activer kubernetes`). devzone ne crée jamais de cluster : sans celui de ta machine, tu en crées un si besoin avec `kind create cluster` (voir [Kubernetes](#kubernetes)).

## Démarrage rapide

1. **Prérequis** : Docker (Docker Desktop, ou Docker Engine sous Linux), puis **soit** VS Code + extension *Dev Containers*, **soit** Node (pour `npx`) et `make`. Facultatif, pour Kubernetes : activer le cluster de Docker Desktop (*Settings → Kubernetes → Enable Kubernetes*). Sous Windows : cloner avec Git for Windows (les scripts restent en fins de ligne LF grâce à `.gitattributes`).
2. **Lancer** depuis le dossier `devzone/` : `make shell` (ou, dans VS Code, *Dev Containers: Reopen in Container*). Le premier build prend quelques minutes (4 à 5 min mesurées, plus le téléchargement des images de base sur une machine neuve).
3. **Se connecter à GitHub, une seule fois** (gardé ensuite, même après `make rebuild`) : `gh auth login -s workflow`. Donne aussi l'identité git ; nécessaire pour pousser, ouvrir des PR et utiliser les tickets repowarden.
   **Facultatif** : `devzone activer ia` (assistants IA), `devzone activer kubernetes` (cluster de ta machine) ; voir [Modules](#modules).
4. **Vérifier** : `java -version`, `node -v`, `python3 --version`, `repowarden --version` ; avec un cluster : `kubectl get nodes`.

Le premier démarrage rappelle ce qui manque (connexion GitHub, permission `workflow`) et liste les modules désactivés, avec la commande pour les activer.

## Modules

Les fonctionnalités facultatives sont des modules, **désactivés par défaut**, activés à la demande depuis le conteneur, sans rebuild :

```bash
devzone                        # état des modules
devzone activer <module>       # active et applique tout de suite
devzone desactiver <module>    # désactive et applique tout de suite
```

| Module | Activé | Désactivé |
|---|---|---|
| `ia` | Claude Code et opencode installés (versions figées), réinstallés à chaque rebuild ; se connecter : `claude` (puis `/login`), `opencode auth login` | désinstallés ; les connexions restent dans leurs volumes |
| `kubernetes` | à chaque démarrage : connexion au cluster de ta machine et metrics-server sur les clusters locaux (CPU et RAM dans k9s) | aucune connexion au cluster de ta machine ; kubectl, helm, k9s et kind restent installés, un cluster kind créé à la main reste utilisable ; metrics-server n'est pas retiré des clusters où il a été installé |

Le choix est **propre à chaque utilisateur** et gardé dans le volume `devzone-config` (il survit aux rebuilds). Au premier démarrage, si une connexion Claude Code ou opencode existe déjà dans les volumes, le module `ia` est activé (et signalé) : rien ne disparaît pour qui s'en servait.

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

**Assistants IA** (module `ia`, voir [Modules](#modules)) : `devzone activer ia`, puis `claude` (puis `/login`), `opencode auth login`.

Chaque connexion est **propre à l'utilisateur** : elle vit dans les volumes Docker de sa machine (voir [Données conservées](#données-conservées)). Le dépôt ne contient aucun identifiant.

## Mettre en route un projet

Tes projets vont dans `workspace/` (`/workspaces/devzone/workspace` dans le conteneur), chacun avec son propre dépôt git. Les hooks repowarden y sont actifs d'office.

**Projet existant, déjà équipé de repowarden** (`.repowarden.conf` et workflows présents) : il suffit de le cloner.

```bash
cd /workspaces/devzone/workspace
git clone https://github.com/<compte>/<projet>.git
cd <projet>
repowarden            # état du poste et du dépôt, étape suivante
```

**Nouveau projet, ou projet sans repowarden** :

```bash
cd /workspaces/devzone/workspace
mkdir <projet> && cd <projet> && git init -b main     # ou git clone d'un dépôt existant
# … premiers fichiers, puis un premier commit : git add . && git cc
gh repo create <compte>/<projet> --private --source . --push   # dépôt GitHub (si absent)
repowarden bots       # CI, releases, tickets, GitHub App, protection : chacun avec ton accord
repowarden            # vérifier
```

`repowarden bots` demande le flux (`main` seule, ou `develop` → `main`), montre ce qu'il va créer, puis attend ta confirmation ; un fichier existant n'est jamais écrasé. Il faut `gh` connecté et les droits d'administration du dépôt GitHub.

## Travailler sur un projet

- **Hooks repowarden** : installés globalement (`repowarden install --global --lang fr`), ils s'appliquent à tout dépôt cloné dans le conteneur (messages de commit, secrets, formatage, tests). Ensuite, suivre les règles du projet (`AGENTS.md`, `CONTRIBUTING.md`) : `repowarden ticket <n>`, `repowarden cc …`.
- **GitHub App** (proposée par `repowarden bots`, ou `repowarden app init`) : sans elle, les workflows agissent sous le bot `github-actions`, dont les actions ne déclenchent aucun autre workflow (PR brouillon sans CI, merge automatique sans préversion…) ; voir [Dépannage](#dépannage).
- **Vérifications de la CI de repowarden** en local : `shellcheck`, `actionlint`, `bats test/`. actionlint est à la même version que la CI ; shellcheck et bats sont ceux d'Ubuntu 24.04 et peuvent différer légèrement.

## Kubernetes

devzone fournit les outils, pas le cluster, et n'en crée jamais tout seul. Avec le module `kubernetes` actif (`devzone activer kubernetes`), il se connecte à chaque démarrage au cluster de l'hôte s'il existe et répond (Docker Desktop sur Mac, Windows ou Linux). Sinon, ou en plus, créer un cluster dans le conteneur :

```bash
kind create cluster          # ~2 min la première fois
kubectl config get-contexts  # clusters de l'hôte + clusters kind
kubectl config use-context <nom>
```

- **Cluster actif** : celui de l'hôte par défaut ; un choix fait avec `use-context` est gardé aux redémarrages.
- **Clusters kind** : tournent dans le Docker interne, redémarrent avec le conteneur, sont conservés par `make rebuild` et `make down` ; supprimés seulement par `kind delete cluster`.
- **CPU et RAM dans k9s** (`kubectl top`) : module `kubernetes` actif, metrics-server est installé au démarrage sur les clusters **locaux** qui ne l'ont pas (Docker Desktop, kind…), jamais sur un cluster distant. Après un `kind create cluster` : `bash .devcontainer/metrics-server.sh` (ou `… metrics-server.sh <contexte>` pour un cluster précis).
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
| `devzone-config` | modules activés (`devzone activer`) | gardé | gardé | gardé |
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
| Claude Code, opencode | `.devcontainer/devzone` : `IA_PAQUETS` (`@anthropic-ai/claude-code@x.y.z`, `opencode-ai@x.y.z`) | `devzone activer ia` (ou `make rebuild`) |
| metrics-server | `.devcontainer/metrics-server.sh` : `VERSION` | `bash .devcontainer/metrics-server.sh` sur un nouveau cluster |
| Java, Node, Python, Docker, kubectl, helm, gh | `.devcontainer/devcontainer.json` (features), versions figées dans `devcontainer-lock.json` | `npx @devcontainers/cli upgrade --workspace-folder .` puis `make rebuild` |

Empreinte d'une archive : `curl -fsSL <url> | shasum -a 256`.

## Tests

| Tests | Commande | Où | Durée |
|---|---|---|---|
| Commande `devzone` (unitaires) | `bats test/` | dans le conteneur | quelques secondes |
| Fonctionnels : un devzone construit et utilisé comme par un utilisateur (outils, modules, Kubernetes avec kind, hooks repowarden, redémarrage, rebuild) | `make test-fonctionnel` | sur ta machine (Docker, Node) | 5 à 10 min |

Les tests fonctionnels travaillent sur une copie du dépôt, avec leurs propres volumes (`devzone-test-…`), puis suppriment tout (conteneur, volumes, image), même en cas d'échec : ton devzone, tes connexions et le cluster de ta machine ne sont jamais touchés (seul un cluster kind de test est utilisé). En CI, le workflow `fonctionnel` les lance sur chaque PR qui modifie `.devcontainer/`, `test/` ou le `Makefile`, et à la main (*Actions → fonctionnel → Run workflow*).

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
| `k9s` : `Error: exit status 1` puis son aide ; `kubectl` : `localhost:8080` … `connection refused` | aucun cluster actif (module `kubernetes` désactivé, ou pas de cluster sur ta machine) | `devzone activer kubernetes` (cluster de ta machine), `kind create cluster`, ou `kubectl config use-context <nom>` |
| `claude` ou `opencode` : « command not found » | module `ia` désactivé | `devzone activer ia` |
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
│   ├── devzone                 # commande devzone : modules (ia, kubernetes), versions des assistants IA
│   ├── post-create.sh          # premier démarrage : droits des volumes, git, repowarden, modules actifs
│   ├── kube-config.sh          # chaque démarrage : contextes kind ; module kubernetes : cluster de l'hôte, metrics-server
│   ├── metrics-server.sh       # metrics-server sur les clusters locaux (CPU et RAM dans k9s)
│   └── git-identite.sh         # chaque démarrage : identité git déduite du compte gh si elle manque
├── .github/workflows/
│   ├── fonctionnel.yml         # tests fonctionnels (PR touchant .devcontainer/, test/ ou le Makefile)
│   ├── repowarden.yml          # vérifications repowarden de chaque PR (PR mal visée reciblée vers develop)
│   ├── tickets.yml             # suivi des tickets : branche, PR brouillon, statuts jusqu'à la production
│   ├── release.yml             # préversions sur develop, livraison develop → main
│   └── nettoyage.yml           # branches mergées supprimées (main et develop conservées)
├── .repowarden.conf            # réglages repowarden : flux develop → main
├── Makefile                    # pilotage sans VS Code
├── test/
│   ├── devzone.bats            # tests de la commande devzone (bats test/)
│   └── fonctionnel.sh          # tests fonctionnels (make test-fonctionnel)
└── workspace/                  # tes projets (ignorés par git, chacun son dépôt)
```
