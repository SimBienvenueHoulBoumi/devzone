# devzone

[![npm](https://img.shields.io/npm/v/devzone)](https://www.npmjs.com/package/devzone) [![Licence GPL-3.0-only](https://img.shields.io/badge/licence-GPL--3.0--only-blue)](https://github.com/SimBienvenueHoulBoumi/devzone/blob/main/LICENSE)

Ton poste de développement Linux, prêt en une commande, identique sur Mac, Windows et Linux.

- Un Ubuntu identique pour toute l'équipe.
- Les outils et services prêts : Java, Node, Python, Docker, Kubernetes, PostgreSQL, GitLab au besoin.
- Les agents IA encadrés par repowarden.
- Local et gratuit : rien n'est hébergé.
- Une mise à jour avec `devzone update`, et des outils ajoutés qui survivent au rebuild (devzone packages).

## Pourquoi devzone ?

Les alternatives ont chacune leur limite :

- **WSL** : Windows seulement, et propre à chaque poste.
- **Machine virtuelle** : lourde, lente à démarrer.
- **Environnements hébergés** (Codespaces, Gitpod…) : cloud, quotas, réseau.

devzone les évite : le même environnement sur chaque poste, sur ta machine.

## Limites

- Pas de systemd : les services fournis par devzone démarrent avec devzone, pas avec `systemctl`.
- Pas de bureau graphique : tout se passe en terminal ou dans VS Code.
- Le socket Docker de l'hôte est partagé par défaut : c'est un compromis de sécurité assumé, qui donne un accès administrateur au Docker de l'hôte, y compris aux agents IA ([#291](https://github.com/SimBienvenueHoulBoumi/devzone/issues/291)). Pour le retirer : `devzone disable docker-hote`, puis `make rebuild` sur le poste. Sans ce socket, `docker` renvoie vers le workspace Kubernetes (`devzone workspace`, kubedock et BuildKit) ; les conteneurs et kind lancés sur le Docker du poste ne fonctionnent plus dans le conteneur, alors que la connexion au cluster Kubernetes de l'hôte et les modules restent utilisables. Pour le remettre : `devzone enable docker-hote`, puis `make rebuild`.
- Le terminal garde l'administrateur du cluster ; les agents n'ont que le compte limité aux namespaces `devzone-*` (rôle `edit`, jeton renouvelé toutes les 24 h). Les installeurs seuls agissent en administrateur ([#430](https://github.com/SimBienvenueHoulBoumi/devzone/issues/430)).

## Comment ça marche

devzone prépare un environnement Ubuntu aux versions d'outils figées, et le lance à l'un de ces deux endroits :

- **dans le cluster Kubernetes** de ta machine, par défaut, dès qu'un cluster répond à la création : le poste est un pod `devzone-workspace-0` (namespace `devzone-workspace`) ;
- **dans un conteneur Docker** sinon : un devcontainer lancé par Docker sur ton poste (mode « poste Docker »).

Dans les deux cas, rien n'est hébergé : tout tourne sur ta machine. `workspace/` est conservé entre les rebuilds, et les projets d'un poste Kubernetes restent dans le volume du pod. Le mode de chaque poste est écrit dans `.devzone.modules` (`workspace=kubernetes` ou `workspace=docker`) ; le détail est dans la [référence](manage/docs/reference.md#workspace-kubernetes).

## Démarrage rapide

### Prérequis

- **Kubernetes (mode par défaut)** : un cluster Kubernetes 1.30 ou plus qui répond, avec `kubectl` et `helm` sur la machine. Sur Mac et Windows, le plus simple est le cluster de Docker Desktop : *Settings → Kubernetes → Enable Kubernetes*. devzone lui-même n'a pas besoin de Docker dans ce mode, mais le cluster de Docker Desktop s'arrête avec Docker Desktop (si le cluster ne répond pas, voir [Questions fréquentes](#questions-fréquentes)). Détails dans le [workspace Kubernetes](manage/docs/reference.md#workspace-kubernetes).
- **Docker (repli)** : Docker Desktop (ou Docker Engine sous Linux). Il sert au poste Docker, qui prend le relais quand aucun cluster ne répond à la création, et il est nécessaire pour lire les volumes à migrer (`devzone workspace migrate`, `devzone workspace revert` pour y retourner).
- Node et npm (pour `npx` ou l'installation globale).
- `make` (nécessaire pour `make shell` ; sous Windows sans `make`, voir le tableau « Au quotidien »).

Sous Windows : il est recommandé de cloner avec Git for Windows (les scripts restent en fins de ligne LF grâce à `.gitattributes`, et la commande npm trouve le `bash` qu'elle exige).

#### Mémoire minimale par module

Mesures du 16/11/2026. Le chiffre LLM vient des valeurs du chart (non mesuré en service).

| Module | Consommation mesurée | Mémoire allouable exigée par devzone |
|---|---|---|
| Cluster de base | ~4 Go | aucune |
| GitLab | ~3,6 Go | 8 Go |
| MySQL | ~0,5 Go | aucune |
| Argo CD | ~0,6 Go | 1 Go |
| LLM modèle 7B (7 milliards de paramètres, fichier Q4_K_M) | 6 Gi | 12 Go |
| LLM --preset light (modèle 3B) | 3 Gi demandés, 4 Gi en limite | 8 Go |

Sur Docker Desktop (kind), le contrôle compare le minimum à la mémoire d'un seul nœud, donc à la VM ; sur un cluster de vraies machines, à la somme des nœuds.

- **Réglage de la RAM** :
  - **Mac** (Docker Desktop) : *Settings → Resources > Memory*. Autre méthode : modifier `MemoryMiB` dans le fichier `settings-store.json` de Docker Desktop (Docker totalement quitté sinon il réécrit la valeur).
  - **Windows** : fichier `%UserProfile%\.wslconfig` avec `[wsl2]` et `memory=<N>GB`, puis `wsl --shutdown`. WSL2 prend 50 % de la RAM par défaut.
  - **Linux** : rien à régler : pas de VM, la RAM de l'hôte sert.

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

Avec un compte GitHub, l'option `--gitops <github|none|<url>>` renseigne le dépôt GitOps dès la création du dossier :

```bash
npx devzone mon-devzone --gitops github
```

Ou bien récupérer le code directement :

```bash
git clone https://github.com/SimBienvenueHoulBoumi/devzone.git
cd devzone
make shell
```

Tu peux aussi utiliser VS Code : ouvre le dossier `mon-devzone` (ou `devzone`), puis *Dev Containers: Reopen in Container*.

À chaque démarrage, un récapitulatif t'indique ce qui est prêt ou ce qu'il te reste à faire. Ses libellés sont en anglais, et `devzone` le réaffiche à la demande. Extrait, sans identité git configurée :

```text
devzone: state (devzone to show it again)
  ✖ git identity    needed to commit: gh auth login -s workflow (automatic),
                    ou git config --file ~/.config/git/config user.name "<nom>" et user.email "<email>"
  ✔ plateforme     github
  ✔ GitHub          connecté
  ○ module ia         optional, assistants IA : Claude Code, opencode: devzone enable ia
  ○ module kubernetes optional, connexion au cluster de l'hôte et metrics-server au démarrage: devzone enable kubernetes
  ○ module gitlab     optional, GitLab de test dans le cluster des services: devzone enable gitlab
```

Une ligne `○ GitHub … optional` remplace `✔ GitHub connecté` tant que `gh` n'est pas connecté. La liste complète des commandes est dans `devzone --help`.

Le premier lancement prend 4 à 5 min mesurées, plus le téléchargement des images de base sur une machine neuve.

### Kubernetes ou Docker à la création

À la création, le poste suit le cluster : Kubernetes s'il répond, Docker sinon.

```text
devzone mon-devzone
  │
  ├─ cluster qui répond ──▶ workspace dans le cluster (Kubernetes)
  │                         make shell ouvre le pod ; pas de migration
  │
  └─ sinon ───────────────▶ poste Docker
                            make shell lance le conteneur ;
                            plus tard : devzone workspace migrate
```

`devzone mon-devzone --kubernetes` exige le cluster : sans lui, rien n'est créé. `devzone mon-devzone --docker` garde le poste Docker sans contrôler le cluster. Détails dans [manage/docs/reference.md](manage/docs/reference.md#création-directe-dans-le-cluster).

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
| Langages | Java 21 + Maven + Gradle, Node LTS + pnpm, Python 3.12 (apt) + uv |
| Conteneurs, Kubernetes | Docker de l'hôte (socket partagé), kubectl, helm, k9s, kind ; connexion au cluster de l'hôte (module `kubernetes`) ; Testcontainers (`TESTCONTAINERS_HOST_OVERRIDE`) ; montages (`$LOCAL_WORKSPACE_FOLDER`) |
| GitHub (ou GitLab), qualité | gh, ou glab connecté à une instance GitLab (`devzone platform gitlab` dans le conteneur, [manage/docs/reference.md](manage/docs/reference.md#plateforme--github-ou-gitlab)) ; repowarden (hooks git globaux), shellcheck, bats, actionlint, gitleaks, ruff, vulture, pytest |
| Assistants IA | Claude Code, opencode (module `ia`, désactivé par défaut) |

## Installer un outil qui reste

Un outil mis à la main (`sudo apt install tree`) ne survit pas à un `make rebuild` : l'image est reconstruite de zéro. Pour un outil qui doit rester, `devzone packages` garde la liste des paquets à réinstaller :

```sh
devzone packages
devzone packages add tree
devzone packages remove tree
devzone packages apply
```

- `devzone packages` affiche la liste : ✔ paquets installés, ○ paquets à installer ;
- `devzone packages add <nom>…` valide chaque paquet (apt-cache), installe puis l'ajoute à la liste ;
- `devzone packages remove <nom>` retire la liste et désinstalle ;
- `devzone packages apply` installe les paquets manquants après un rebuild.

La liste vit dans `.devzone.paquets` à la racine du dossier devzone, hors du dépôt. Un paquet en échec est signalé dans le récapitulatif (⚠ paquets : …) ; `devzone packages apply` peut alors être relancé.

## Au quotidien

| Action | VS Code (`Cmd+Shift+P`) | `make` | Sans `make` (Windows) |
|---|---|---|---|
| Lancer | *Dev Containers: Reopen in Container* | `make up` | `npx @devcontainers/cli up --workspace-folder .` |
| Ouvrir un shell | terminal de VS Code | `make shell` | `npx @devcontainers/cli exec --workspace-folder . bash` |
| Arrêter | *Remote: Close Remote Connection* (le conteneur s'arrête avec la fenêtre) | `make stop` | — |
| Supprimer le conteneur | — | `make down` | — |
| Reconstruire (après une modification de `.devcontainer/`) | *Dev Containers: Rebuild Container* | `make rebuild` | `npx @devcontainers/cli up --workspace-folder . --remove-existing-container` |
| État | — | `make status` | — |
| **Désinstaller** (tout ce que devzone a créé, après confirmation) | — | `make uninstall` | `npx devzone uninstall` |

Dans le mode Kubernetes (poste créé alors que le cluster répondait, ou après `devzone workspace migrate`), le même tableau s'applique au pod `devzone-workspace-0` : `make up`, `make shell` et `make stop` le pilotent, et `make rebuild` est refusé, car rien n'est à reconstruire sur la machine. `devzone workspace revert` rend le poste Docker. Les services GitLab, PostgreSQL et Argo CD s'installent depuis le poste : `devzone workspace services enable postgres` (voir [la référence](manage/docs/reference.md#services-de-devzone-dans-le-workspace-kubernetes)). Tu peux aussi y développer : `devzone workspace clone <url>` fait un clone de travail dans le pod, `devzone ticket <n>` y crée le worktree d'un ticket et `devzone agent` y lance opencode sans copie ([développer dans le pod](manage/docs/reference.md#développer-devzone-et-repowarden-dans-le-pod)). Argo CD y est installé d'office et tient les déploiements : interface sur https://localhost:8443 (mot de passe `admin` dans `.password`), dépôt GitOps `<login>/devzone-argocd` créé sur ton GitHub, projets déclarés dans `.argocd.conf` (`devzone workspace argocd app add <dépôt>`) ; voir [Argo CD dans le workspace Kubernetes](manage/docs/reference.md#argo-cd-dans-le-workspace-kubernetes).

Dans le conteneur, `devzone --help` liste toutes les commandes. Extrait :

```text
  devzone enable <module>                  enable and apply at once
  devzone use CTX [--confirm CTX]          switch the kubectl working cluster
  devzone port [<n>|--close <n>]           relay of a container port to the workstation
```

### Mettre à jour devzone

À la création, le dossier garde sa version dans `.devzone.version` : la version, puis l'empreinte sha256 de chaque fichier copié depuis le paquet. Pour passer un dossier existant à la version du paquet :

```bash
cd mon-devzone
devzone update
```

Pour la dernière version publiée, sans installation globale :

```bash
cd mon-devzone
npx devzone@latest update
```

La commande affiche la version du dossier et celle du paquet, et ne fait rien si elles sont égales. Sinon, elle sauvegarde dans `.devzone.sauvegarde/<date>/` les fichiers remplacés ou supprimés, liste les fichiers modifiés localement et demande confirmation (`--oui` pour un script ; sans terminal, `--oui` est nécessaire), remplace les fichiers du paquet, retire les anciennes arborescences (`core/`, `scripts/`), complète `.gitignore` sans l'écraser, puis propose `make rebuild`. `--sans-reconstruire` saute cette proposition ; sans terminal, la reconstruction n'est jamais lancée.

`workspace/`, `.devzone.modules`, `.devzone.paquets`, `.password`, `.app`, `.devzone.log` et les volumes Docker ne sont jamais touchés.

La mise à jour ne change jamais le mode du poste ; sur un poste Docker avec Kubernetes joignable, elle propose `devzone workspace migrate`.

Dans le conteneur, le récapitulatif `devzone` signale une version publiée plus récente (vérification npm au plus une fois par jour, sans bloquer hors ligne) : `○ devzone X.Y.Z disponible : sur le poste, devzone update`.

## Options

**Mode à la création** : `--kubernetes` (workspace dans le cluster, refusé sans cluster) ou `--docker` (poste Docker, sans contrôle du cluster). Sans option, le mode suit le cluster (voir [Kubernetes ou Docker à la création](#kubernetes-ou-docker-à-la-création)).

**Module `ia`** : active Claude Code et opencode (versions figées), avec le garde-fou repowarden qui les arrête avant de modifier `main` ou `develop` ou de commiter sans `repowarden cc` (voir [manage/docs/reference.md](manage/docs/reference.md#garde-fou-des-assistants-ia)). Pour l'activer : `devzone enable ia`. Ils sont désinstallés quand le module est désactivé, mais tes connexions restent dans leurs volumes.

**Module `kubernetes`** : active à chaque démarrage la connexion au cluster de l'hôte et l'installation de metrics-server sur les clusters locaux (pour voir le CPU et la RAM dans k9s). Pour l'activer : `devzone enable kubernetes`. Sans ce module, kubectl, helm, k9s et kind restent installés.

**Plateforme GitHub ou GitLab** : GitHub par défaut (nouvelle architecture). Pour servir une équipe sur GitLab : `devzone platform gitlab --url URL` (ou sans `--url` quand le module `gitlab` est activé, pour l'instance de test) : glab est installé (version figée, somme vérifiée) et connecté à l'instance, et `devzone` l'affiche à la place des contrôles `gh`. `devzone platform github` revient en arrière (glab retiré). GitLab est accessible directement depuis le poste sans relais temporaire. Détails dans [manage/docs/reference.md](manage/docs/reference.md#plateforme--github-ou-gitlab).

**Module `postgres`** : un PostgreSQL partagé, une base par projet (voir [Accéder à PostgreSQL](#accéder-à-postgresql)). Pour l'activer : `devzone enable postgres`.

**Module `llm`** : un modèle de code local (Qwen2.5-Coder, sur CPU) dans le cluster de devzone, utilisé par opencode quand les modèles en ligne sont épuisés ou injoignables ; premier téléchargement de plusieurs Go (voir [manage/docs/reference.md](manage/docs/reference.md#modèle-de-code-local)). Pour l'activer : `devzone enable llm` (`--preset light` sur une machine juste en mémoire).

**Module `argocd`** : Argo CD sur le cluster de devzone, interface sur https://127.0.0.1:8443 dans le conteneur (voir [Argo CD](manage/docs/reference.md#argo-cd)). Pour l'activer : `devzone enable argocd`.

Ces modules sont désactivés par défaut, activables à la demande depuis le conteneur (sans rebuild), et leur choix est conservé d'un démarrage à l'autre.

La commande `devzone` s'écrit en anglais, sous-commandes et options comprises (`enable`, `disable`, `platform`, `packages`, `update`, `uninstall`, `status`, `use` ; `postgres create`, `packages add`, `gitlab new-password`, `port --close`, `cluster --yes`). Les anciens noms français restent acceptés et écrivent un avertissement ; la table complète est dans [Anciens noms des commandes](manage/docs/reference.md#anciens-noms-des-commandes).

## Où sont mes identifiants ?

Les comptes créés par devzone sont regroupés dans `.password`, à la racine de devzone (à côté de `.devzone.modules`). Une ligne par compte, colonnes séparées par des tabulations :

```text
# service	adresse	utilisateur	mot de passe
gitlab	http://gitlab.localhost:8929	root	…
postgres	127.0.0.1:5432	postgres	…
postgres:monprojet	127.0.0.1:5432/monprojet	monprojet	…
argocd	https://127.0.0.1:8443	admin	…
```

Le fichier est lisible par toi seul (600) et ignoré par git : ne le copie ni ne le commit jamais. Il est régénéré à chaque création, suppression ou changement de compte (modules `gitlab`, `postgres` et `argocd`, seed GitLab, démarrage) :

```sh
devzone passwords                  # régénère le fichier et affiche seulement son chemin
devzone postgres create <projet>         # création, ou nouveau mot de passe avec --new-password
devzone postgres delete <projet>     # suppression du compte et de sa ligne
devzone gitlab new-password [root|dev]  # mot de passe aléatoire (root ou dev) régénéré
```

Les fichiers des modules restent la source : `workspace/.postgres/<projet>.env`, `workspace/.postgres/admin-password`, `workspace/.gitlab/root-password`, `workspace/.gitlab/dev-password` et `workspace/.argocd/admin.env`.

Le secret Rails de GitLab est conservé dans `workspace/.gitlab/rails-secret.yaml` (600) et réappliqué à une réinstallation ; à défaut, si le secret a été perdu, le récapitulatif avertit : « GitLab réinstallé : si le navigateur affiche 422, supprimez les données de site de gitlab.localhost ».

## Accéder à PostgreSQL

Le module `postgres` installe un PostgreSQL 16 partagé sur le cluster de devzone : une base et un utilisateur par projet. Toutes les commandes se lancent dans le conteneur (`make shell`).

```sh
devzone enable postgres          # la première fois : choix du cluster (kind dédié ou cluster de l'hôte)
devzone postgres create monprojet  # base et utilisateur « monprojet »
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

Autres commandes : `devzone postgres list`, `devzone postgres psql monprojet` (console), `devzone postgres delete monprojet`, `devzone cluster [CTX]` (voir ou changer de cluster). Détails dans [manage/docs/reference.md](manage/docs/reference.md#postgresql).

### Voir le contenu de la base

Dans le conteneur :

```sh
devzone postgres list              # les bases et leur propriétaire
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

« Connection refused » : le tunnel ne tourne pas, ou il a été lancé dans le conteneur. Une base recréée (`devzone postgres delete` puis `create`, ou `create --new-password`) a un nouveau mot de passe : à reporter dans le client.

### Droits : un utilisateur par base

L'utilisateur d'un projet possède **sa** base (il y crée tables, index, données) et rien d'autre : il ne peut ni créer une base, ni se connecter à celle d'un autre projet. D'où, dans un client, `[42501] ERROR: permission denied to create database`. C'est voulu (les projets ne se voient pas). Pour une nouvelle base : `devzone postgres create <projet>`, qui donne son propre utilisateur et son fichier `.env`.

> Le module `gitlab` a aussi son propre PostgreSQL (`gitlab-postgresql`) : il appartient à GitLab, n'y mets pas tes bases.

## Voir mon application dans le navigateur

Sur le poste Kubernetes, `devzone workspace start` lance un veilleur de ports : chaque port TCP ≥ 1024 qui écoute dans le pod est relayé sur `127.0.0.1` du poste, au même numéro, par `kubectl port-forward`. Un serveur lancé dans le pod (`npm run dev`, port 5173) répond donc sur `http://localhost:5173`, sans commande. Les services activés (PostgreSQL, MySQL, Argo CD) sont relayés aussi, sur leur port habituel. Le veilleur se pilote avec `devzone workspace ports start|stop|status` ; détails dans la [référence](manage/docs/reference.md#applications-et-services-sur-localhost-du-poste).

Sur le poste Docker, une application lancée **dans** le conteneur (par exemple un Spring Boot avec `./gradlew bootRun` sur le port 8080) n'est pas joignable depuis le poste : le conteneur devzone ne publie aucun port. Dès qu'elle écoute dans le conteneur, le **veilleur de ports automatiques** (`.devcontainer/ports-auto.sh`) pose un relais `alpine/socat` (version figée) sur le Docker de l'hôte, de `127.0.0.1:<port>` du poste vers le port du conteneur : `http://localhost:<port>` **sans commande**. Le relais disparaît quand l'application s'arrête.

```sh
devzone port             # liste : relais manuels et automatiques, ● actif ou ○ arrêté
devzone port auto off    # coupe le veilleur : plus de relais automatique
devzone port --close <n> # retire un relais manuel et son port de l'état
```

`devzone port <n>` ouvre aussi un relais manuel : même mécanisme côté poste, conteneur `alpine/socat`, nom `devzone-<instance>-port-<n>`.

Depuis le poste : `http://localhost:8080`. Le relais manuel est recréé automatiquement au démarrage du conteneur, vers l'adresse actuelle du conteneur ; il est retiré par `make uninstall` (étiquette `devzone.instance`). Le relais automatique disparaît avec l'application.

Spring Boot écoute sur `0.0.0.0` par défaut : ne fixe pas `server.address` à `127.0.0.1`, sinon le relais ne peut pas joindre l'application. Un port déjà pris sur le poste, un port invalide ou un Docker de l'hôte injoignable sont refusés avec un code non nul. Détails dans [manage/docs/reference.md](manage/docs/reference.md#ports-vers-le-poste).

## Questions fréquentes

- **Docker absent ou arrêté** : `npx devzone`, `make up`, `make rebuild` et `make uninstall` vérifient Docker avant tout et disent quoi faire : l'installer (Docker Desktop, ou Docker Engine sous Linux), démarrer Docker Desktop, ou, sous Linux, ajouter ton compte au groupe `docker` (`sudo usermod -aG docker $USER`, puis une nouvelle session). Avec `npx devzone mon-devzone`, le dossier est créé quand même : une fois Docker démarré, `cd mon-devzone && make shell`.
- **Accès au socket Docker de l'hôte** : le socket Docker de la machine hôte est monté dans le conteneur. Cela offre un accès administrateur au Docker de l'hôte, y compris pour les agents IA. C'est un compromis de sécurité assumé documenté dans la section Limites. Pour restreindre l'accès, utilisez les mécanismes propres à Docker Desktop/Linux.
- **Le premier lancement est long** : c'est normal (construction de l'image, téléchargement des images de base). Il prend 4 à 5 min mesurées, plus le téléchargement des images de base sur une machine neuve.
- **`make` est absent sous Windows** : tu peux utiliser `npx @devcontainers/cli` (voir le tableau « Au quotidien ») ou Git Bash. Les scripts sont compatibles (fins de ligne LF).
- **Le cluster Kubernetes ne répond pas** : devzone ne crée jamais de cluster. À la création, sans cluster qui répond (en 5 s), le poste devient un poste Docker et l'annonce :

  ```text
  ⚠ Kubernetes not reachable: cluster <contexte> unreachable (<serveur>). Docker workstation; later: devzone workspace migrate
  ```

  Avec `--kubernetes`, rien n'est créé et la commande échoue. Ensuite, `devzone workspace start` (donc `make up` et `make shell`) vérifie le cluster en premier et s'arrête sans rien modifier. Le message dit la cause :

  - **Docker Desktop arrêté** : `✖ Docker Desktop is stopped: the Kubernetes cluster of this machine runs inside it. Start Docker Desktop, then: make shell`. Lance Docker Desktop, puis `make shell`. Pour qu'il démarre à chaque connexion : *Settings → General → Start Docker Desktop when you sign in*.
  - **Docker répond, pas le cluster** : `✖ Kubernetes cluster <contexte> unreachable (<serveur>): enable Kubernetes in Docker Desktop (Settings → Kubernetes) or check kubectl config get-contexts`. Active Kubernetes dans Docker Desktop (*Settings → Kubernetes → Enable Kubernetes*).
  - **Autre cluster** : `✖ Kubernetes cluster <contexte> unreachable (<serveur>)`, suivi de `Check the contexts: kubectl config get-contexts`. Vérifie le contexte choisi, ou change-le avec `devzone use CTX`.

  Détails dans la [référence](manage/docs/reference.md#le-cluster-ne-répond-pas).
- **Problème d'identité git pour commiter** : règle-la une seule fois. Avec GitHub : `gh auth login -s workflow` (l'identité est déduite automatiquement). Sans GitHub : `git config --file ~/.config/git/config user.name "<nom>"` et `git config --file ~/.config/git/config user.email "<email>"`.
- **`make up` semble bloqué** : il affiche ses étapes et un signe de vie au moins toutes les 30 s ; le journal complet est dans `.devzone.log`.

## Changer de cluster

```sh
devzone clusters                    # vue : contextes, type, état, namespace
devzone use CTX [-n NS]        # bascule le cluster de travail de kubectl
devzone use -n NS              # change seulement le namespace du cluster courant
```

L'invite du shell affiche `⎈ ctx/ns` (cyan si local, rouge gras avec distant sinon). Un rebuild repart sur le cluster de l'hôte : le choix de kubectl est écrit dans `~/.kube/config`, qui n'est pas dans un volume.

## Désinstaller

```bash
make uninstall
```

Cette commande supprime le conteneur, l'image `vsc-devzone-…`, les volumes `devzone-*`, les events du Docker de l'hôte et les clusters kind créés sur l'hôte, les namespaces `devzone-postgres` et les étiquettes `app.kubernetes.io/managed-by=devzone` sur les clusters de l'hôte, ainsi que les éventuels metrics-server installés par devzone. Les ressources sont filtrées par l'étiquette `devzone.instance` pour ne cibler que l'instance courante. Elle **ne touche jamais** à `workspace/` (tes projets). Pour garder tes connexions (GitHub, git, Claude Code, opencode et modules) : `make uninstall KEEP=logins` (ancien `GARDER=connexions` accepté).

Avec la commande installée globalement (`npm install -g devzone`), tu peux aussi lancer, dans le dossier du devzone :

```bash
devzone uninstall
```

Même effet que `make uninstall`. Ensuite seulement, pour retirer la commande de ta machine :

```bash
npm uninstall -g devzone
```

Cette commande retire seulement la commande `devzone` de ta machine ; elle ne supprime ni conteneur, ni volume, ni dossier.

## Pour aller plus loin

- [Référence détaillée](https://github.com/SimBienvenueHoulBoumi/devzone/blob/main/manage/docs/reference.md)
- [Contribuer](https://github.com/SimBienvenueHoulBoumi/devzone/blob/main/manage/docs/contribuer.md) : tests, processus de livraison et organisation

## Licence

devzone est un logiciel libre, distribué sous la [GNU General Public License version 3](https://github.com/SimBienvenueHoulBoumi/devzone/blob/main/LICENSE).

