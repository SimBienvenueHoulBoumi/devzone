# devzone

[![npm](https://img.shields.io/npm/v/devzone)](https://www.npmjs.com/package/devzone) [![Licence GPL-3.0-only](https://img.shields.io/badge/licence-GPL--3.0--only-blue)](https://github.com/SimBienvenueHoulBoumi/devzone/blob/main/LICENSE)

devzone est un environnement de développement prêt en une commande : Java, Node, Python, Docker et Kubernetes dans un conteneur, identique sur Mac, Linux et Windows. Il s'adresse à toute personne qui souhaite développer sans installer d'outils sur sa machine, avec les mêmes versions pour toute l'équipe.

## Pourquoi devzone ?

- **Rien à installer à part Docker** : tout le reste tourne dans un conteneur.
- **Mêmes outils et mêmes versions** pour toute l'équipe, sur Mac, Linux et Windows.
- **Prêt en quelques minutes** sur une machine neuve.
- **Jetable** : ta machine reste propre.

## Démarrage rapide

### Prérequis

- Docker Desktop (ou Docker Engine sous Linux). Pour Kubernetes (facultatif) : activer le cluster de Docker Desktop (*Settings → Kubernetes → Enable Kubernetes*).
- Node (pour `npx`).
- `make` (nécessaire pour `make shell` ; sous Windows sans `make`, voir le tableau « Au quotidien »).

Sous Windows : il est recommandé de cloner avec Git for Windows (les scripts restent en fins de ligne LF grâce à `.gitattributes`, et la commande npm trouve le `bash` qu'elle exige).

### Lancer en une commande

```bash
npx devzone mon-devzone
cd mon-devzone
make shell
```

Ou bien récupérer le code directement :

```bash
git clone https://github.com/SimBienvenueHoulBoumi/devzone.git
cd devzone
make shell
```

Tu peux aussi utiliser VS Code : ouvre le dossier `mon-devzone` (ou `devzone`), puis *Dev Containers: Reopen in Container*.

À chaque démarrage, un récapitulatif t'indique ce qui est prêt ou ce qu'il te reste à faire (extrait) :

```text
devzone : état (devzone pour le réafficher)
  ✖ identité git    nécessaire pour commiter : gh auth login -s workflow (automatique),
                    ou git config --file ~/.config/git/config user.name "<nom>" et user.email "<email>"
  ○ GitHub          facultatif (push et PR, tickets repowarden) : gh auth login -s workflow
  ○ module ia         facultatif, assistants IA : Claude Code, opencode : devzone activer ia
  ○ module kubernetes facultatif, connexion au cluster de l'hôte et metrics-server au démarrage : devzone activer kubernetes
```

Le premier lancement prend 4 à 5 min mesurées, plus le téléchargement des images de base sur une machine neuve.

### Vérifier que tout fonctionne

```bash
java -version
node -v
python3 --version
repowarden --version
```

Avec un cluster Kubernetes actif : `kubectl get nodes`.

**Étape facultative** : `gh auth login -s workflow` pour activer GitHub (push, PR et tickets repowarden).

## Ton premier projet

Tes projets vont dans `workspace/` (conservé sur ta machine, même après `make down` ou `make rebuild`).

Exemple :
```bash
cd workspace
git clone https://github.com/ton-compte/ton-projet.git
# ou
mkdir mon-projet && cd mon-projet && git init -b main
```

Pour en savoir plus : [Mettre en route un projet](https://github.com/SimBienvenueHoulBoumi/devzone/blob/main/docs/reference.md#mettre-en-route-un-projet).

## Ce que contient devzone

| Domaine | Outils |
|---|---|
| Langages | Java 21 + Maven, Node LTS + pnpm, Python 3.12 + uv |
| Conteneurs, Kubernetes | Docker (Docker-in-Docker), kubectl, helm, k9s, kind ; connexion au cluster de l'hôte (module `kubernetes`) |
| GitHub, qualité | gh, repowarden (hooks git globaux), shellcheck, bats, actionlint, gitleaks, ruff, vulture, pytest |
| Assistants IA | Claude Code, opencode (module `ia`, désactivé par défaut) |

## Au quotidien

| Action | VS Code (`Cmd+Shift+P`) | `make` | Sans `make` (Windows) |
|---|---|---|---|
| Lancer | *Dev Containers: Reopen in Container* | `make up` | `npx @devcontainers/cli up --workspace-folder .` |
| Ouvrir un shell | terminal de VS Code | `make shell` | `npx @devcontainers/cli exec --workspace-folder . bash` |
| Arrêter | *Remote: Close Remote Connection* (le conteneur s'arrête avec la fenêtre) | `make stop` | — |
| Supprimer le conteneur | — | `make down` | — |
| Reconstruire (après une modification de `.devcontainer/`) | *Dev Containers: Rebuild Container* | `make rebuild` | `npx @devcontainers/cli up --workspace-folder . --remove-existing-container` |
| État | — | `make status` | — |
| **Désinstaller** (tout ce que devzone a créé, après confirmation) | — | `make desinstaller` | `bash core/scripts/desinstaller.sh` |

## Options

**Module `ia`** : active Claude Code et opencode (versions figées), avec le garde-fou repowarden qui les arrête avant de modifier `main` ou `develop` ou de commiter sans `repowarden cc` (voir [docs/reference.md](docs/reference.md#garde-fou-des-assistants-ia)). Pour l'activer : `devzone activer ia`. Ils sont désinstallés quand le module est désactivé, mais tes connexions restent dans leurs volumes.

**Module `kubernetes`** : active à chaque démarrage la connexion au cluster de l'hôte et l'installation de metrics-server sur les clusters locaux (pour voir le CPU et la RAM dans k9s). Pour l'activer : `devzone activer kubernetes`. Sans ce module, kubectl, helm, k9s et kind restent installés.

Ces modules sont désactivés par défaut, activables à la demande depuis le conteneur (sans rebuild), et leur choix est conservé d'un démarrage à l'autre.

## Questions fréquentes

- **Docker absent ou arrêté** : `npx devzone`, `make up`, `make rebuild` et `make desinstaller` vérifient Docker avant tout et disent quoi faire : l'installer (Docker Desktop, ou Docker Engine sous Linux), démarrer Docker Desktop, ou, sous Linux, ajouter ton compte au groupe `docker` (`sudo usermod -aG docker $USER`, puis une nouvelle session). Avec `npx devzone mon-devzone`, le dossier est créé quand même : une fois Docker démarré, `cd mon-devzone && make shell`.
- **Le premier lancement est long** : c'est normal (construction de l'image, téléchargement des images de base). Il prend 4 à 5 min mesurées, plus le téléchargement des images de base sur une machine neuve.
- **`make` est absent sous Windows** : tu peux utiliser `npx @devcontainers/cli` (voir le tableau « Au quotidien ») ou Git Bash. Les scripts sont compatibles (fins de ligne LF).
- **Pas de cluster Kubernetes visible** : devzone ne crée jamais de cluster. Avec le module `kubernetes` actif, il tente de se connecter à celui de l'hôte. Sinon, crée un cluster local avec `kind create cluster`.
- **Problème d'identité git pour commiter** : règle-la une seule fois. Avec GitHub : `gh auth login -s workflow` (l'identité est déduite automatiquement). Sans GitHub : `git config --file ~/.config/git/config user.name "<nom>"` et `git config --file ~/.config/git/config user.email "<email>"`.
- **`make up` semble bloqué** : il affiche ses étapes et un signe de vie au moins toutes les 30 s ; le journal complet est dans `.devzone.log`.

## Désinstaller

```bash
make desinstaller
```

Cette commande supprime le conteneur, l'image `vsc-devzone-…`, les volumes `devzone-*`, le volume du Docker interne (images et clusters kind créés dans le conteneur) ainsi que les éventuels metrics-server installés par devzone sur les clusters locaux. Elle **ne touche jamais** à `workspace/` (tes projets). Pour garder tes connexions (GitHub, git, Claude Code, opencode et modules) : `make desinstaller GARDER=connexions`.

## Pour aller plus loin

- [Référence détaillée](https://github.com/SimBienvenueHoulBoumi/devzone/blob/main/docs/reference.md)
- [Contribuer](https://github.com/SimBienvenueHoulBoumi/devzone/blob/main/docs/contribuer.md) : tests, processus de livraison et organisation

## Licence

devzone est un logiciel libre, distribué sous la [GNU General Public License version 3](https://github.com/SimBienvenueHoulBoumi/devzone/blob/main/LICENSE).

