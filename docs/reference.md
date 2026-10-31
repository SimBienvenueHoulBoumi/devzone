# Référence détaillée

## Connexions et identité

**GitHub (facultatif)** : sert à pousser et ouvrir des PR sur GitHub, aux tickets et bots repowarden, et donne l'identité git automatiquement. Sans GitHub, git fonctionne normalement (dépôts locaux, autre hébergeur) ; seule l'identité se règle à la main. Pour l'utiliser : `gh auth login -s workflow`. Git passe alors par le jeton de `gh` (https, même pour les remotes en `git@github.com:`), sans clé ssh à recopier. Les dépôts de `/workspaces/devzone` sont déclarés sûrs (`safe.directory`).
- **Permission `workflow`** : sans elle, GitHub refuse tout push qui modifie `.github/workflows/` (fréquent avec repowarden). Compte déjà connecté : `gh auth refresh -h github.com -s workflow`.
- **Depuis `make shell`**, aucun navigateur ne s'ouvre depuis le conteneur : copier le code affiché par `gh` et ouvrir https://github.com/login/device à la main. L'avertissement « No clipboard utilities available » est sans conséquence.

**Identité git** (nécessaire pour commiter) : sans GitHub, à régler à la main (`git config --file ~/.config/git/config user.name "<nom>"` et `user.email "<email>"`) ; avec GitHub, déduite du compte `gh` à chaque démarrage, tant qu'elle manque (`git-identite.sh`) :
- nom du profil GitHub (sinon le login) ;
- email noreply `<id>+<login>@users.noreply.github.com` : les commits sont rattachés au compte, l'email personnel n'est pas exposé.

Une identité déjà définie n'est jamais remplacée. Pour un autre email : `git config --file ~/.config/git/config user.email "<email>"`. Après un `gh auth login` en cours de session : `bash .devcontainer/git-identite.sh`.

**Assistants IA** (module `ia`, voir [Modules](#modules)) : `devzone activer ia`, puis `claude` (puis `/login`), `opencode auth login`.

Les connexions (**GitHub**, **git**, **Claude Code**, **opencode**) et les caches (**Maven**, **pnpm**) sont **partagés volontairement** entre les devzone d'une machine : elles vivent dans les volumes Docker (voir [Données conservées](#données-conservées)). Le dépôt ne contient aucun identifiant.



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

### Worktrees git

**Règle** : un dépôt du workspace se manipule d'un seul côté. Les worktrees se créent **et** se suppriment dans le conteneur (`git worktree add`, `git worktree remove`) ; ne jamais lancer `git worktree prune` sur la machine hôte, ni laisser un outil de l'hôte le faire (VS Code, GitHub Desktop…).

**Pourquoi** : le workspace est monté depuis l'hôte (`/Users/…/devzone` sur Mac → `/workspaces/devzone`). git enregistre le chemin **absolu** de chaque worktree dans `.git/worktrees/<nom>/gitdir` : `/workspaces/…` pour un worktree créé dans le conteneur, `/Users/…` pour un worktree créé sur le Mac. Vu de l'autre côté, ce chemin n'existe pas : le worktree paraît « prunable », et un `git worktree prune` efface ses métadonnées, ce qui casse le worktree là où il a été créé.

**Signalement** : l'état affiché au démarrage (et par `devzone`) liste, sans rien supprimer, les worktrees du dépôt devzone et des dépôts du workspace dont le chemin n'existe pas dans le conteneur : `⚠ worktree        /Users/…/wt-42 absent ici (créé hors du conteneur ?) : …`. Le gérer depuis le côté qui l'a créé (le supprimer là-bas avec `git worktree remove`, puis le recréer dans le conteneur si besoin).



## Modules

Les fonctionnalités facultatives sont des modules, **désactivés par défaut**, activés à la demande depuis le conteneur, sans rebuild :

```bash
devzone                        # état : identité git, GitHub, outils, modules
devzone activer <module>       # active et applique tout de suite
devzone desactiver <module>    # désactive et applique tout de suite
```

| Module | Activé | Désactivé |
|---|---|---|
| `ia` | Claude Code et opencode installés (versions figées), réinstallés à chaque rebuild, avec le [garde-fou repowarden](#garde-fou-des-assistants-ia) et une [configuration opencode par défaut](#configuration-dopencode) ; se connecter : `claude` (puis `/login`), `opencode auth login` | désinstallés ; les connexions restent dans leurs volumes, le garde-fou aussi (sans effet sans les assistants) |
| `kubernetes` | à chaque démarrage : connexion au cluster de ta machine et metrics-server sur les clusters locaux (CPU et RAM dans k9s) | aucune connexion au cluster de ta machine ; kubectl, helm, k9s et kind restent installés, un cluster kind créé à la main reste utilisable ; metrics-server n'est pas retiré des clusters où il a été installé |

Le choix est **propre à chaque devzone** (instance) et gardé dans le dossier `$RACINE/.devzone.modules` (monté de l'hôte, il survit aux rebuilds). Au premier démarrage d'une instance, si une connexion Claude Code ou opencode existe déjà dans les volumes, le module `ia` n'est pas activé : tout est désactivé par défaut et la connexion est signalée (« devzone activer ia pour l'utiliser ici »).

### Garde-fou des assistants IA

Avec le module `ia` actif, devzone branche le [garde-fou de repowarden](https://github.com/simdevWarden/repowarden/blob/main/docs/agents.md) pour Claude Code et opencode (`repowarden agents init --global`, à l'activation et à chaque démarrage ; relancé, rien ne change). Dans **tout dépôt** du conteneur, l'agent est arrêté **avant** son action, avec la commande repowarden à lancer à la place, quand il veut modifier `main` ou `develop`, commiter sans `repowarden cc` ou contourner les hooks (`--no-verify`).

- **Où** : `~/.claude/settings.json` (hook `PreToolUse`) et `~/.config/opencode/plugins/repowarden-garde.js`, dans les volumes : gardés aux rebuilds. Un réglage déjà présent est complété, jamais écrasé.
- **Le voir à l'œuvre** : dans un dépôt sur `main`, demander à l'assistant de modifier un fichier : il est refusé (« branche protégée ») avec la commande à lancer.
- **Limites** : un filet, pas un mur. Une modification faite par le shell (`sed -i`, redirection `>`, script) n'est vue qu'au commit, par les hooks ; une commande cachée dans `bash -c "…"` n'est pas vue. Sans `repowarden` ni `jq`, rien n'est bloqué. `devzone desactiver ia` laisse le garde-fou en place, sans effet sans les assistants.

### Configuration d'opencode

Avec le module `ia`, devzone écrit une configuration opencode prête à l'emploi dans `~/.config/opencode/opencode.jsonc` (volume `devzone-opencode-config`) : modèles gratuits par rôle (`build`, `plan`, `general`, `explore`, titre, résumé, compaction), partage et mises à jour désactivés. Elle est mise à jour à chaque `devzone activer ia` et à chaque démarrage, tant que sa première ligne repère `// devzone : configuration opencode par défaut …` est présente.

- **Permissions par défaut** : ce qui sert au travail est permis sans question (`edit`, `git`, `repowarden`, `gh` en lecture, lecture et recherche, fichiers du projet, tests, linters et build) ; le reste demande ton accord (`ask`, dont `webfetch`) ; les fuites possibles de secrets sont interdites (`deny`) : `gh auth token`, `gh auth status --show-token`, `~/.config/gh/hosts.yml`, `*.credentials*`, `auth.json`, `~/.ssh/*`, l'environnement (`env`, `printenv`, `set`, `export -p`), `curl`/`wget`, `nc`, `ssh`, `scp`, `sudo`, `rm -rf /` et les push forcés. Le dernier motif qui correspond l'emporte : les `deny` sont en fin de liste.
- **Pourquoi `curl`/`wget` sont interdits** : une requête peut envoyer des données (jeton, fichier) vers l'extérieur. Le réseau passe par `webfetch`, qui reste disponible après ton accord.
- **La personnaliser** : retirer cette ligne repère. devzone la garde alors telle quelle, et signale « configuration personnalisée, gardée » ; pour élargir, y ajouter un `allow` (par exemple une commande de plus).
- **Changer de modèle** : modifier `model` (modèle par défaut), `small_model` (titre) et les `agent` concernés ; `opencode models` liste les modèles disponibles.
- **Fournisseur payant** : `opencode auth login` (la connexion reste dans le volume `devzone-opencode-data`).
- **Lancer opencode en tâche de fond** : `opencode run --auto "…" < /dev/null`. Sans `--auto`, toute demande de permission est refusée d'office et l'agent s'arrête ; sans `< /dev/null`, il attend son entrée et reste muet.



## Plusieurs devzone sur une machine

Plusieurs devzone peuvent cohabiter sur une même machine (un par projet, un par usage) : chaque instance est un dossier du workspace, avec son propre état et ses propres modules.

- **Modules** : **propres à chaque devzone**. L'état vit dans le dossier de l'instance (`$RACINE/.devzone.modules`), monté de l'hôte : un second devzone démarre avec des valeurs par défaut, sans hériter de ceux du premier (un ancien état global, au premier devzone démarré après la mise à jour, est repris une fois, par déplacement).
- **Connexions** (**GitHub**, **git**, **Claude Code**, **opencode**) et **caches** (**Maven**, **pnpm**) : **partagés volontairement** entre les devzone d'une machine, dans les volumes `devzone-*`.
- **Isolation complète** : `DEVZONE_VOLUMES=<préfixe>` (comme pour les tests) donne à chaque devzone ses propres volumes.


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
- **Clusters kind** : tournent dans le Docker interne, redémarrent avec le conteneur, sont conservés par `make rebuild` et `make down` ; supprimés par `kind delete cluster` (ou `make desinstaller`).
- **CPU et RAM dans k9s** (`kubectl top`) : module `kubernetes` actif, metrics-server est installé au démarrage sur les clusters **locaux** qui ne l'ont pas (Docker Desktop, kind…), jamais sur un cluster distant. Après un `kind create cluster` : `bash .devcontainer/metrics-server.sh` (ou `… metrics-server.sh <contexte>` pour un cluster précis).
- **Cluster de l'hôte** : `~/.kube` est monté en lecture seule, jamais modifié ; sa copie adaptée est `~/.kube/hote.config` (`127.0.0.1` remplacé par `host.docker.internal`). Après un changement de cluster sur l'hôte : `make stop && make up`.
- **Messages de démarrage** (`kube-config : …`, `metrics-server : …`, récapitulatif) : dans le terminal de création, ou en relançant `bash .devcontainer/demarrage.sh`.

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
| `devzone-config` | modules activés (`devzone activer`) : ancien état utilisateur, repris une fois | gardé | gardé | gardé |
| `devzone-m2`, `devzone-pnpm` | caches Maven (`~/.m2`) et pnpm | gardé | gardé | gardé |
| volume du Docker interne | images Docker et clusters kind du conteneur | gardé | gardé | gardé |
| `workspace/` (dossier de l'hôte) | tes projets | gardé | gardé | gardé |

Tout le reste du conteneur (paquets installés à la main, fichiers hors de ces emplacements) est perdu à `make down` et `make rebuild`. Le Docker interne est isolé : ses images ne sont pas partagées avec Docker Desktop.



## Mettre à jour un outil

| Outil | Où | Puis |
|---|---|---|
| k9s, actionlint, gitleaks, kind | `.devcontainer/Dockerfile` : `ARG …_VERSION` **et** les empreintes `sha256` (arm64 + amd64) | `make rebuild` |
| uv, ruff, vulture, pytest | `.devcontainer/Dockerfile` : `ARG …_VERSION` | `make rebuild` |
| repowarden | `.devcontainer/post-create.sh` : `repowarden@x.y.z` | `devzone appliquer` (ou `make rebuild`) |
| Claude Code, opencode | `.devcontainer/devzone` : une ligne par paquet, `IA_CLAUDE=@anthropic-ai/claude-code@x.y.z` et `IA_OPENCODE=opencode-ai@x.y.z` | `devzone activer ia` (ou `make rebuild`) |
| metrics-server | `.devcontainer/metrics-server.sh` : `VERSION` | `bash .devcontainer/metrics-server.sh` sur un nouveau cluster |
| Java, Node, Python, Docker, kubectl, helm, gh | `.devcontainer/devcontainer.json` (features), versions figées dans `devcontainer-lock.json` | `npx @devcontainers/cli upgrade --workspace-folder .` puis `make rebuild` |

Empreinte d'une archive : `curl -fsSL <url> | shasum -a 256`.

**Montées automatiques** : les versions de `repowarden` et des assistants IA (`IA_CLAUDE`, `IA_OPENCODE`) sont comparées toutes les heures à npm par le workflow `versions` (`.github/workflows/versions.yml`). Pour chaque paquet en retard, il ouvre ou met à jour un ticket, y propose une conception (« Conception proposée »), crée sa branche, applique la montée (`core/scripts/versions.sh --appliquer`), commit et pousse : la PR brouillon s'ouvre et la CI teste le conteneur. Le mainteneur confirme la conception sur le ticket (« Conception retenue », attendue par la vérification `ticket`), puis passe la PR en ready. Une ligne par paquet : deux montées ouvertes en même temps (Claude Code et opencode) se fusionnent l'une après l'autre sans conflit. À la main : *Actions → versions → Run workflow* ; en local, `bash core/scripts/versions.sh` liste les paquets en retard. Sans nouvelle version, le job s'arrête après la comparaison ; pas de déclenchement croisé depuis repowarden, qui demanderait un jeton d'un autre propriétaire.

**Rattraper sans rebuild** : l'état affiché au démarrage (et par `devzone`) compare les outils installés à leur version figée. Une ligne `⚠ outils          repowarden 4.9.2 installé, 4.12.0 figé : devzone appliquer` signale un écart ; `devzone appliquer` réinstalle repowarden à la version figée et les modules actifs. `✔ outils          versions figées` indique que tout correspond. Les outils installés par `apt` ou l'image (Java, Node, Python, …) ne sont pas concernés.



## Dépannage

| Symptôme | Cause | Solution |
|---|---|---|
| `✖ Docker introuvable` (`npx devzone`, `make up`, `make rebuild`, `make desinstaller`) | Docker n'est pas installé | installer Docker Desktop (macOS, Windows, Linux : https://docs.docker.com/desktop/) ou, sous Linux, Docker Engine (https://docs.docker.com/engine/install/), puis relancer la commande |
| `✖ Docker est installé mais ne répond pas (arrêté ?)` | Docker Desktop fermé, ou service Docker arrêté (Linux) | démarrer Docker Desktop (Linux sans Docker Desktop : `sudo systemctl start docker`), puis relancer la commande. Après `npx devzone mon-devzone`, le dossier est déjà créé : `cd mon-devzone && make shell` |
| `✖ Docker refuse l'accès` | Linux : compte hors du groupe `docker` | `sudo usermod -aG docker $USER`, puis une nouvelle session (ou `newgrp docker`), puis relancer la commande |
| `make up` ou `make rebuild` semble figé | une étape longue (première construction de l'image : plusieurs minutes), ou une question posée dans le conteneur | `make` affiche un signe de vie avec la dernière ligne du journal au moins toutes les 30 s : suivre le détail avec `tail -f .devzone.log`. Une question (ligne finissant par `[o/N]`, `?`…) est signalée et le lancement arrêté : la [signaler](https://github.com/SimBienvenueHoulBoumi/devzone/issues), puis `make rebuild`. Version antérieure de devzone, figée sur « Configurer les bots … ? [o/N] » (invisible) : `Ctrl+C`, mettre devzone à jour puis `make rebuild` ; les bots se configurent à la main dans le conteneur : `repowarden bots` |
| `git push` refusé : « refusing to allow an OAuth App to create or update workflow … without `workflow` scope » | jeton `gh` sans la permission `workflow` | `gh auth refresh -h github.com -s workflow` |
| `devzone` affiche `⚠ worktree … absent ici` ; ou un worktree cassé (« not a git repository: …/.git/worktrees/… ») | worktree créé de l'autre côté (hôte ↔ conteneur), ou métadonnées effacées par un `git worktree prune` lancé de l'autre côté | voir [Worktrees git](#worktrees-git) : gérer chaque worktree du côté qui l'a créé, jamais `git worktree prune` sur l'hôte |
| PR bloquée, run `action_required`, bandeau « Approve workflows to run » | PR ouverte ou poussée par le bot `github-actions` : pour les événements `pull_request` `opened`, `synchronize` et `reopened`, GitHub attend l'accord d'une personne ayant l'écriture ([doc GitHub](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow)) | vérifier les changements (surtout `.github/workflows/`), puis *Approve workflows to run* ; pour ne plus avoir à le faire : `repowarden app init` dans le projet |
| PR de livraison bloquée : « aucune préversion vX.Y.Z-next.N » | la préversion n'est pas encore publiée (sans `preversion-on-push`, elle part le soir) | attendre celle du soir, *Actions → release → Run workflow* sur `develop`, `preversion-on-push: true`, ou ne plus l'exiger : `preversion-obligatoire: false` |
| PR de livraison restée ouverte | une vérification rouge (voir la PR), `delivery-auto: false`, ou GitHub App absente ou désinstallée (avertissement dans le run `release`) | corriger la vérification ; installer l'App (`repowarden app init` sur ta machine) |
| `repowarden app init` depuis `make shell` : la page `http://127.0.0.1:…` ne s'ouvre pas, ou GitHub ne revient pas | la page est servie dans le conteneur, injoignable depuis le navigateur de ta machine | lancer la commande **sur ta machine** : `npx -y repowarden app init --repo <compte>/<dépôt>` |
| `repowarden app init` : « nom déjà utilisé » | un essai précédent a créé l'App sans en récupérer les identifiants | supprimer l'App orpheline (*GitHub → Settings → Developer settings → GitHub Apps*), ou `--nom <autre-nom>` |
| `git commit` : « Please tell me who you are » | identité git absente | avec GitHub : `gh auth login -s workflow` puis `bash .devcontainer/git-identite.sh` ; sans GitHub : `git config --file ~/.config/git/config user.name "<nom>"` et `user.email "<email>"` |
| `gh auth login` : « Press Enter to open … in your browser », rien ne s'ouvre | pas de navigateur dans le conteneur (`make shell`) | ouvrir https://github.com/login/device à la main et saisir le code |
| `k9s` : `Error: exit status 1` puis son aide ; `kubectl` : `localhost:8080` … `connection refused` | aucun cluster actif (module `kubernetes` désactivé, ou pas de cluster sur ta machine) | `devzone activer kubernetes` (cluster de ta machine), `kind create cluster`, ou `kubectl config use-context <nom>` |
| `claude` ou `opencode` : « command not found » | module `ia` désactivé | `devzone activer ia` |
| `devzone` affiche `✖ module ia         en échec : installation incomplète (journal npm : …)` | l'installation de Claude Code ou d'opencode a échoué (réseau, paquet) ; le message d'échec nomme les paquets et le journal npm | lire le journal cité, puis `devzone appliquer` pour réessayer (ou `devzone desactiver ia`) |
| `devzone activer ia` ou `devzone appliquer` sans rien afficher de neuf pendant plusieurs minutes | installation de Claude Code et opencode (plusieurs centaines de Mo) : annoncée, puis une ligne `… toujours en cours (N s)` toutes les 30 s | attendre la ligne `Claude Code et opencode installés` ou le message d'échec |
| CPU et RAM vides dans k9s | metrics-server absent du cluster | `bash .devcontainer/metrics-server.sh` |
| Deux conteneurs devzone | `make up` lancé pendant que VS Code ouvrait le conteneur | `make down`, puis un seul lancement |
| Windows (Git Bash, MSYS) : `~/.kube` introuvable | `HOME` et `USERPROFILE` concaténés dans le chemin monté | lancer depuis VS Code ou PowerShell |
| Pas de `~/.kube` sur l'hôte | Docker le crée vide au démarrage (sous Linux avec Docker Engine, il appartient à root) | rien à faire : le conteneur démarre quand même |

