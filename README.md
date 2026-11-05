# devzone

[![npm](https://img.shields.io/npm/v/devzone)](https://www.npmjs.com/package/devzone) [![Licence GPL-3.0-only](https://img.shields.io/badge/licence-GPL--3.0--only-blue)](https://github.com/SimBienvenueHoulBoumi/devzone/blob/main/LICENSE)

devzone est un environnement de développement prêt en une commande : Java, Node, Python, Docker et Kubernetes dans un conteneur, identique sur Mac, Linux et Windows. Il s'adresse à toute personne qui souhaite développer sans installer d'outils sur sa machine, avec les mêmes versions pour toute l'équipe.

**Sécurité** : par défaut, devzone utilise le Docker et le Kubernetes de votre machine hôte au lieu de son Docker interne (Docker-in-Docker). C'est un compromis de sécurité assumé : le socket Docker de l'hôte donne un accès administrateur à son Docker, y compris pour les agents IA. Cette configuration est documentée ci-dessous.

## Pourquoi devzone ?

- **Rien à installer à part Docker** : tout le reste tourne dans un conteneur.
- **Mêmes outils et mêmes versions** pour toute l'équipe, sur Mac, Linux et Windows.
- **Prêt en quelques minutes** sur une machine neuve.
- **Jetable** : ta machine reste propre.

## Démarrage rapide

### Prérequis

- Docker Desktop (ou Docker Engine sous Linux). Pour Kubernetes (facultatif) : activer le cluster de Docker Desktop (*Settings → Kubernetes → Enable Kubernetes*).
- Node et npm (pour `npx` ou l'installation globale).
- `make` (nécessaire pour `make shell` ; sous Windows sans `make`, voir le tableau « Au quotidien »).

Sous Windows : il est recommandé de cloner avec Git for Windows (les scripts restent en fins de ligne LF grâce à `.gitattributes`, et la commande npm trouve le `bash` qu'elle exige).

### Lancer en une commande

Deux façons via npm. Sans installation, à chaque usage :

```bash
npx devzone mon-devzone
cd mon-devzone
make shell
```

Tu peux aussi l'installer une fois pour toutes :

```bash
npm install -g devzone
devzone --version
devzone --help
devzone mon-devzone
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

Pour en savoir plus : [Mettre en route un projet](https://github.com/SimBienvenueHoulBoumi/devzone/blob/main/manage/docs/reference.md#mettre-en-route-un-projet).

## Ce que contient devzone

| Domaine | Outils |
|---|---|
| Langages | Java 21 + Maven, Node LTS + pnpm, Python 3.12 + uv |
| Conteneurs, Kubernetes | Docker de l'hôte (socket partagé), kubectl, helm, k9s, kind ; connexion au cluster de l'hôte (module `kubernetes`) ; Testcontainers (`TESTCONTAINERS_HOST_OVERRIDE`) ; montages (`$LOCAL_WORKSPACE_FOLDER`) |
| GitHub (ou GitLab), qualité | gh, ou glab connecté à une instance GitLab (`devzone plateforme gitlab` dans le conteneur, [manage/docs/reference.md](manage/docs/reference.md#plateforme-github-ou-gitlab)) ; repowarden (hooks git globaux), shellcheck, bats, actionlint, gitleaks, ruff, vulture, pytest |
| Assistants IA | Claude Code, opencode (module `ia`, désactivé par défaut) |

## Installer un outil qui reste

Un outil mis a la main (sudo apt install tree) ne survit pas a un make rebuild : l'image est reconstruite de zero. Pour un outil qui doit rester, devzone paquets garde la liste des paquets a reinstaller :

```sh
devzone paquets
devzone paquets ajouter tree
devzone paquets retirer tree
devzone paquets appliquer
```

- devzone paquets affiche la liste : ✔ paquets installes, ○ paquets a installer ;
- devzone paquets ajouter <nom>… valide chaque paquet (apt-cache), installe puis l'ajoute a la liste ;
- devzone paquets retirer <nom> retire la liste et desinstalle ;
- devzone paquets appliquer installe les paquets manquants apres un rebuild.

La liste vit dans .devzone.paquets a la racine du dossier devzone, hors du depot. Un paquet en echec est signale dans le recap (⚠ paquets : …) ; devzone paquets appliquer peut alors etre relance.

## Au quotidien

| Action | VS Code (`Cmd+Shift+P`) | `make` | Sans `make` (Windows) |
|---|---|---|---|
| Lancer | *Dev Containers: Reopen in Container* | `make up` | `npx @devcontainers/cli up --workspace-folder .` |
| Ouvrir un shell | terminal de VS Code | `make shell` | `npx @devcontainers/cli exec --workspace-folder . bash` |
| Arrêter | *Remote: Close Remote Connection* (le conteneur s'arrête avec la fenêtre) | `make stop` | — |
| Supprimer le conteneur | — | `make down` | — |
| Reconstruire (après une modification de `.devcontainer/`) | *Dev Containers: Rebuild Container* | `make rebuild` | `npx @devcontainers/cli up --workspace-folder . --remove-existing-container` |
| État | — | `make status` | — |
| **Désinstaller** (tout ce que devzone a créé, après confirmation) | — | `make desinstaller` | `bash manage/scripts/desinstaller.sh` |

## Options

**Module `ia`** : active Claude Code et opencode (versions figées), avec le garde-fou repowarden qui les arrête avant de modifier `main` ou `develop` ou de commiter sans `repowarden cc` (voir [manage/docs/reference.md](manage/docs/reference.md#garde-fou-des-assistants-ia)). Pour l'activer : `devzone activer ia`. Ils sont désinstallés quand le module est désactivé, mais tes connexions restent dans leurs volumes.

**Module `kubernetes`** : active à chaque démarrage la connexion au cluster de l'hôte et l'installation de metrics-server sur les clusters locaux (pour voir le CPU et la RAM dans k9s). Pour l'activer : `devzone activer kubernetes`. Sans ce module, kubectl, helm, k9s et kind restent installés.

**Plateforme GitHub ou GitLab** : GitHub par défaut (nouvelle architecture). Pour servir une équipe sur GitLab : `devzone plateforme gitlab --url URL` (ou sans `--url` quand le module `gitlab` est activé, pour l'instance de test) : glab est installé (version figée, somme vérifiée) et connecté à l'instance, et `devzone` l'affiche à la place des contrôles `gh`. `devzone plateforme github` revient en arrière (glab retiré). GitLab est accessible directement depuis le poste sans relais temporaire. Détails dans [manage/docs/reference.md](manage/docs/reference.md#plateforme-github-ou-gitlab).

**Module `postgres`** : un PostgreSQL partagé, une base par projet (voir [Accéder à PostgreSQL](#accéder-à-postgresql)). Pour l'activer : `devzone activer postgres`.

Ces modules sont désactivés par défaut, activables à la demande depuis le conteneur (sans rebuild), et leur choix est conservé d'un démarrage à l'autre.

## Où sont mes identifiants ?

Les comptes créés par devzone sont regroupés dans `.password`, à la racine de devzone (à côté de `.devzone.modules`). Une ligne par compte, colonnes séparées par des tabulations :

```text
# service	adresse	utilisateur	mot de passe
gitlab	http://gitlab.localhost:8929	root	…
postgres	127.0.0.1:5432	postgres	…
postgres:monprojet	127.0.0.1:5432/monprojet	monprojet	…
```

Le fichier est lisible par toi seul (600) et ignoré par git : ne le copie ni ne le commit jamais. Il est régénéré à chaque création, suppression ou changement de compte (modules `gitlab` et `postgres`, seed GitLab, démarrage) :

```sh
devzone mots-de-passe                  # régénère le fichier et affiche seulement son chemin
devzone postgres creer <projet>         # création, ou nouveau mot de passe avec --nouveau-mdp
devzone postgres supprimer <projet>     # suppression du compte et de sa ligne
```

Les fichiers des modules restent la source : `workspace/.postgres/<projet>.env`, `workspace/.postgres/admin-password`, `workspace/.gitlab/root-password` et `workspace/.gitlab/dev-password`.

## Accéder à PostgreSQL

Le module `postgres` installe un PostgreSQL 16 partagé sur le cluster de devzone : une base et un utilisateur par projet. Toutes les commandes se lancent dans le conteneur (`make shell`).

```sh
devzone activer postgres          # la première fois : choix du cluster (kind dédié ou cluster de l'hôte)
devzone postgres creer monprojet  # base et utilisateur « monprojet »
```

Les identifiants sont écrits dans `workspace/.postgres/monprojet.env` (lisible par toi seul, jamais commité) :

```text
DB_HOST=127.0.0.1
DB_PORT=5432
DB_NAME=monprojet
DB_USER=monprojet
DB_PASSWORD=…
DB_URL=jdbc:postgresql://127.0.0.1:5432/monprojet
```

PostgreSQL est joignable sur `127.0.0.1:5432` depuis le conteneur. Exemple Spring Boot (`application.yaml` d'un projet rangé dans `workspace/<dossier>/<projet>/`) :

```yaml
spring:
  config:
    import: optional:file:../../.postgres/monprojet.env[.properties]
  datasource:
    url: ${DB_URL}
    username: ${DB_USER}
    password: ${DB_PASSWORD}
```

Autres commandes : `devzone postgres liste`, `devzone postgres psql monprojet` (console), `devzone postgres supprimer monprojet`, `devzone cluster [CTX]` (voir ou changer de cluster). Détails dans [manage/docs/reference.md](manage/docs/reference.md#postgresql).

### Voir le contenu de la base

Dans le conteneur :

```sh
devzone postgres liste              # les bases et leur propriétaire
devzone postgres psql monprojet     # console SQL connectée à la base « monprojet », avec son utilisateur
```

Dans la console (`\q` pour sortir) :

| Commande | Affiche |
|---|---|
| `\conninfo` | la base et l'utilisateur de la connexion |
| `\dt` | les tables de la base |
| `\d task` | la structure d'une table : colonnes, types, index, clés |
| `\dn` | les schémas |
| `SELECT * FROM task LIMIT 10;` | les premières lignes d'une table |
| `SELECT * FROM flyway_schema_history;` | les migrations Flyway appliquées (si le projet utilise Flyway) |

`devzone postgres psql`, sans nom de projet, ouvre la console en superutilisateur `postgres` : toutes les bases (`\l`), tous les utilisateurs (`\du`). Réserve-la à l'administration, une erreur y touche les bases de tous les projets.

### Se connecter depuis le poste (IntelliJ, DBeaver, psql)

Le relais de devzone rend PostgreSQL joignable **dans le conteneur** seulement (en attendant [#292](https://github.com/SimBienvenueHoulBoumi/devzone/issues/292)). Pour un client installé sur le poste, ouvre un tunnel dans un terminal **du poste** (Terminal du Mac, pas celui du conteneur), et laisse-le ouvert :

```sh
kubectl --context docker-desktop -n devzone-postgres port-forward svc/postgres 5432:5432
```

(`docker-desktop` : le Kubernetes de l'hôte, celui de devzone par défaut ; `15432:5432` si un PostgreSQL local occupe déjà le port 5432 du poste.)

Puis, dans le client, une connexion PostgreSQL : hôte `localhost`, port `5432`, base, utilisateur et mot de passe lus dans `workspace/.postgres/monprojet.env` (`DB_NAME`, `DB_USER`, `DB_PASSWORD`). Dans IntelliJ : *View → Tool Windows → Database → + → Data Source → PostgreSQL*, puis *Test Connection* (fenêtre Database : IntelliJ Ultimate ; plugin *Database Navigator* sinon).

« Connection refused » : le tunnel ne tourne pas, ou il a été lancé dans le conteneur. Une base recréée (`devzone postgres supprimer` puis `creer`, ou `creer --nouveau-mdp`) a un nouveau mot de passe : à reporter dans le client.

### Droits : un utilisateur par base

L'utilisateur d'un projet possède **sa** base (il y crée tables, index, données) et rien d'autre : il ne peut ni créer une base, ni se connecter à celle d'un autre projet. D'où, dans un client, `[42501] ERROR: permission denied to create database`. C'est voulu (les projets ne se voient pas). Pour une nouvelle base : `devzone postgres creer <projet>`, qui donne son propre utilisateur et son fichier `.env`.

> Le module `gitlab` a aussi son propre PostgreSQL (`gitlab-postgresql`) : il appartient à GitLab, n'y mets pas tes bases.

## Accéder à une application depuis le poste

Une application lancée **dans** le conteneur (par exemple un Spring Boot avec `./gradlew bootRun` sur le port 8080) n'est pas joignable depuis le poste : le conteneur devzone ne publie aucun port. `devzone port <n>` ouvre un relais `alpine/socat` (version figée) sur le Docker de l'hôte, de `127.0.0.1:<port>` du poste vers le port du conteneur.

```sh
devzone port 8080        # ouvre le relais du port 8080
devzone port             # liste : port, ● actif ou ○ arrêté, application derrière
devzone port --fermer 8080
```

Depuis le poste : `http://localhost:8080`. Le relais est recréé automatiquement au démarrage du conteneur, vers l'adresse actuelle du conteneur ; il est retiré par `make desinstaller` (étiquette `devzone.instance`).

Spring Boot écoute sur `0.0.0.0` par défaut : ne fixe pas `server.address` à `127.0.0.1`, sinon le relais ne peut pas joindre l'application. Un port déjà pris sur le poste, un port invalide ou un Docker de l'hôte injoignable sont refusés avec un code non nul. Détails dans [manage/docs/reference.md](manage/docs/reference.md#ports-vers-le-poste).

## Questions fréquentes

- **Docker absent ou arrêté** : `npx devzone`, `make up`, `make rebuild` et `make desinstaller` vérifient Docker avant tout et disent quoi faire : l'installer (Docker Desktop, ou Docker Engine sous Linux), démarrer Docker Desktop, ou, sous Linux, ajouter ton compte au groupe `docker` (`sudo usermod -aG docker $USER`, puis une nouvelle session). Avec `npx devzone mon-devzone`, le dossier est créé quand même : une fois Docker démarré, `cd mon-devzone && make shell`.
- **Accès au socket Docker de l'hôte** : le socket Docker de la machine hôte est monté dans le conteneur avec accès en lecture seule. Cela offre un accès administrateur au Docker de l'hôte, y compris pour les agents IA. C'est un compromis de sécurité assumé documenté dans la section Sécurité. Pour restreindre l'accès, utilisez les mécanismes propres à Docker Desktop/Linux.
- **Le premier lancement est long** : c'est normal (construction de l'image, téléchargement des images de base). Il prend 4 à 5 min mesurées, plus le téléchargement des images de base sur une machine neuve.
- **`make` est absent sous Windows** : tu peux utiliser `npx @devcontainers/cli` (voir le tableau « Au quotidien ») ou Git Bash. Les scripts sont compatibles (fins de ligne LF).
- **Pas de cluster Kubernetes visible** : devzone ne crée jamais de cluster. Avec le module `kubernetes` actif, il tente de se connecter au cluster de l'hôte (via `host.docker.internal`). Sinon, crée un cluster local avec `kind create cluster`.
- **Problème d'identité git pour commiter** : règle-la une seule fois. Avec GitHub : `gh auth login -s workflow` (l'identité est déduite automatiquement). Sans GitHub : `git config --file ~/.config/git/config user.name "<nom>"` et `git config --file ~/.config/git/config user.email "<email>"`.
- **`make up` semble bloqué** : il affiche ses étapes et un signe de vie au moins toutes les 30 s ; le journal complet est dans `.devzone.log`.

## Désinstaller

```bash
make desinstaller
```

Cette commande supprime le conteneur, l'image `vsc-devzone-…`, les volumes `devzone-*`, les events du Docker de l'hôte et les clusters kind créés sur l'hôte, les namespaces `devzone-postgres` et les étiquettes `app.kubernetes.io/managed-by=devzone` sur les clusters de l'hôte, ainsi que les éventuels metrics-server installés par devzone. Les ressources sont filtrées par l'étiquette `devzone.instance` pour ne cibler que l'instance courante. Elle **ne touche jamais** à `workspace/` (tes projets). Pour garder tes connexions (GitHub, git, Claude Code, opencode et modules) : `make desinstaller GARDER=connexions`.

Avec la commande installée globalement (`npm install -g devzone`), tu peux aussi lancer, dans le dossier du devzone :

```bash
devzone desinstaller
```

Même effet que `make desinstaller`. Ensuite seulement, pour retirer la commande de ta machine :

```bash
npm uninstall -g devzone
```

Même effet que `make desinstaller`.
## Pour aller plus loin

- [Référence détaillée](https://github.com/SimBienvenueHoulBoumi/devzone/blob/main/manage/docs/reference.md)
- [Contribuer](https://github.com/SimBienvenueHoulBoumi/devzone/blob/main/manage/docs/contribuer.md) : tests, processus de livraison et organisation

## Licence

devzone est un logiciel libre, distribué sous la [GNU General Public License version 3](https://github.com/SimBienvenueHoulBoumi/devzone/blob/main/LICENSE).

