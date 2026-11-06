# Référence détaillée

## Connexions et identité

**GitHub (facultatif)** : sert à pousser et ouvrir des PR sur GitHub, aux tickets et bots repowarden, et donne l'identité git automatiquement. Sans GitHub, git fonctionne normalement (dépôts locaux, autre hébergeur) ; seule l'identité se règle à la main. Pour l'utiliser : `gh auth login -s workflow`. Git passe alors par le jeton de `gh` (https, même pour les remotes en `git@github.com:`), sans clé ssh à recopier. Les dépôts de `/workspaces/devzone` sont déclarés sûrs (`safe.directory`).
- **Permission `workflow`** : sans elle, GitHub refuse tout push qui modifie `.github/workflows/` (fréquent avec repowarden). Compte déjà connecté : `gh auth refresh -h github.com -s workflow`.
- **Depuis `make shell`**, aucun navigateur ne s'ouvre depuis le conteneur : copier le code affiché par `gh` et ouvrir https://github.com/login/device à la main. L'avertissement « No clipboard utilities available » est sans conséquence.

**Identité git** (nécessaire pour commiter) : sans GitHub, à régler à la main (`git config --file ~/.config/git/config user.name "<nom>"` et `user.email "<email>"`) ; avec GitHub, déduite du compte `gh` à chaque démarrage, tant qu'elle manque (`git-identite.sh`) :
- nom du profil GitHub (sinon le login) ;
- email noreply `<id>+<login>@users.noreply.github.com` : les commits sont rattachés au compte, l'email personnel n'est pas exposé.

Une identité déjà définie n'est jamais remplacée. Pour un autre email : `git config --file ~/.config/git/config user.email "<email>"`. Après un `gh auth login` en cours de session : `devzone demarrer`.

**Assistants IA** (module `ia`, voir [Modules](#modules)) : `devzone activer ia`, puis `claude` (puis `/login`), `opencode auth login`.

Les connexions (**GitHub**, **git**, **Claude Code**, **opencode**) et les caches (**Maven**, **Gradle**, **pnpm**) sont **partagés volontairement** entre les devzone d'une machine : elles vivent dans les volumes Docker (voir [Données conservées](#données-conservées)). Le dépôt ne contient aucun identifiant.



## Plateforme : GitHub ou GitLab

devzone est pensé pour GitHub ; `devzone plateforme` choisit celle à laquelle la CLI se connecte (`github` par défaut, comportement actuel, rien ne change) :

```bash
devzone plateforme                  # affiche la plateforme et son état
devzone plateforme github           # retour à GitHub : glab et sa configuration retirés
devzone plateforme gitlab --url https://gitlab.example.com:3443
devzone plateforme gitlab           # sans --url : l'instance du module gitlab (http://gitlab.localhost:8929)
```

- **Choix par instance** : gardé aux rebuilds dans le fichier d'état (`$RACINE/.devzone.modules`, lignes `plateforme=` et `gitlab_url=`), comme les [modules](#modules).
- **glab** (CLI GitLab), installé **seulement** quand GitLab est choisi : binaire de la release officielle de gitlab.org (chart de gitlab-org/cli), version figée et somme SHA-256 vérifiées, dans `~/.local/bin` ; au retour à `github`, le binaire et sa configuration (`~/.config/glab-cli/`) sont retirés — la configuration d'un service n'existe que pendant qu'il est choisi.
- **Connexion** : instance du module `gitlab` → automatique, avec le jeton root du module (`workspace/.gitlab/`, protocole http, jamais affiché) ; autre instance (gitlab.com ou auto-hébergée) → `glab auth login --hostname <hôte>`, interactif (code de connexion à saisir).
- **État** : la ligne `plateforme` affiche l'instance et « glab connecté », ou « non connecté » avec la commande à lancer. Avec `gitlab`, les lignes propres à GitHub signalent qu'elles ne s'appliquent pas : repowarden (bots, tickets, workflows du dépôt devzone) reste uniquement sur GitHub en attendant son support GitLab ([simdevWarden/repowarden#531](https://github.com/simdevWarden/repowarden/issues/531)). `gh` connecté reste utile pour ces tickets.
- **Instance de test** : le [module gitlab](#gitlab) fournit l'instance locale du conteneur (utilisateur `root`, secrets dans `workspace/.gitlab/`) ; dès qu'il est actif, `devzone plateforme gitlab` (sans `--url`) la cible d'office.
- **Mise à jour de glab** : dans `.devcontainer/devzone`, `GLAB_VERSION` et les deux sommes `GLAB_SOMME_ARM64` / `GLAB_SOMME_AMD64` (checksums.txt de la release), puis `devzone plateforme gitlab --url URL` (glab est re-téléchargé seulement s'il est absent ou cassé : le retirer d'abord, `rm ~/.local/bin/glab`).



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
| `ia` | Claude Code et opencode installés (versions figées), réinstallés à chaque rebuild, avec le [garde-fou repowarden](#garde-fou-des-assistants-ia) et une [configuration opencode par défaut](#configuration-dopencode) ; se connecter : `claude` (puis `/login`), `opencode auth login` | désinstallés ; le garde-fou (hook et plugin) et la configuration opencode par défaut sont retirés ; l'état de `devzone agent` (volume partagé), les journaux `workspace/.agents/` et les connexions restent |
| `kubernetes` | à chaque démarrage : connexion au cluster de ta machine et metrics-server sur les clusters locaux (CPU et RAM dans k9s) | aucune connexion au cluster de ta machine ; kubectl, helm, k9s et kind restent installés, un cluster kind créé à la main reste utilisable ; metrics-server est retiré des clusters où devzone l'a installé |
| `gitlab` | GitLab CE de test dans un cluster kind `gitlab` (chart figé), runner Kubernetes, projet `devzone/demo` avec pipeline ; http://gitlab.localhost:8929 ; au moins 8 Go de RAM libre (voir [GitLab](#gitlab)) | cluster `gitlab`, contexte `kind-gitlab` et secrets `workspace/.gitlab/` retirés ; rien d'autre touché |
| `postgres` | PostgreSQL 16 partagé sur le [cluster de devzone](#cluster-de-devzone), une base par projet (`devzone postgres creer <projet>`), joignable sur `127.0.0.1:5432` dans le conteneur (voir [PostgreSQL](#postgresql)) | namespace `devzone-postgres` (toutes les bases) et secrets `workspace/.postgres/` supprimés, après confirmation en terminal ; kind dédié supprimé s'il ne sert plus |

Le choix est **propre à chaque devzone** (instance) et gardé dans le dossier `$RACINE/.devzone.modules` (monté de l'hôte, il survit aux rebuilds). Au premier démarrage d'une instance, si une connexion Claude Code ou opencode existe déjà dans les volumes, le module `ia` n'est pas activé : tout est désactivé par défaut et la connexion est signalée une seule fois (« devzone activer ia pour l'utiliser ici »), pas pour un état repris.

### Commandes de l'application

Les scripts internes de `.devcontainer/` ne sont pas des commandes utilisateur : `devzone` les enveloppe.

```bash
devzone reparer                 # relance relais Docker, gitlab, postgres, ports et identifiants
devzone demarrer                # démarrage complet (identité git, clusters, relais, récapitulatif)
devzone metrics [contexte…]     # installe metrics-server sur un cluster local
devzone utiliser CTX [--confirmer CTX]  # bascule le cluster de travail de kubectl
devzone clusters                       # vue des clusters connectes (travail et services)
```

`reparer` affiche `✔` ou `✖` par élément et rend le code 1 dès qu'un élément échoue. `utiliser` ne modifie jamais le [cluster des services](#cluster-de-devzone) (aucune ligne `cluster=`) : un cluster distant exige `--confirmer CTX` hors terminal.

### Garde-fou des assistants IA

Avec le module `ia` actif, devzone branche le [garde-fou de repowarden](https://github.com/simdevWarden/repowarden/blob/main/docs/agents.md) pour Claude Code et opencode (`repowarden agents init --global`, à l'activation et à chaque démarrage ; relancé, rien ne change). Dans **tout dépôt** du conteneur, l'agent est arrêté **avant** son action, avec la commande repowarden à lancer à la place, quand il veut modifier `main` ou `develop`, commiter sans `repowarden cc` ou contourner les hooks (`--no-verify`).

- **Où** : `~/.claude/settings.json` (hook `PreToolUse`) et `~/.config/opencode/plugins/repowarden-garde.js`, dans les volumes : gardés aux rebuilds. Un réglage déjà présent est complété, jamais écrasé.
- **Le voir à l'œuvre** : dans un dépôt sur `main`, demander à l'assistant de modifier un fichier : il est refusé (« branche protégée ») avec la commande à lancer.
- **Limites** : un filet, pas un mur. Une modification faite par le shell (`sed -i`, redirection `>`, script) n'est vue qu'au commit, par les hooks ; une commande cachée dans `bash -c "…"` n'est pas vue. Sans `repowarden` ni `jq`, rien n'est bloqué. `devzone desactiver ia` retire le garde-fou (hook et plugin) et la configuration opencode par défaut ; l'état de `devzone agent`, les journaux `workspace/.agents/` et les connexions restent.

### Configuration d'opencode

Avec le module `ia`, devzone écrit une configuration opencode prête à l'emploi dans `~/.config/opencode/opencode.jsonc` (volume `devzone-opencode-config`) : modèles gratuits par rôle (`build`, `plan`, `general`, `explore`, titre, résumé, compaction), partage et mises à jour désactivés. Elle est mise à jour à chaque `devzone activer ia` et à chaque démarrage, tant que sa première ligne repère `// devzone : configuration opencode par défaut …` est présente.

- **Permissions par défaut** : ce qui sert au travail est permis sans question (`edit`, `git`, `repowarden`, `gh` en lecture, lecture et recherche, fichiers du projet, tests, linters et build) ; le reste demande ton accord (`ask`, dont `webfetch`) ; les fuites possibles de secrets sont interdites (`deny`) : `gh auth token`, `gh auth status --show-token`, `~/.config/gh/hosts.yml`, `*.credentials*`, `auth.json`, `~/.ssh/*`, l'environnement (`env`, `printenv`, `set`, `export -p`), `curl`/`wget`, `nc`, `ssh`, `scp`, `sudo`, `rm -rf /` et les push forcés. Le dernier motif qui correspond l'emporte : les `deny` sont en fin de liste.
- **Pourquoi `curl`/`wget` sont interdits** : une requête peut envoyer des données (jeton, fichier) vers l'extérieur. Le réseau passe par `webfetch`, qui reste disponible après ton accord.
- **La personnaliser** : retirer cette ligne repère. devzone la garde alors telle quelle, et signale « configuration personnalisée, gardée » ; pour élargir, y ajouter un `allow` (par exemple une commande de plus).
- **Changer de modèle** : modifier `model` (modèle par défaut), `small_model` (titre) et les `agent` concernés ; `opencode models` liste les modèles disponibles.
- **Fournisseur payant** : `opencode auth login` (la connexion reste dans le volume `devzone-opencode-data`).
- **Lancer opencode en tâche de fond** : `opencode run --auto "…" < /dev/null`. Sans `--auto`, toute demande de permission est refusée d'office et l'agent s'arrête ; sans `< /dev/null`, il attend son entrée et reste muet.

### Diriger opencode

Claude Code est le **lead** (conception, consignes, relecture, essais, push, suivi CI) ; opencode est le **développeur** (code, tests, commit `repowarden cc`). Plusieurs sessions opencode tournent en parallèle, une par ticket et par worktree.

```bash
devzone agent <dossier> <fichier-consigne>    # au premier plan
devzone agent <dossier> <fichier-consigne> &  # plusieurs en parallèle (ou nohup)
devzone agent etat                            # sessions, modèles écartés et leur cause
devzone agent liberer <modèle>|--tous        # lève un écart de modèle
```

- **Lancement** : `opencode run --auto -m opencode/<modèle> "<consigne>" < /dev/null` dans le dossier. Le journal est `workspace/.agents/<nom du dossier>.log` (état de devzone, hors dépôt, ignoré par git). `--auto` évite l'attente d'une permission ; `< /dev/null` évite une session muette.
- **Rotation des modèles gratuits** : `opencode models opencode` fournit la liste (`*-free`, `big-pickle`), avec une liste figée de secours. Un rang partagé et verrouillé fait commencer chaque lancement au modèle suivant : deux sessions simultanées partent sur deux modèles différents.
- **Bascule** selon la cause de l'échec. Le message n'est cherché que dans les 30 dernières lignes de la tentative et seulement si le code de sortie est non nul ou si opencode a écrit sa ligne d'erreur : du code affiché qui contient « Free usage limit » et finit normalement n'est pas un échec.
  - **pays** (« not available in your country ») : modèle écarté 7 jours ;
  - **quota** (« Free usage limit »), **filtre** (« content filter ») et **muet** (rien écrit en 45 s au départ) : modèle écarté 1 h ;
  - **réseau** (`ENOTFOUND`, `ECONNREFUSED`, `ETIMEDOUT`…) : retenu seulement si le réseau est coupé au moment de l'erreur, sinon traité comme **autre**. Aucun écart. devzone attend le retour du réseau (essai toutes les 30 s, 30 min au plus, journal « réseau coupé, attente »), puis relance le même modèle, 3 fois au plus par modèle ; ensuite modèle suivant. Sans retour : arrêt, « réseau indisponible », code 4 ;
  - autre (« Model is unavailable », « Upstream request failed »…) : modèle suivant, sans écart.
- **Écarts** : `devzone agent etat` affiche la cause et l'heure de fin de chaque écart ; `devzone agent liberer <modèle>` (ou `--tous`) le lève.
- Une session figée (rien écrit depuis 10 min) est arrêtée et reprise sur une session neuve, modèle suivant, avec une consigne de reprise (`git status`, `git diff`, `git log`). Tous les modèles écartés : « aucun modèle gratuit disponible », code 3.
- **Permissions** : `.devcontainer/opencode/agent.json` est la configuration par défaut, fusionnée avec `OPENCODE_CONFIG_CONTENT` s'il est défini. opencode applique la dernière règle qui correspond : les `deny` de devzone sont ré-ajoutés en dernier après la fusion, donc l'appelant peut ajouter des permissions mais jamais retirer un interdit de devzone. `webfetch` est permis ; `git push`, `git checkout/reset/restore/stash/clean`, `git branch -D`, les écritures GitHub, `gh api`, `curl`, `sudo`, `rm -rf` (sauf `./.essai`) et la gestion des tickets/PR par repowarden (`repowarden ticket …`, `repowarden proteger`, `repowarden run`) sont interdits ; `git commit` reste permis pour `repowarden cc`. `~/bash32` est toujours protégé (le bash 3.2 du conteneur).
- **Fichiers de droits protégés** : pendant une session, `agent.json`, `.devcontainer/opencode.jsonc`, `.repowarden.conf` et `.devcontainer/agent-droits.sh` (liste fixe, qu'aucune variable ne change) sont interdits à l'écriture d'opencode (`permission.edit`, `deny` ajoutés en dernier). Comme un agent peut aussi écrire par le shell, `devzone agent` photographie ces fichiers au lancement et les compare après **chaque** session (fin normale, erreur, muet, figée) : tout changement est annulé dans l'arbre (jamais de `reset` ni de `rebase`), le journal reçoit `=== ⚠ droits modifiés : <fichier>` (avec le commit à retirer avant tout push si l'agent a commité) et `devzone agent etat` affiche `⚠ droits modifiés (<projet>)` jusqu'au prochain lancement sur ce projet. Le code de sortie ne change pas. opencode sait qu'il tourne dans une session d'agent, pour un futur réglage de repowarden qui refusera ces chemins au commit.
- **Quota des modèles gratuits** : ces modèles sont limités ; la rotation et l'écart d'une heure évitent de bloquer un ticket quand l'un est épuisé. Pour un fournisseur payant : `opencode auth login`.



## Identifiants regroupés

Les comptes créés par devzone (modules `gitlab` et `postgres`) sont regroupés dans `$RACINE/.password`, à côté de `.devzone.modules`.

```bash
devzone mots-de-passe          # régénère le fichier et affiche seulement son chemin
```

- **Format** : en-tête en commentaire, puis une ligne par compte, colonnes séparées par des tabulations : `service`, `adresse`, `utilisateur`, `mot de passe`. Tri stable par service puis utilisateur ; aucune ligne vide.
- **Source** : les fichiers des modules restent la référence (`workspace/.gitlab/root-password`, `workspace/.gitlab/dev-password`, `workspace/.postgres/admin-password`, `workspace/.postgres/<projet>.env`). `.password` est une vue régénérée, jamais une seconde copie à tenir à jour.
- **Mise à jour** : `password_regenerer` (`.devcontainer/password.sh`) est appelée à la fin de chaque création, suppression ou changement de compte : installation, `creer`, `supprimer` et `--nouveau-mdp` de postgres ; seed et désinstallation de gitlab ; démarrage de devzone. Un échec n'empêche jamais l'opération, il affiche un avertissement.
- **Protection** : fichier ignoré par git (`.gitignore`) et droits **600** posés avant l'écriture (`umask 077`, fichier temporaire dans le même dossier puis `mv`). Aucune commande ne lit ni n'affiche son contenu ; le récapitulatif et `devzone mots-de-passe` citent seulement le chemin. Sans aucun compte, le fichier est supprimé.



## Plusieurs devzone sur une machine

Plusieurs devzone peuvent cohabiter sur une même machine (un par projet, un par usage) : chaque instance est un dossier du workspace, avec son propre état et ses propres modules.

- **Modules** : **propres à chaque devzone**. L'état vit dans le dossier de l'instance (`$RACINE/.devzone.modules`), monté de l'hôte : un second devzone démarre avec des valeurs par défaut, sans hériter de ceux du premier (un ancien état global, au premier devzone démarré après la mise à jour, est repris une fois, par déplacement).
- **Plateforme** (GitHub ou GitLab, [voir plus haut](#plateforme-github-ou-gitlab)) : propre à chaque devzone aussi, dans le même fichier d'état, avec l'URL de son instance GitLab.
- **Connexions** (**GitHub**, **git**, **Claude Code**, **opencode**) et **caches** (**Maven**, **Gradle**, **pnpm**) : **partagés volontairement** entre les devzone d'une machine, dans les volumes `devzone-*`.
- **Isolation complète** : un préfixe de volumes distinct (comme pour les tests) donne à chaque devzone ses propres volumes ; voir « Pour les contributeurs ».


## Travailler sur un projet

- **Hooks repowarden** : installés globalement (`repowarden install --global --lang fr`), ils s'appliquent à tout dépôt cloné dans le conteneur (messages de commit, secrets, formatage, tests). Ensuite, suivre les règles du projet (`AGENTS.md`, `CONTRIBUTING.md`) : `repowarden ticket <n>`, `repowarden cc …`.
- **GitHub App** (proposée par `repowarden bots`, ou `repowarden app init`) : sans elle, les workflows agissent sous le bot `github-actions`, dont les actions ne déclenchent aucun autre workflow (PR brouillon sans CI, merge automatique sans préversion…) ; voir [Dépannage](#dépannage).
- **Vérifications de la CI de repowarden** en local : `shellcheck`, `actionlint`, `bats test/`. actionlint est à la même version que la CI ; shellcheck et bats sont ceux d'Ubuntu 24.04 et peuvent différer légèrement.



## Kubernetes

devzone fournit les outils, pas le cluster, et n'en crée jamais tout seul. Avec le module `kubernetes` actif (`devzone activer kubernetes`), il se connecte à chaque démarrage au cluster de l'hôte s'il existe et répond (en pratique `docker-desktop`) ; sinon, ou en plus, créer un cluster dans le conteneur :

```bash
kind create cluster          # ~2 min la première fois
kubectl config get-contexts  # clusters de l'hôte + clusters kind
devzone utiliser <nom>       # bascule le cluster de travail de kubectl
```

- **Cluster actif** : celui de l'hôte par défaut s'il répond (en pratique `docker-desktop`), sinon kind dédié `kind-devzone`. Un choix fait avec `devzone utiliser` est gardé aux redémarrages.
- **Clusters kind** : tournent sur le Docker de l'hôte (socket partagé, #291). Leur API écoute sur 127.0.0.1 **du poste**, jamais sur le réseau local ; `kind` (enveloppe de devzone) réécrit l'adresse en `host.docker.internal` dans le kubeconfig du conteneur, en gardant la vérification TLS : un cluster créé à la main par `kind create cluster` est joignable tout de suite. Nom suffixé par instance quand ce n'est pas l'instance par défaut. Ils redémarrent avec Docker Desktop, sont conservés par `make rebuild` et `make down`, et supprimés par `kind delete cluster` (ou `make desinstaller`).
- **Relais du socket Docker** ([#293](https://github.com/SimBienvenueHoulBoumi/devzone/issues/293)) : sous Docker Desktop, la feature `docker-outside-of-docker` relaie le socket de l'hôte par `socat` sans option `-t`. Un `docker exec` sans entrée standard (kind lance ainsi `kubeadm init`) y est coupé au bout de 0,5 s, avec une sortie tronquée et un code 0 : kind croit l'init réussi (« failed to remove control plane taint … connection refused »). Au démarrage, devzone remplace ce relais par le même avec `-t 86400`, puis vérifie qu'un `docker exec` long va au bout. En cas d'échec, une ligne `⚠ relais Docker` apparaît dans le récapitulatif `devzone`, avec la commande à relancer : `devzone reparer`. Sous Linux (socket par groupe, sans socat), seul le contrôle est fait.
- **CPU et RAM dans k9s** (`kubectl top`) : module `kubernetes` actif, metrics-server est installé au démarrage sur les clusters **locaux** qui ne l'ont pas (Docker Desktop, kind…), jamais sur un cluster distant. Après un `kind create cluster` : `devzone metrics` (ou `devzone metrics <contexte>` pour un cluster précis).
- **Cluster de l'hôte** : `~/.kube` est monté en lecture seule, jamais modifié ; sa copie adaptée est `~/.kube/hote.config` (`127.0.0.1` remplacé par `host.docker.internal`). Après un changement de cluster sur l'hôte : `make stop && make up`.
- **Messages de démarrage** (`kube-config : …`, `metrics-server : …`, récapitulatif) : dans le terminal de création, ou en relançant `devzone demarrer`.

L'adresse `127.0.0.1` du cluster de l'hôte est réécrite en `host.docker.internal` par `kube-config.sh` au démarrage, rendant le cluster joignable depuis le conteneur. Le certificat de l'API inclut `host.docker.internal` dans ses SAN (configuré via `networking.apiServerAddress` et `kubeadmConfigPatches` dans la config kind).

Le cluster de l'hôte n'est pas joignable dans deux cas (kind fonctionne quand même) :
- **Codespaces, machine distante** : pas de `~/.kube` local ;
- **Linux avec Docker Engine** : un cluster kind ou minikube de l'hôte écoute sur `127.0.0.1`, invisible du conteneur sans la réécriture `kube-config.sh`. Un cluster qui écoute sur toutes les interfaces (k3s, kubeadm) est joignable.

## GitLab

Le module `gitlab` fournit une instance GitLab de test dans un cluster kind dédié (`gitlab`).

```bash
devzone                        # état : identité git, GitHub, outils, modules
devzone activer gitlab         # active et installe GitLab dans kind
devzone desactiver gitlab      # désinstalle GitLab et supprime le cluster
devzone appliquer              # applique les modules actifs
devzone actif gitlab           # code 0 si GitLab est actif
```

- **Ressources** : au moins 8 Go de RAM libre avant la création du cluster (refus sinon) ; environ 8 Go occupés dans le conteneur une fois GitLab installé. Trop lourd pour la CI GitHub : testé à la main (essai réel du 31/10).
- **Durée** (mesurée) : installation complète environ 7 min (dont le chart GitLab, attendu jusqu'à `GITLAB_ATTENTE`, 1200 s par défaut) ; une relance sur une instance prête environ 35 s (rien n'est réinstallé ni re-poussé).
- **Ce qui est installé** : cluster kind `gitlab` (un nœud, `.devcontainer/gitlab/kind.yaml`, ports 8929 HTTP et 2224 SSH publiés sur `127.0.0.1` du poste) ; chart `gitlab/gitlab` 9.11.16 (GitLab 18.11 CE) sans cert-manager, Prometheus, registry ni KAS, nginx en une réplique et service NodePort ; chart `gitlab/gitlab-runner` 0.88.2, exécuteur Kubernetes, image auxiliaire à l'architecture du nœud (arm64 compris).
- **Données de test** : groupe `devzone`, projet `devzone/demo` (Python, pipeline ruff et pytest), utilisateur `dev`, runner enregistré. Sur une relance, rien n'est recréé.
- **Accès dans le conteneur** : http://gitlab.localhost:8929, utilisateur `root`. Le nom `gitlab.localhost` pointe vers `127.0.0.1` dans `/etc/hosts` (entrée `127.0.0.1	gitlab.localhost # devzone:gitlab`, posée à l'activation et à chaque démarrage, remplacée si son adresse diffère, retirée à la désactivation). Un relais TCP `socat` dans le conteneur écoute sur `127.0.0.1:8929` et `127.0.0.1:2224` et joint le **nœud kind** (`gitlab<instance>-control-plane`), sur `<nœud>:80` et `<nœud>:32022` (PID, journal et cible dans `workspace/.gitlab-<port>/`). Pour cela, le conteneur rejoint le réseau Docker `kind` du nœud (`docker network connect kind "$(hostname)"`, idempotent) ; si ce réseau ne peut pas être rejoint, repli sur l'**IPv4** de `host.docker.internal` sur les mêmes ports, avec un message sur stderr. La cible du relais est comparée à chaque lancement : si elle change, l'ancien relais est arrêté et relancé. Il est indispensable à curl et à git en HTTP : libcurl résout tout nom `*.localhost` vers la boucle locale sans lire `/etc/hosts` (RFC 6761), donc sans relais la requête part sur le `127.0.0.1` du conteneur, où rien n'écoute. ssh et glab, eux, lisent `/etc/hosts` et passent par le même relais.

- **Accès depuis le poste** : les ports 8929 (HTTP) et 2224 (SSH) sont publiés sur la seule boucle locale du poste via `extraPortMappings` du cluster kind `gitlab` (`listenAddress: "127.0.0.1"` sur les deux mappings). Depuis le poste, `gitlab.localhost` pointe vers l'hôte ; depuis une autre machine du réseau local, GitLab est injoignable. Plus besoin de relais temporaire `docker run ... socat` côté poste : le relais vit dans le conteneur.
- **Ancien cluster** : un cluster `gitlab` créé avant ce réglage garde ses publications sur `0.0.0.0` ; kind ne les modifie pas sur un nœud existant. Le récapitulatif `devzone` l'affiche alors (`docker port` du nœud sur `0.0.0.0` ou `::`) avec la marche à suivre : `devzone desactiver gitlab` puis `devzone activer gitlab`. Cette recréation perd les données de test de GitLab (acceptable pour cette instance).

- **Secrets** : mot de passe root, jeton root, mot de passe de `dev` et jeton du runner dans `workspace/.gitlab/` (droits 600, ignorés par git, jamais affichés). Mot de passe root : `cat workspace/.gitlab/root-password`.
- **Désactivation** : `devzone desactiver gitlab` arrête les relais TCP 8929/2224, supprime le cluster `gitlab`, retire `kind-gitlab` de `~/.kube/config`, remet le contexte courant d'avant et supprime `workspace/.gitlab/`. Rien d'autre n'est touché.

### Essai de bout en bout : `devzone test-gitlab`

`devzone test-gitlab` rejoue sur le poste l'essai réel du module et de la plateforme GitLab, que la CI GitHub ne peut pas lancer (8 Go de RAM). Le script est `.devcontainer/gitlab/test-gitlab.sh`.

```bash
devzone test-gitlab              # étapes 1 à 7
devzone test-gitlab --complet    # désactive, contrôle qu'il ne reste rien, puis réinstalle
devzone test-gitlab --statut     # publie aussi le statut gitlab-integration sur HEAD
```

- **Étapes**, chacune chronométrée : 1 module actif (sinon activé) ; 2 état « prêt » et runner en ligne ; 3 `gitlab.localhost` résolu vers `127.0.0.1` et relais TCP actifs sur 8929 et 2224 (`gitlab.sh hote-poser` et `relais-lancer`), sinon ✖ avec l'adresse ou le port manquant ; 4 pipeline de `devzone/demo` relancé sur `main` et attendu jusqu'à `success` ; 5 clone SSH (clé ed25519 jetable) et clone HTTP authentifié par un assistant d'identifiants (Basic `oauth2` + jeton lu dans le fichier, jamais dans les arguments d'un processus, l'URL ni `.git/config`) ; 6 plateforme `gitlab` avec `glab repo clone`, puis retour à la plateforme d'avant ; 7 suite d'intégration `test/gitlab/` de repowarden ([#533](https://github.com/simdevWarden/repowarden/issues/533)), dossier absent à la réf → étape sautée avec la raison, échec → sortie gardée dans `${TMPDIR:-/tmp}/devzone-test-gitlab-repowarden.log` (jeton masqué) et citée dans la raison. Avec `--complet`, une étape 8 précède les autres : `devzone desactiver gitlab`, puis contrôle qu'il ne reste ni cluster `gitlab<instance>`, ni contexte `kind-gitlab<instance>` (noms calculés comme `gitlab.sh` et `cluster.sh`), ni conteneur étiqueté `devzone.instance=<instance>` du module sur le Docker de l'hôte, ni `workspace/.gitlab/`, ni ligne `# devzone:gitlab` de `/etc/hosts`.
- **Résumé** : une ligne par étape (✔/✖/sauté, durée, raison) et un total ; le code de sortie n'est 0 que sans ✖ (une étape sautée n'échoue pas). Un jeton n'est jamais affiché.
- **Nettoyage garanti** par `trap … EXIT` : clé SSH retirée de GitLab, dossiers temporaires supprimés, plateforme d'avant restaurée, même si une étape échoue.
- **Variables** : `GITLAB_TEST_PIPELINE` (délai du pipeline, 600 s par défaut), `GITLAB_TEST_INTERVALLE` (intervalle d'interrogation du pipeline, 5 s par défaut), `REPOWARDEN_TEST_REF` (réf. de la suite d'intégration, `develop` par défaut), `DEVZONE_RACINE` (racine du dépôt, comme `gitlab.sh`).
- **Durée indicative** : quelques dizaines de secondes sur une instance déjà prête ; plusieurs minutes si le module doit être installé (environ 7 min) et davantage avec `--complet`, qui réinstalle.
- **`--statut`** : publie le résultat comme statut de commit `gitlab-integration` (`success`/`failure`, description = résumé court) sur `HEAD` du dépôt courant, par `gh api repos/<dépôt>/statuses/<sha>` avec le jeton du mainteneur. Refus clair si `gh` n'est pas connecté. Voir la règle dans [Contribuer](contribuer.md).


## PostgreSQL

Le module `postgres` fournit un PostgreSQL partagé : une base et un utilisateur par projet, sur le [cluster de devzone](#cluster-de-devzone).

```bash
devzone activer postgres [--contexte CTX]   # installe (choix du cluster la première fois)
devzone postgres creer <projet>             # base + utilisateur <projet>, identifiants dans workspace/.postgres/<projet>.env
devzone postgres creer <projet> --nouveau-mdp
devzone postgres liste                      # bases et propriétaires
devzone postgres psql [<projet>]            # console psql dans le pod (superutilisateur sans projet)
devzone postgres supprimer <projet> [--oui] # base, utilisateur et fichier .env
devzone desactiver postgres                 # supprime PostgreSQL et TOUTES ses bases
```

- **Ce qui est installé** : `.devcontainer/postgres/postgres.yaml`, StatefulSet `postgres` (image `postgres:16.x-alpine` figée), volume persistant de 5 Gi (`POSTGRES_TAILLE`), Service `postgres:5432`, namespace `devzone-postgres` étiqueté `app.kubernetes.io/managed-by=devzone`. Pas de chart ni d'image Bitnami.
- **Accès** : un relais `kubectl port-forward` rend le service joignable sur `127.0.0.1:5432` **dans le conteneur** (`POSTGRES_PORT` pour un autre port) ; relancé à chaque démarrage et par `devzone appliquer`. PID et journal : `workspace/.postgres/relais.*`.
- **Bases par projet** : nom en minuscules, chiffres et `_`. `creer` est idempotent : le mot de passe est gardé (sauf `--nouveau-mdp`) ; `REVOKE CONNECT … FROM PUBLIC` : un projet ne se connecte pas à la base d'un autre. Le fichier `<projet>.env` (600) contient `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` et `DB_URL` (JDBC).
- **Secrets** : mot de passe du superutilisateur `postgres` dans le secret `postgres-admin` et `workspace/.postgres/admin-password` (600) ; jamais régénéré tant que le secret existe ; jamais affiché.
- **Désactivation** : namespace supprimé (volume compris), `workspace/.postgres/` supprimé, kind dédié supprimé s'il ne porte plus aucun service. `make desinstaller` supprime aussi le namespace d'un cluster de l'hôte.

## Ports vers le poste

`devzone port` rend accessibles depuis le poste les applications qui écoutent **dans** le conteneur devzone : un relais `alpine/socat` par port, sur le Docker de l'hôte (#290).

```bash
devzone port <n>              # ouvre 127.0.0.1:<n> du poste → <n> du conteneur
devzone port                  # liste : port, ● actif ou ○ arrêté, application derrière
devzone port --fermer <n>     # retire le relais et le port de l'état
```

- **Relais** : conteneur `devzone-<instance>-port-<n>`, étiqueté `devzone.instance=<instance>` et `devzone.port=<n>`, image figée `SOCAT_IMAGE=alpine/socat:1.8.0.3` (`.devcontainer/ports.sh`). Il publie `-p 127.0.0.1:<n>:<n>` seulement, avec `--restart unless-stopped`.
- **Réseau et IP** : lus par `docker inspect "$(hostname)"` sur le Docker de l'hôte ; le relais rejoint le conteneur par son IP sur son réseau Docker. Conteneur devzone introuvable (Docker de l'hôte absent) : refus clair, code 1.
- **État** : ligne `ports=8080,3000` dans `$RACINE/.devzone.modules`, triée et sans doublon ; `--fermer` retire le port. Le relais déjà ouvert est idempotent (message, code 0).
- **Démarrage** : `devzone demarrer` relance chaque relais de l'état vers l'IP actuelle du conteneur (elle change à chaque redémarrage). Un échec affiche un avertissement sans bloquer le démarrage ; `devzone reparer` le reprend sans redémarrer.
- **Refus, code 1** : port non numérique ou hors 1-65535 ; Docker de l'hôte injoignable ; port déjà pris sur le poste (échec de `docker run`, « port is already allocated » ou « address already in use »), l'état restant inchangé.
- **Plusieurs instances** : le nom du relais et l'étiquette portent `DEVZONE_INSTANCE` ; deux instances qui veulent le même port du poste : la seconde reçoit le refus « déjà utilisé ».
- **Récapitulatif** : ligne `ports vers le poste` avec `8080 ●, 3000 ○`, ou `aucun (devzone port <n>)`.
- **Désinstallation** : `make desinstaller` retire les conteneurs étiquetés `devzone.instance` (voir README, « Désinstaller »).
- **Spring Boot** : l'application doit écouter sur `0.0.0.0` (défaut). Un `server.address=127.0.0.1` la rend injoignable depuis le relais.

## Cluster de devzone

Les modules qui déploient un service (`postgres` ; `gitlab` avec #279) s'installent sur **un seul cluster**, choisi une fois et gardé dans l'état (`cluster=` dans `$RACINE/.devzone.modules`).

- **Cluster local vs distant** : un cluster est considéré comme **local** quand son serveur écoute sur une adresse de boucle (`127.0.0.1`, `localhost`, `::1`, `host.docker.internal`) — lu dans la configuration kubeconfig, sans appel réseau. Le cluster kind dédié (`kind-devzone`) est toujours local. Tout autre cluster (serveur sur une adresse distante) est **distant**.
- **Choix** : à la première activation. `--contexte CTX` d'abord ; sinon, dans un terminal, un menu : le cluster par défaut est le contexte courant du kubeconfig de l'hôte s'il répond et est local (en pratique `docker-desktop`), sinon kind dédié `kind-devzone`. Le choix est gardé dans l'état et repris aux redémarrages. Le menu propose les clusters **locaux** d'abord, puis le **cluster kind dédié**, enfin les clusters **distants** (marqués « distant ») ; sans terminal : `kind-devzone`. Les clusters de l'hôte n'apparaissent qu'avec le [module `kubernetes`](#kubernetes) actif.
- **Cluster distant** : choisir un cluster distant nécessite une confirmation en terminal, ou `--confirmer CTX` sans terminal. Sans confirmation exacte, le choix est refusé. Quand le cluster de devzone est distant, le récapitulatif `devzone` affiche un avertissement `⚠ cluster distant : <contexte>`.
- **Voir / changer** : `devzone cluster` affiche le cluster et les possibles ; `devzone cluster CTX [--confirmer CTX]` y déplace les services actifs (désinstallés de l'ancien, installés sur le nouveau). **Les données ne sont pas migrées** : confirmation en terminal, `--oui` sans terminal.
- **Cluster de l'hôte** : devzone n'y crée que ses namespaces étiquetés `app.kubernetes.io/managed-by=devzone`, et les supprime à la désactivation. Désactiver le module `kubernetes` rend ce cluster injoignable pour les services.
- **Contexte courant** : les clusters kind sont créés sans basculer dessus ; `devzone utiliser CTX` bascule seulement le cluster de travail de kubectl, jamais le cluster des services de devzone. Si tu te retrouves sur un cluster interne (kind-devzone ou kind-gitlab), reviens avec `devzone utiliser <ton cluster>`.
- **Namespace** : pour un contexte du poste (ceux de `hote.config`, recopié depuis le poste à chaque démarrage), le namespace fixé par `devzone utiliser -n` ne survit pas à un redémarrage ; pour les clusters kind du conteneur, il est gardé jusqu'au rebuild.

- **Deux notions** : `★` marque le cluster de travail de kubectl (kubectl, k9s, helm), `●` le cluster des services de devzone (`devzone cluster`). Un contexte peut porter les deux marques. `devzone clusters` affiche la vue.
- **Rebuild** : `le choix de kubectl` écrit dans `~/.kube/config`, qui n'est pas dans un volume ; un rebuild repart sur le cluster de l'hôte.

## Données conservées

Le conteneur est jetable ; ce qui compte vit dans des volumes Docker, sur ta machine.

| Volume | Contenu | `make stop` | `make down` | `make rebuild` |
|---|---|---|---|---|
| `devzone-gh` | connexion GitHub (`gh`) | gardé | gardé | gardé |
| `devzone-git` | identité git (`~/.config/git/config`) | gardé | gardé | gardé |
| `devzone-claude` | connexion et réglages de Claude Code | gardé | gardé | gardé |
| `devzone-opencode-config`, `devzone-opencode-data` | connexion et réglages d'opencode | gardé | gardé | gardé |
| `devzone-agent` | état de `devzone agent` (modèles écartés, rang), partagé entre les devzone | gardé | gardé | gardé |
| `devzone-config` | modules activés (`devzone activer`) : ancien état utilisateur, repris une fois | gardé | gardé | gardé |
| `devzone-m2`, `devzone-pnpm` | caches Maven (`~/.m2`) et pnpm | gardé | gardé | gardé |
| `devzone-gradle` | cache Gradle (`~/.gradle`) | gardé | gardé | gardé |
| volume du Docker interne | images Docker et clusters kind du conteneur | gardé | gardé | gardé |
| `workspace/` (dossier de l'hôte) | tes projets | gardé | gardé | gardé |

Tout le reste du conteneur (paquets installés à la main, fichiers hors de ces emplacements) est perdu à `make down` et `make rebuild`. Le Docker interne est isolé : ses images ne sont pas partagées avec Docker Desktop.



## Mettre à jour devzone

Un dossier devzone garde sa version dans `.devzone.version` : la version, puis une empreinte sha256 (calculée par node) par fichier copié depuis le paquet. La commande se lance **sur le poste**, dans le dossier :

```bash
cd mon-devzone
devzone mettre-a-jour              # version du paquet installé
npx devzone@latest mettre-a-jour   # dernière version publiée
```

- **Déjà à jour** : version du dossier égale à celle du paquet et aucun fichier du paquet manquant → `déjà à jour`, code 0. Le message rappelle `npx devzone@latest mettre-a-jour` pour la dernière version publiée.
- **Fichiers modifiés localement** : leur empreinte diffère de celle du manifeste (sans manifeste, de celle du paquet). Ils sont listés et une confirmation est demandée. `--oui` répond oui pour un script ; sans terminal et sans `--oui`, la commande refuse (code 1) et ne touche à rien.
- **Sauvegarde** : tout fichier remplacé ou supprimé est copié dans `.devzone.sauvegarde/<AAAAMMJJ-HHMMSS>/`, avec la même arborescence. Ce dossier est ajouté au `.gitignore` du devzone.
- **Remplacement** : les fichiers du paquet sont recopiés, les fichiers de l'ancien manifeste qui n'existent plus sont supprimés, ainsi que les anciennes arborescences `core/` et `scripts/` à la racine. `.gitignore` est complété des lignes manquantes, jamais écrasé.
- **Jamais touchés** : `workspace/`, `.devzone.modules`, `.devzone.paquets`, `.password`, `.app`, `.devzone.log`, les volumes Docker.
- **Reconstruction** : le nouveau `.devzone.version` est écrit, puis `make rebuild` est proposé avec confirmation dans un terminal. `--sans-reconstruire` saute cette étape ; sans terminal, la reconstruction est indiquée mais jamais lancée.

Un dossier créé avant ce manifeste a une version « inconnue » : tous les fichiers différents du paquet sont traités comme modifiés (sauvegarde, puis confirmation).

Dans le conteneur, le récapitulatif `devzone` lit `$RACINE/.devzone.version` et la dernière version publiée (`npm view devzone version`, au plus une fois par jour, cache sous `~/.cache/devzone/`, délai de 5 s, silencieux hors ligne). Si elle est plus récente : `○ devzone X.Y.Z disponible : sur le poste, devzone mettre-a-jour`.

## Mettre à jour un outil

| Outil | Où | Puis |
|---|---|---|
| k9s, actionlint, gitleaks, kind | `.devcontainer/Dockerfile` : `ARG …_VERSION` **et** les empreintes `sha256` (arm64 + amd64) | `make rebuild` |
| uv, ruff, vulture, pytest | `.devcontainer/Dockerfile` : `ARG …_VERSION` | `make rebuild` |
| repowarden | `.devcontainer/post-create.sh` : `repowarden@x.y.z` | `devzone appliquer` (ou `make rebuild`) |
| Claude Code, opencode | `.devcontainer/devzone` : une ligne par paquet, `IA_CLAUDE=@anthropic-ai/claude-code@x.y.z` et `IA_OPENCODE=opencode-ai@x.y.z` | `devzone activer ia` (ou `make rebuild`) |
| glab (plateforme gitlab) | `.devcontainer/devzone` : `GLAB_VERSION` et les sommes `GLAB_SOMME_ARM64` / `GLAB_SOMME_AMD64` | `rm ~/.local/bin/glab` puis `devzone plateforme gitlab --url URL` |
| metrics-server | `.devcontainer/metrics-server.sh` : `VERSION` | `devzone metrics` sur un nouveau cluster |
| Java, Node, Python, Docker, kubectl, helm, gh | `.devcontainer/devcontainer.json` (features), versions figées dans `devcontainer-lock.json` | `npx @devcontainers/cli upgrade --workspace-folder .` puis `make rebuild` |

Empreinte d'une archive : `curl -fsSL <url> | shasum -a 256`.

**Montées automatiques** : les versions de `repowarden` et des assistants IA (`IA_CLAUDE`, `IA_OPENCODE`) sont comparées toutes les heures à npm par le workflow `versions` (`.github/workflows/versions.yml`). Pour chaque paquet en retard, il ouvre ou met à jour un ticket, y propose une conception (« Conception proposée »), crée sa branche, applique la montée (`manage/scripts/versions.sh --appliquer`), commit et pousse : la PR brouillon s'ouvre et la CI teste le conteneur. Le mainteneur confirme la conception sur le ticket (« Conception retenue », attendue par la vérification `ticket`), puis passe la PR en ready. Une ligne par paquet : deux montées ouvertes en même temps (Claude Code et opencode) se fusionnent l'une après l'autre sans conflit. À la main : *Actions → versions → Run workflow* ; en local, `bash manage/scripts/versions.sh` liste les paquets en retard. Sans nouvelle version, le job s'arrête après la comparaison ; pas de déclenchement croisé depuis repowarden, qui demanderait un jeton d'un autre propriétaire.

**Rattraper sans rebuild** : l'état affiché au démarrage (et par `devzone`) compare les outils installés à leur version figée. Une ligne `⚠ outils          repowarden 4.9.2 installé, 4.12.0 figé : devzone appliquer` signale un écart ; `devzone appliquer` réinstalle repowarden à la version figée et les modules actifs. `✔ outils          versions figées` indique que tout correspond. Les outils installés par `apt` ou l'image (Java, Node, Python, …) ne sont pas concernés.



## Garder des paquets systeme

Un paquet installe a la main (`sudo apt install tree`) est perdu au prochain rebuild. `devzone paquets` maintient la liste des paquets a reinstaller apres un rebuild :

| Action | Commande |
|---|---|
| Lister | `devzone paquets` : ✔ paquets installes, ○ paquets a installer |
| Ajouter | `devzone paquets ajouter <nom>…` : valide (`apt-cache`), installe, ajoute a la liste |
| Retirer | `devzone paquets retirer <nom>` : retire la liste et desinstalle |
| Appliquer | `devzone paquets appliquer` : installe les paquets manquants |

La liste est relue au post-create et affiche dans le recap (`⚠ paquets : …`) l'etat des paquets non installes. `devzone paquets appliquer` peut etre relance.

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
| `git commit` : « Please tell me who you are » | identité git absente | avec GitHub : `gh auth login -s workflow` puis `devzone demarrer` ; sans GitHub : `git config --file ~/.config/git/config user.name "<nom>"` et `user.email "<email>"` |
| `gh auth login` : « Press Enter to open … in your browser », rien ne s'ouvre | pas de navigateur dans le conteneur (`make shell`) | ouvrir https://github.com/login/device à la main et saisir le code |
| `k9s` : `Error: exit status 1` puis son aide ; `kubectl` : `localhost:8080` … `connection refused` | aucun cluster actif (module `kubernetes` désactivé, ou pas de cluster sur ta machine) | `devzone activer kubernetes` (cluster de ta machine), `kind create cluster`, ou `devzone utiliser <nom>` |
| `claude` ou `opencode` : « command not found » | module `ia` désactivé | `devzone activer ia` |
| `devzone` affiche `✖ module ia         en échec : installation incomplète (journal npm : …)` | l'installation de Claude Code ou d'opencode a échoué (réseau, paquet) ; le message d'échec nomme les paquets et le journal npm | lire le journal cité, puis `devzone appliquer` pour réessayer (ou `devzone desactiver ia`) |
| `devzone activer ia` ou `devzone appliquer` sans rien afficher de neuf pendant plusieurs minutes | installation de Claude Code et opencode (plusieurs centaines de Mo) : annoncée, puis une ligne `… toujours en cours (N s)` toutes les 30 s | attendre la ligne `Claude Code et opencode installés` ou le message d'échec |
| CPU et RAM vides dans k9s | metrics-server absent du cluster | `devzone metrics` |
| Deux conteneurs devzone | `make up` lancé pendant que VS Code ouvrait le conteneur | `make down`, puis un seul lancement |
| Windows (Git Bash, MSYS) : `~/.kube` introuvable | `HOME` et `USERPROFILE` concaténés dans le chemin monté | lancer depuis VS Code ou PowerShell |
| Pas de `~/.kube` sur l'hôte | Docker le crée vide au démarrage (sous Linux avec Docker Engine, il appartient à root) | rien à faire : le conteneur démarre quand même |

## Pour les contributeurs

Les commandes de l'application (`devzone reparer`, `demarrer`, `metrics`,
`utiliser`) remplacent les scripts directs pour l'utilisateur. Les scripts
internes restent appelables pendant le développement et par les tests :

```bash
bash .devcontainer/demarrage.sh
bash .devcontainer/docker-relais.sh
bash .devcontainer/metrics-server.sh
```

Les tests isolent le relais Docker (`DEVZONE_RELAIS_SOCKET=…`,
`DEVZONE_RELAIS_SOURCE=…`, `DEVZONE_RELAIS_PID=…`, `DEVZONE_RELAIS_LOG=…`,
`DEVZONE_RELAIS_MARQUE=…`, `DEVZONE_RELAIS_SUDO=`) et Kubernetes
(`kube_isole` de `manage/test/commun.bash` : `HOME`, `KUBECONFIG` et
`DEVZONE_KUBE_HOTE` sous le dossier temporaire du test). `cluster.sh` accepte
`--confirmer CTX` et conserve `DEVZONE_CLUSTER_DISTANT=<contexte>` pour les
tests et la CI. Un changement de contexte direct (`kubectl config
use-context CTX`) ne doit être fait que dans un test isolé. L'isolation des
volumes utilise `DEVZONE_VOLUMES=<préfixe>`.

