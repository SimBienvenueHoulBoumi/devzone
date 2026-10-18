# devzone

[![npm](https://img.shields.io/npm/v/devzone)](https://www.npmjs.com/package/devzone) [![Licence GPL-3.0-only](https://img.shields.io/badge/licence-GPL--3.0--only-blue)](LICENSE)

devzone est un environnement de développement prêt en une commande : Java, Node, Python, Docker et Kubernetes dans un conteneur, identique sur Mac, Linux et Windows. Il s’adresse à toute personne qui souhaite développer sans installer d’outils sur sa machine, avec les mêmes versions pour toute l’équipe.

## Pourquoi devzone ?

- **Rien à installer à part Docker** : tout le reste tourne dans un conteneur.
- **Mêmes outils et mêmes versions** pour toute l’équipe, sur Mac, Linux et Windows.
- **Prêt en quelques minutes** sur une machine neuve.
- **Jetable** : ta machine reste propre.

## Démarrage rapide

### Prérequis

- Docker Desktop (ou Docker Engine sous Linux)
- Node (pour `npx`)
- `make` (facultatif sous Windows ; sinon utiliser `npx @devcontainers/cli`)

### Lancer en une commande

```bash
npx devzone mon-devzone
cd mon-devzone
make shell
```

À chaque démarrage, un récapitulatif t’indique ce qui est prêt ou ce qu’il te reste à faire (extrait) :

```text
devzone : état (devzone pour le réafficher)
  ✖ identité git    nécessaire pour commiter : gh auth login -s workflow (automatique),
                    ou git config --file ~/.config/git/config user.name "<nom>" et user.email "<email>"
  ○ GitHub          facultatif (push et PR, tickets repowarden) : gh auth login -s workflow
  ○ module ia         facultatif, assistants IA : Claude Code, opencode : devzone activer ia
  ○ module kubernetes facultatif, connexion au cluster de l’hôte et metrics-server au démarrage : devzone activer kubernetes
```

Le premier lancement prend quelques minutes (4 à 5 min mesurées, plus le téléchargement des images de base sur une machine neuve).

**Étape facultative** : `gh auth login -s workflow` pour activer GitHub (push, PR et tickets repowarden).

## Ce que contient devzone

| Domaine | Outils |
|---|---|
| Langages | Java 21 + Maven, Node LTS + pnpm, Python 3.12 + uv |
| Conteneurs, Kubernetes | Docker (Docker-in-Docker), kubectl, helm, k9s, kind ; connexion au cluster de l’hôte (module `kubernetes`) |
| GitHub, qualité | gh, repowarden (hooks git globaux), shellcheck, bats, actionlint, gitleaks, ruff, vulture, pytest |
| Assistants IA | Claude Code, opencode (module `ia`, désactivé par défaut) |

## Au quotidien

| Action | VS Code (`Cmd+Shift+P`) | `make` | Sans `make` (Windows) |
|---|---|---|---|
| Lancer | *Dev Containers: Reopen in Container* | `make up` | `npx @devcontainers/cli up --workspace-folder .` |
| Ouvrir un shell | terminal de VS Code | `make shell` | `npx @devcontainers/cli exec --workspace-folder . bash` |
| Arrêter | *Remote: Close Remote Connection* (le conteneur s’arrête avec la fenêtre) | `make stop` | — |
| Supprimer le conteneur | — | `make down` | — |
| Reconstruire (après une modification de `.devcontainer/`) | *Dev Containers: Rebuild Container* | `make rebuild` | `npx @devcontainers/cli up --workspace-folder . --remove-existing-container` |
| État | — | `make status` | — |
| **Désinstaller** (tout ce que devzone a créé, après confirmation) | — | `make desinstaller` | `bash scripts/desinstaller.sh` |

## Options

**Module `ia`** : active Claude Code et opencode (versions figées). Pour l’activer : `devzone activer ia`. Ils sont désinstallés quand le module est désactivé, mais tes connexions restent dans leurs volumes.

**Module `kubernetes`** : active à chaque démarrage la connexion au cluster de l’hôte et l’installation de metrics-server sur les clusters locaux (pour voir le CPU et la RAM dans k9s). Pour l’activer : `devzone activer kubernetes`. Sans ce module, kubectl, helm, k9s et kind restent installés.

Ces modules sont désactivés par défaut, activables à la demande depuis le conteneur (sans rebuild), et leur choix est conservé d’un démarrage à l’autre.

## Questions fréquentes

- **Le premier lancement est long** : c’est normal (construction de l’image, téléchargement des images de base). Il dure environ 4 à 5 minutes mesurées sur une machine neuve.
- **`make` est absent sous Windows** : tu peux utiliser `npx @devcontainers/cli` (voir le tableau « Au quotidien ») ou Git Bash. Les scripts sont compatibles (fins de ligne LF).
- **Pas de cluster Kubernetes visible** : devzone ne crée jamais de cluster. Avec le module `kubernetes` actif, il tente de se connecter à celui de l’hôte. Sinon, crée un cluster local avec `kind create cluster`.
- **Problème d’identité git pour commiter** : règle-la une seule fois. Avec GitHub : `gh auth login -s workflow` (l’identité est déduite automatiquement). Sans GitHub : `git config --file ~/.config/git/config user.name "<nom>"` et `git config --file ~/.config/git/config user.email "<email>"`.
- **Les commandes attendent en silence ?** : `make up` et `make rebuild` affichent leurs étapes et un signe de vie au moins toutes les 30 s ; le journal complet est dans `.devzone.log`.

## Désinstaller

```bash
make desinstaller
```

Cette commande supprime le conteneur, l’image `vsc-devzone-…`, les volumes `devzone-*`, le volume du Docker interne (images et clusters kind créés dans le conteneur) ainsi que les éventuels metrics-server installés par devzone sur les clusters locaux. Elle **ne touche jamais** à `workspace/` (tes projets). Pour garder tes connexions (GitHub, git, Claude Code, opencode et modules) : `make desinstaller GARDER=connexions`.

## Pour aller plus loin

- [Référence détaillée](https://github.com/SimBienvenueHoulBoumi/devzone/blob/main/docs/reference.md)
- [Contribuer](https://github.com/SimBienvenueHoulBoumi/devzone/blob/main/docs/contribuer.md)

## Contribuer

Les contributions sont les bienvenues. Voir [docs/contribuer.md](https://github.com/SimBienvenueHoulBoumi/devzone/blob/main/docs/contribuer.md) pour les tests, le processus de livraison et l’organisation.

## Licence

devzone est un logiciel libre, distribué sous la [GNU General Public License version 3](LICENSE).
