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
| `ia` | Claude Code et opencode installés (versions figées), réinstallés à chaque rebuild, avec le [garde-fou repowarden](#garde-fou-des-assistants-ia), une [configuration opencode par défaut](#configuration-dopencode) et la [skill devzone](#skill-devzone) posée dans `~/.claude/skills/devzone/` et `~/.config/opencode/skills/devzone/` ; se connecter : `claude` (puis `/login`), `opencode auth login` | désinstallés ; le garde-fou (hook et plugin), la configuration opencode par défaut et la skill devzone non modifiée sont retirés ; l'état de `devzone agent` (volume partagé), les journaux `workspace/.agents/` et les connexions restent | Python 3.12 d Ubuntu 24.04, installé par apt (plus de feature devcontainer, pas de serveur de clés, #464)
| `kubernetes` | à chaque démarrage : connexion au cluster de ta machine et metrics-server sur les clusters locaux (CPU et RAM dans k9s) | aucune connexion au cluster de ta machine ; kubectl, helm, k9s et kind restent installés, un cluster kind créé à la main reste utilisable ; metrics-server est retiré des clusters où devzone l'a installé |
| `gitlab` | GitLab CE de test dans le [cluster des services](#cluster-de-devzone), namespace `devzone-gitlab` (chart figé), runner Kubernetes, projet `devzone/demo` avec pipeline ; http://gitlab.localhost:8929 ; au moins 8 Go de RAM allouable (voir [GitLab](#gitlab)) | releases Helm et namespace `devzone-gitlab` retirés, secret Rails gardé (`workspace/.gitlab/rails-secret.yaml`) ; rien d'autre touché |
| `postgres` | PostgreSQL 16 partagé sur le [cluster de devzone](#cluster-de-devzone), une base par projet (`devzone postgres creer <projet>`), joignable sur `127.0.0.1:5432` dans le conteneur (voir [PostgreSQL](#postgresql)) | namespace `devzone-postgres` (toutes les bases) et secrets `workspace/.postgres/` supprimés, après confirmation en terminal ; kind dédié supprimé s'il ne sert plus |
| `argocd` | Argo CD sur le [cluster de devzone](#cluster-de-devzone), namespace `devzone-argocd` (chart figé), serveur en `ClusterIP` ; https://127.0.0.1:8443 dans le conteneur ; au moins 1 Go de RAM allouable (voir [Argo CD](#argo-cd)) | release Helm et namespace `devzone-argocd` retirés, secret `workspace/.argocd/` supprimé ; les autres services restent, sous helm direct |

Le choix est **propre à chaque devzone** (instance) et gardé dans le dossier `$RACINE/.devzone.modules` (monté de l'hôte, il survit aux rebuilds). Au premier démarrage d'une instance, si une connexion Claude Code ou opencode existe déjà dans les volumes, le module `ia` n'est pas activé : tout est désactivé par défaut et la connexion est signalée une seule fois (« devzone activer ia pour l'utiliser ici »), pas pour un état repris.

### Socket Docker de l'hôte

Par défaut, la feature `docker-outside-of-docker` monte le socket Docker du poste dans le conteneur : le récapitulatif affiche `⚠ socket Docker de l hôte partagé (agents compris)`. C'est ce qui permet à `docker`, Testcontainers et kind de parler au Docker de l'hôte, mais cela donne aussi au conteneur et à ses agents l'administration du Docker du poste.

Le récapitulatif suit le **socket réellement monté**, pas l'option : tant que `make rebuild` n'a pas été lancé, le conteneur courant garde son ancien montage, signalé par `⚠ socket Docker de l hôte encore partagé : make rebuild sur le poste` (option `off`) ou `⚠ socket Docker de l hôte absent : make rebuild sur le poste` (option `on`, socket absent). Sans socket et avec l'option `off`, tout est cohérent : rien n'est affiché.

Pour retirer ce partage :

```bash
devzone desactiver docker-hote     # écrit docker-hote=off, puis demande une reconstruction
make rebuild                       # sur le poste, pas dans le conteneur
```

Au lancement sur le poste, `manage/scripts/lancer.sh` lit la ligne `docker-hote` (absente = `on`). À `off`, il génère `.devcontainer/sans-docker-hote/devcontainer.json` (copie sans la feature, chemins de build adaptés au sous-dossier, dossier ignoré par git) et passe ce fichier au CLI devcontainers avec `--config`. Pour remettre le socket : `devzone activer docker-hote`, puis `make rebuild`.

Sans socket, `docker` n'existe plus dans le conteneur : la commande affiche un message qui renvoie au workspace Kubernetes (`devzone workspace`, kubedock et BuildKit). Le relais du socket ne bloque pas le démarrage, et la connexion au cluster Kubernetes de l'hôte reste disponible ; en revanche, kind et les conteneurs lancés sur le Docker du poste ne le sont plus. `devzone etat --json` porte l'option dans le champ `docker_hote` et l'état réel du montage dans `docker_hote_actif`.

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

### Skill devzone

Avec le module `ia`, devzone pose la skill devzone (`.devcontainer/skills/devzone/SKILL.md`) dans `~/.claude/skills/devzone/` et `~/.config/opencode/skills/devzone/` (volumes, gardés aux rebuilds). Elle rappelle que tout se fait dans le conteneur avec les commandes `devzone` (jamais les scripts), les worktrees sous `workspace/wt/`, les modules, `devzone agent` (rotation, `etat`, `liberer`), le garde-fou et les fichiers de droits protégés, les services Kubernetes (contexte `devzone`, namespaces `devzone-*`) et ce qui revient au mainteneur (connexions, Ready, fusions).

- **Pose** : si absente, la skill est écrite depuis le modèle ; si elle porte le repère `<!-- devzone : skill posée par devzone activer ia -->` et n'a pas été modifiée, elle est mise à jour ; personnalisée, elle est gardée.
- **Désactivation** : `devzone desactiver ia` retire seulement la skill non modifiée ; une skill personnalisée est gardée.

La skill « repowarden » est déjà posée par `repowarden agents init` : vérifiez seulement qu'elle est présente.

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
- **Fichiers de droits protégés** : pendant une session, `agent.json`, `.devcontainer/opencode.jsonc`, `.repowarden.conf` et `.devcontainer/agent-droits.sh` (liste fixe, qu'aucune variable ne change) sont interdits à l'écriture d'opencode (`permission.edit`, `deny` ajoutés en dernier). Comme un agent peut aussi écrire par le shell, `devzone agent` photographie ces fichiers au lancement et les compare après **chaque** session (fin normale, erreur, muet, figée) : tout changement est annulé dans l'arbre (jamais de `reset` ni de `rebase`), le journal reçoit `=== ⚠ droits modifiés : <fichier>` (avec le commit à retirer avant tout push si l'agent a commité) et `devzone agent etat` affiche `⚠ droits modifiés (<projet>)` jusqu'au prochain lancement sur ce projet. Le code de sortie ne change pas. De plus, le garde-fou repowarden (réglage `agentsProtectedPaths` de `.repowarden.conf`, repowarden 4.16.1) refuse à tout agent, Claude Code comme opencode, d'écrire ou de commiter ces fichiers, avant même la fin de la session ; un humain peut toujours les modifier.
- **Quota des modèles gratuits** : ces modèles sont limités ; la rotation et l'écart d'une heure évitent de bloquer un ticket quand l'un est épuisé. Pour un fournisseur payant : `opencode auth login`.



## Identifiants regroupés

Les comptes créés par devzone (modules `gitlab`, `postgres` et `argocd`) sont regroupés dans `$RACINE/.password`, à côté de `.devzone.modules`.

```bash
devzone mots-de-passe          # régénère le fichier et affiche seulement son chemin
```

- **Format** : en-tête en commentaire, puis une ligne par compte, colonnes séparées par des tabulations : `service`, `adresse`, `utilisateur`, `mot de passe`. Tri stable par service puis utilisateur ; aucune ligne vide.
- **Source** : les fichiers des modules restent la référence (`workspace/.gitlab/root-password`, `workspace/.gitlab/dev-password`, `workspace/.postgres/admin-password`, `workspace/.postgres/<projet>.env`, `workspace/.argocd/admin.env`). `.password` est une vue régénérée, jamais une seconde copie à tenir à jour.
- **Mise à jour** : `password_regenerer` (`.devcontainer/password.sh`) est appelée à la fin de chaque création, suppression ou changement de compte : installation, `creer`, `supprimer` et `--nouveau-mdp` de postgres ; seed et désinstallation de gitlab ; installation et désinstallation d'argocd ; démarrage de devzone. Un échec n'empêche jamais l'opération, il affiche un avertissement.
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

## Workspace Kubernetes

Le poste de developpement peut tourner dans le cluster, avec Kubernetes 1.30 ou plus comme prerequis minimal (sidecars natifs, et profil AppArmor de BuildKit). Le chart charts/devzone-workspace/ deploie un StatefulSet, sans conteneur privilegie ni Docker du noeud :

- conteneur `workspace` (image ghcr.io/simbienvenuehoulboumi/devzone-workspace:<version>), avec `DOCKER_HOST=tcp://127.0.0.1:2475`, `BUILDKIT_HOST=tcp://127.0.0.1:1234`, `TESTCONTAINERS_RYUK_DISABLED=true` et `TESTCONTAINERS_CHECKS_DISABLE=true` ;
- sidecar natif `kubedock` (joyrex2001/kubedock:0.23.0, sans privilege), demarre avant `workspace` : une API Docker dont les conteneurs deviennent des pods du namespace ;
- sidecar natif `buildkitd` (moby/buildkit:v0.34.2-rootless, UID 1000, sans privilege), demarre avant `workspace` : construit les images ;
- deux PVC : `workspace` (les projets, monte sur `/workspaces/projets`) et `etat` ;
- un ServiceAccount devzone-workspace avec un Role limite au namespace et une NetworkPolicy meme namespace.

Depuis le poste :

```bash
devzone workspace demarrer                # installe ou met a jour le workspace
devzone workspace arreter                 # desinstalle le workspace
devzone workspace etat                    # etat des pods
devzone workspace shell                   # shell dans le conteneur workspace
devzone workspace vscode                  # marche a suivre : attache VS Code au pod
devzone workspace copier-vers <dossier>   # copie un dossier du poste vers les projets du pod
devzone workspace copier-depuis <dossier> # copie un projet du pod vers le poste
```

Les commandes utilisent helm et kubectl du poste, avec le contexte devzone s il existe, sinon le contexte courant. L image est construite par la CI a chaque PR et publiee sur ghcr.io a la livraison.

### Projets dans un volume

- **Montage** : le PVC `workspace` est monte sur `/workspaces/projets`, ou le conteneur demarre (`workingDir`). Sa taille se regle avec `workspace.taille` (20 Gi par defaut).
- **Conservation** : le PVC porte l annotation `helm.sh/resource-policy: keep` et n est jamais supprime par `helm uninstall` : `devzone workspace arreter` retire le pod, pas les projets. Le perdre demande une suppression a la main dans le cluster.
- **Copies** : `devzone workspace copier-vers <dossier>` copie le dossier du poste dans `/workspaces/projets/<nom du dossier>` ; `devzone workspace copier-depuis <dossier>` ramene `/workspaces/projets/<nom du dossier>` dans ce dossier du poste. Les deux passent par `kubectl cp` (tar est present dans l image).

### Edition depuis le poste

**VS Code** : `devzone workspace vscode` affiche la marche a suivre. Extensions « Kubernetes » et « Dev Containers » ; dans la vue Kubernetes, avec le contexte `devzone` : namespace `devzone-workspace`, pod `devzone-workspace-0`, conteneur `workspace` → « Attach to Running Kubernetes Container », puis ouvre le dossier `/workspaces/projets`.

**IntelliJ (JetBrains Gateway)** : Gateway installe le backend de l IDE dans le pod et l ouvre dans un client leger sur le poste. La connexion se fait en SSH : elle demande le serveur SSH du pod et son transfert de port vers le poste, qui arrivent avec les ports du workspace (#401).

1. Gateway → *Remote Development* → *New Connection* → *SSH* : hôte `127.0.0.1`, port transfere du pod, utilisateur `vscode`.
2. Dossier ouvert par le backend : `/workspaces/projets/<projet>`.

En attendant ces deux points, edite le projet sur le poste par les copies : `devzone workspace copier-vers <dossier>` avant, `devzone workspace copier-depuis <dossier>` apres.

### Testcontainers et docker dans le workspace

- `docker` et Testcontainers parlent a kubedock (`DOCKER_HOST=tcp://127.0.0.1:2475`) : rien a configurer, et le socket Docker du poste n'est pas monte.
- Chaque conteneur lance par Testcontainers devient un pod du namespace, cree et supprime par kubedock. Ryuk est desactive (`TESTCONTAINERS_RYUK_DISABLED=true`) : kubedock nettoie lui-meme.
- Les ports des conteneurs sont relayes par kubedock (`--port-forward --reverse-proxy`) : rien a publier sur le pod.
- Le conteneur `workspace` ne demarre qu'une fois kubedock et BuildKit joignables (startupProbe, 60 s au plus).
- Fonctions de Testcontainers non prises en charge par kubedock 0.23.0 : reseaux, montages et compose ne sont pas essayes (#410).
- Les images construites par BuildKit (`BUILDKIT_HOST=tcp://127.0.0.1:1234`, `buildctl`) restent dans le systeme de fichiers du sidecar `buildkitd` : le cache est perdu quand ce conteneur redemarre.

### Securite : workspace sans Docker

- **Aucun conteneur privilegie** : ni kubedock, ni BuildKit, ni le workspace n'ont `privileged: true`. Un test `helm template` (`manage/test/workspace-sans-docker.bats`) echoue si un tel conteneur apparait.
- **BuildKit rootless** : UID 1000, `--oci-worker-no-process-sandbox` (la doc BuildKit le recommande pour Kubernetes, avec ses caveats). seccomp et AppArmor sont `Unconfined` (`buildkit.unconfined`), sans quoi `mount` et `unshare` sont bloques. Le profil est le seul relache de securite du workspace : il ne donne pas de privilege.
- **Pas de socket du poste** : le socket Docker de l'hote (#291) n'est pas monte, et aucun socket du noeud n'est partage.
- **Ecoute** : kubedock et BuildKit n'ecoutent que sur `127.0.0.1` du pod, sans TLS. Aucun port n'est declare (ni `containerPort`, ni `hostPort`), et le Service n'expose que le HTTP du workspace.
- **RBAC** : le ServiceAccount a un Role (pas un ClusterRole) limite au namespace, avec les droits que kubedock 0.23.0 utilise : pods (get, list, watch, create, delete), pods/log (get), pods/exec et pods/portforward (create), services et configmaps (list, create, delete). Aucun droit sur les secrets ni les deployments. Le pod peut donc lancer des conteneurs et les executer dans le namespace, sans rien ecrire hors de lui.
- **Ports relayes** : les conteneurs de test sont joignables par les autres pods du namespace (la NetworkPolicy l'autorise). Ne pas y mettre de secret.
- **Cloisonnement** : le workspace voit tous les conteneurs de test de son namespace, y compris ceux lances par d'autres projets. Un projet ne doit pas compter sur une isolation entre ses conteneurs et ceux d'un autre.

## GitLab

Le module `gitlab` fournit une instance GitLab de test dans le [cluster des services](#cluster-de-devzone), namespace `devzone-gitlab` (suffixé par instance).

```bash
devzone                        # état : identité git, GitHub, outils, modules
devzone activer gitlab         # active et installe GitLab dans le cluster des services
devzone desactiver gitlab      # désinstalle GitLab et supprime son namespace
devzone gitlab migrer          # installe, puis propose de supprimer l'ancien cluster kind
devzone gitlab migrer --oui    # idem sans confirmation
devzone gitlab nouveau-mdp [root|dev]  # mot de passe aléatoire (root ou dev) régénéré
devzone appliquer              # applique les modules actifs
devzone actif gitlab           # code 0 si GitLab est actif
```

- **Ressources** : au moins 8 Go de RAM **allouable dans le cluster des services** (somme des nœuds, refus sinon) ; environ 8 Go occupés une fois GitLab installé. Trop lourd pour la CI GitHub : testé à la main.
- **Durée** (mesurée) : installation complète environ 7 min (dont le chart GitLab, attendu jusqu'à `GITLAB_ATTENTE`, 1200 s par défaut) ; une relance sur une instance prête environ 35 s (rien n'est réinstallé ni re-poussé).
- **Ce qui est installé** : namespace `devzone-gitlab<instance>` dans le cluster choisi pour les services, étiqueté et isolé par NetworkPolicy ; chart `gitlab/gitlab` 9.11.16 (GitLab 18.11 CE) sans cert-manager, Prometheus, registry ni KAS, nginx en une réplique et services en `ClusterIP` (ingress désactivé) ; chart `gitlab/gitlab-runner` 0.88.2, exécuteur Kubernetes, URL interne et clone des jobs dans le même namespace.
- **Données de test** : groupe `devzone`, projet `devzone/demo` (Python, pipeline ruff et pytest), utilisateur `dev`, runner enregistré. Sur une relance, rien n'est recréé.
- **Accès dans le conteneur** : http://gitlab.localhost:8929, utilisateur `root`. Le nom `gitlab.localhost` pointe vers `127.0.0.1` dans `/etc/hosts` (entrée `127.0.0.1	gitlab.localhost # devzone:gitlab`, posée à l'activation et à chaque démarrage, remplacée si son adresse diffère, retirée à la désactivation). Deux relais `kubectl port-forward` écoutent sur `127.0.0.1:8929` et `127.0.0.1:2224` : `svc/gitlab-webservice-default` (8929→8181) et `svc/gitlab-gitlab-shell` (2224→22), dans le namespace de l'instance (PID et journal dans `workspace/.gitlab-web/` et `workspace/.gitlab-ssh/`). Ils sont indispensables à curl et à git en HTTP : libcurl résout tout nom `*.localhost` vers la boucle locale sans lire `/etc/hosts` (RFC 6761). ssh et glab lisent `/etc/hosts` et passent par le même relais.
- **Accès depuis le poste** : GitLab n'est pas publié directement sur le réseau ; le port-forward écoute dans le conteneur. Depuis le poste, utiliser `devzone port 8929` (et `devzone port 2224` pour SSH) si nécessaire.
- **Ancien cluster** : un cluster kind `gitlab<instance>` créé avant #396 n'est plus utilisé. Le récapitulatif `devzone` affiche `⚠ ancien cluster kind-gitlab<instance> : devzone gitlab migrer` tant qu'il existe. `devzone gitlab migrer` installe GitLab dans le cluster des services, puis supprime l'ancien cluster après confirmation (`--oui` sans terminal) ; sans terminal et sans `--oui`, l'installation se fait et l'ancien cluster est conservé (code 2). Les données de test de l'ancien cluster ne sont pas migrées.
- **Secrets** : mot de passe root, jeton root, mot de passe de `dev` et jeton du runner dans `workspace/.gitlab/` (droits 600, ignorés par git, jamais affichés). Mot de passe root : `cat workspace/.gitlab/root-password`.
- **Secrets Rails** : le secret `gitlab-rails-secret` du namespace `devzone-gitlab` est conservé dans `workspace/.gitlab/rails-secret.yaml` (600, ignoré par git) à la première installation, puis réappliqué avant `helm upgrade --install` à une réinstallation : le chart le réutilise et les sessions du navigateur restent valides, sans 422.
- **Réinstallation** : à défaut, si les secrets ont été perdus, la fin d'installation et le récapitulatif préviennent : « GitLab réinstallé : si le navigateur affiche 422, supprimez les données de site de gitlab.localhost ».
- **Mot de passe régénérable** : `devzone gitlab nouveau-mdp [root|dev]` applique un mot de passe aléatoire par `gitlab-rails runner` dans le pod toolbox, puis met à jour le fichier source et le regroupé `.password` ; rien n'est affiché, seulement le chemin.
- **Désactivation** : `devzone desactiver gitlab` arrête les deux relais, désinstalle les releases Helm `gitlab` et `gitlab-runner`, supprime le namespace `devzone-gitlab<instance>` et le reste de `workspace/.gitlab/`, mais **garde `rails-secret.yaml`** : « secret Rails gardé dans workspace/.gitlab/rails-secret.yaml (sessions du navigateur valides à la réinstallation) ». Le secret ne part qu'avec une désinstallation complète voulue (`devzone desactiver gitlab --oui`, ou la réponse `o` à la confirmation). Le cluster des services et son contexte courant ne sont pas touchés.

### Essai de bout en bout : `devzone test-gitlab`

`devzone test-gitlab` rejoue sur le poste l'essai réel du module et de la plateforme GitLab, que la CI GitHub ne peut pas lancer (8 Go de RAM). Le script est `.devcontainer/gitlab/test-gitlab.sh`.

```bash
devzone test-gitlab              # étapes 1 à 7
devzone test-gitlab --complet    # désactive, contrôle qu'il ne reste rien, puis réinstalle
devzone test-gitlab --statut     # publie aussi le statut gitlab-integration sur HEAD
```

- **Étapes**, chacune chronométrée : 1 module actif (sinon activé) ; 2 état « prêt » et runner en ligne ; 3 `gitlab.localhost` résolu vers `127.0.0.1` et relais TCP actifs sur 8929 et 2224 (`gitlab.sh hote-poser` et `relais-lancer`), sinon ✖ avec l'adresse ou le port manquant ; 4 pipeline de `devzone/demo` relancé sur `main` et attendu jusqu'à `success` ; 5 clone SSH (clé ed25519 jetable) et clone HTTP authentifié par un assistant d'identifiants (Basic `oauth2` + jeton lu dans le fichier, jamais dans les arguments d'un processus, l'URL ni `.git/config`) ; 6 plateforme `gitlab` avec `glab repo clone`, puis retour à la plateforme d'avant ; 7 suite d'intégration `test/gitlab/` de repowarden ([#533](https://github.com/simdevWarden/repowarden/issues/533)), dossier absent à la réf → étape sautée avec la raison, échec → sortie gardée dans `${TMPDIR:-/tmp}/devzone-test-gitlab-repowarden.log` (jeton masqué) et citée dans la raison. Avec `--complet`, une étape 8 précède les autres : `devzone desactiver gitlab`, puis contrôle qu'il ne reste ni namespace `devzone-gitlab<instance>` (nom calculé comme `gitlab.sh`), ni conteneur étiqueté `devzone.instance=<instance>` du module sur le Docker de l'hôte, ni `workspace/.gitlab/`, ni ligne `# devzone:gitlab` de `/etc/hosts`.
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

## MySQL

Le catalogue `mysql` fournit un MySQL partagé (une base par projet), sur le [cluster de devzone](#cluster-de-devzone), namespace `devzone-mysql`, joignable sur `127.0.0.1:3306` dans le conteneur.

```bash
devzone activer mysql
devzone mysql creer <projet> [--nouveau-mdp]
devzone mysql liste
devzone mysql supprimer <projet> [--oui]
devzone mysql volume                 # liste les PVC *-mysql-0, marque le monté
devzone mysql volume <nom>           # réapplique le StatefulSet sur ce volume (données gardées)
devzone mysql volume --supprimer <nom> [--oui]
devzone desactiver mysql             # retire StatefulSet, service et secret ; volume gardé
devzone mysql supprimer-donnees [--oui]  # supprime le namespace et les volumes (confirmé)
```

- **Volumes** : avant l'installation, si un seul PVC `*-mysql-0` existe dans le namespace, il est réutilisé ; aucun → claim `donnees` ; plusieurs → refus avec la liste et `devzone mysql volume <nom>`. `devzone mysql volume <nom>` réapplique le StatefulSet sur le PVC choisi sans supprimer les données. `--supprimer` demande confirmation `[o/N]` en terminal (`--oui` sans terminal) et refuse si le volume est monté. Le récapitulatif signale `⚠ volume <pvc> non utilisé : devzone mysql volume`.
- **Désinstaller et supprimer les données** : `devzone desactiver mysql` retire le StatefulSet, le service et le secret, garde le volume (PVC) et les bases, et affiche `✔ mysql retiré du cluster ; volume <pvc> et bases gardés : devzone mysql volume`. En terminal, la question est « Désactiver mysql retire le serveur, le volume et les bases restent. Supprimer aussi le namespace devzone-mysql et ses volumes ? » : un `oui` (ou `--oui` sans terminal) supprime aussi le namespace `devzone-mysql` et ses volumes ; un refus garde le volume et les bases, le serveur part quand même ; sans terminal et sans `--oui`, les données restent. `devzone mysql supprimer-donnees [--oui]` fait cette suppression seule : confirmation `[o/N]` en terminal, `--oui` obligatoire sinon (sinon refus avec la commande exacte). Le namespace et les volumes partent, `workspace/.mysql/root.env` est gardé ; `devzone mysql volume` liste ensuite les volumes restants.

## Argo CD

Le module `argocd` fournit Argo CD sur le [cluster de devzone](#cluster-de-devzone). L'étape A installe le module ; les Applications (services et workspace) viendront après #401.

```bash
devzone activer argocd      # installe Argo CD dans le cluster des services
devzone desactiver argocd   # désinstalle Argo CD, les autres services restent
devzone argocd etat         # état du module
```

- **Ce qui est installé** : chart `argo/argo-cd` en version figée (`10.14.0`), namespace `devzone-argocd` étiqueté `app.kubernetes.io/managed-by=devzone` et isolé par NetworkPolicy. Valeurs minimales (`.devcontainer/argocd/values.yaml`) : un réplica par composant, sans Dex ni notifications, serveur en `ClusterIP`, sans Ingress ni LoadBalancer.
- **Mémoire** : l'installation est refusée sous environ 1 Go de mémoire allouable dans le cluster, avec le message pour l'agrandir.
- **Accès** : un relais `kubectl port-forward` rend l'interface joignable sur https://127.0.0.1:8443 **dans le conteneur** (`ARGOCD_PORT` pour un autre port) ; relancé à chaque démarrage et par `devzone appliquer`. Sur le poste, l'accès passera par #401. PID et journal : `workspace/.argocd/relais.*`.
- **Mot de passe** : lu dans le Secret `argocd-initial-admin-secret`, rangé dans `workspace/.argocd/admin.env` (600) puis repris dans [`.password`](#identifiants-regroupés) ; utilisateur `admin`, jamais affiché.
- **Désactivation** : `helm uninstall` de la release et suppression du namespace `devzone-argocd`, puis de `workspace/.argocd/` ; **les autres services restent**, sous helm direct.

## Ports vers le poste

`devzone port` rend accessibles depuis le poste les applications qui écoutent **dans** le conteneur devzone : un relais `alpine/socat` par port, sur le Docker de l'hôte (#290).

```bash
devzone port <n>              # ouvre 127.0.0.1:<n> du poste → <n> du conteneur
devzone port                  # liste : port, ● actif ou ○ arrêté, application derrière
devzone port --fermer <n>     # retire le relais et le port de l'état
devzone port auto on|off     # active ou coupe le veilleur automatique
devzone port exclure <n>      # retire un port de la liste automatique
devzone port inclure <n>      # réintègre un port à la liste automatique
```

- **Relais** : conteneur `devzone-<instance>-port-<n>`, étiqueté `devzone.instance=<instance>` et `devzone.port=<n>`, image figée `SOCAT_IMAGE=alpine/socat:1.8.0.3` (`.devcontainer/ports.sh`). Il publie `-p 127.0.0.1:<n>:<n>` seulement, avec `--restart unless-stopped`.
- **Veilleur automatique (#394)** : `.devcontainer/ports-auto.sh` surveille les ports écoutés dans le conteneur toutes les 2 s (`ss -ltnH`). Un port non déjà relayé, non exclu, pas un service de devzone (5432, 8929, 2224) et pas un pont du veilleur est relayé : pont interne sur l'IP du conteneur si l'application n'écoute que sur `127.0.0.1`/`::1`, puis relais poste `devzone-<instance>-auto-<n>`. Le port disparu depuis plus de 10 s retire le pont et le relais. Un port déjà pris sur le poste est marqué occupé et n'est plus réessayé. Un seul veilleur tourne (verrou `mkdir` dans `/tmp/devzone-ports-auto/`, rafraîchi à chaque tour ; une instance morte est remplacée). Le veilleur s'arrête seul si le dossier d'état disparaît. Il ne tourne qu'à la demande des scripts de démarrage : tout autre appel est refusé (code 2), affiche la commande à faire (`devzone reparer`).
- **Désactivation** : `devzone port auto off` arrête le veilleur et retire les relais automatiques ; `devzone port auto on` le réactive : le veilleur repart au prochain démarrage du conteneur ou via `devzone reparer`. Au démarrage, les relais automatiques d'une session précédente sont retirés.
- **Réseau et IP** : lus par `docker inspect "$(hostname)"` sur le Docker de l'hôte ; le relais rejoint le conteneur par son IP sur son réseau Docker. Conteneur devzone introuvable (Docker de l'hôte absent) : refus clair, code 1.
- **État** : ligne `ports=8080,3000` dans `$RACINE/.devzone.modules`, triée et sans doublon ; `--fermer` retire le port. Le relais déjà ouvert est idempotent (message, code 0).
- **Démarrage** : `devzone demarrer` relance chaque relais de l'état vers l'IP actuelle du conteneur (elle change à chaque redémarrage). Un échec affiche un avertissement sans bloquer le démarrage ; `devzone reparer` le reprend sans redémarrer.
- **Refus, code 1** : port non numérique ou hors 1-65535 ; Docker de l'hôte injoignable ; port déjà pris sur le poste (échec de `docker run`, « port is already allocated » ou « address already in use »), l'état restant inchangé.
- **Plusieurs instances** : le nom du relais et l'étiquette portent `DEVZONE_INSTANCE` ; deux instances qui veulent le même port du poste : la seconde reçoit le refus « déjà utilisé ».
- **Récapitulatif** : ligne `ports vers le poste` avec `8080 ●, 3000 ○`, ou `aucun (devzone port <n>)`.
- **Désinstallation** : `make desinstaller` retire les conteneurs étiquetés `devzone.instance` (voir README, « Désinstaller »).
- **Spring Boot** : l'application doit écouter sur `0.0.0.0` (défaut). Un `server.address=127.0.0.1` la rend injoignable depuis le relais.

## Cluster de devzone

Les modules qui déploient un service (`postgres`, `gitlab`) s'installent sur **un seul cluster**, choisi une fois et gardé dans l'état (`cluster=` dans `$RACINE/.devzone.modules`).

- **Cluster local vs distant** : un cluster est considéré comme **local** quand son serveur écoute sur une adresse de boucle (`127.0.0.1`, `localhost`, `::1`, `host.docker.internal`) — lu dans la configuration kubeconfig, sans appel réseau. Le cluster kind dédié (`kind-devzone`) est toujours local. Tout autre cluster (serveur sur une adresse distante) est **distant**.
- **Choix** : à la première activation. `--contexte CTX` d'abord ; sinon, dans un terminal, un menu : le cluster par défaut est le contexte courant du kubeconfig de l'hôte s'il répond et est local (en pratique `docker-desktop`), sinon kind dédié `kind-devzone`. Le choix est gardé dans l'état et repris aux redémarrages. Le menu propose les clusters **locaux** d'abord, puis le **cluster kind dédié**, enfin les clusters **distants** (marqués « distant ») ; sans terminal : `kind-devzone`. Les clusters de l'hôte n'apparaissent qu'avec le [module `kubernetes`](#kubernetes) actif.
- **Cluster distant** : choisir un cluster distant nécessite une confirmation en terminal, ou `--confirmer CTX` sans terminal. Sans confirmation exacte, le choix est refusé. Quand le cluster de devzone est distant, le récapitulatif `devzone` affiche un avertissement `⚠ cluster distant : <contexte>`.
- **Voir / changer** : `devzone cluster` affiche le cluster et les possibles ; `devzone cluster CTX [--confirmer CTX]` y déplace les services actifs (désinstallés de l'ancien, installés sur le nouveau). **Les données ne sont pas migrées** : confirmation en terminal, `--oui` sans terminal.
- **Cluster de l'hôte** : devzone n'y crée que ses namespaces étiquetés `app.kubernetes.io/managed-by=devzone`, et les supprime à la désactivation. Désactiver le module `kubernetes` rend ce cluster injoignable pour les services.
- **Contexte courant** : les clusters kind sont créés sans basculer dessus ; `devzone utiliser CTX` bascule seulement le cluster de travail de kubectl, jamais le cluster des services de devzone. Si tu te retrouves sur un cluster interne (kind-devzone), reviens avec `devzone utiliser <ton cluster>`.
- **Namespace** : pour un contexte du poste (ceux de `hote.config`, recopié depuis le poste à chaque démarrage), le namespace fixé par `devzone utiliser -n` ne survit pas à un redémarrage ; pour les clusters kind du conteneur, il est gardé jusqu'au rebuild.

- **Deux notions** : `★` marque le cluster de travail de kubectl (kubectl, k9s, helm), `●` le cluster des services de devzone (`devzone cluster`). Un contexte peut porter les deux marques. `devzone clusters` affiche la vue.
- **Rebuild** : `le choix de kubectl` écrit dans `~/.kube/config`, qui n'est pas dans un volume ; un rebuild repart sur le cluster de l'hôte.

### Cluster des services et contexte devzone

- **Cluster unique** : tous les services (PostgreSQL, GitLab, etc.) vivent sur un seul cluster choisi via `devzone cluster CTX`. Le choix est gardé dans l'état (`cluster=` dans `$RACINE/.devzone.modules`) et survivre aux redémarrages.
- **Contexte devzone** : le contexte `devzone` de kubectl est posé sur le cluster des services (cluster + user extraits du contexte courant). Il est restauré sur le nouveau cluster quand `devzone cluster` déplace les services. Voir `changer_cluster` dans `cluster.sh`.
- **Déplacement de cluster** : `devzone cluster CTX [--oui]` déplace PostgreSQL : suppression dans l'ancien cluster, installation dans le nouveau. Les données ne sont pas migrées, d'où la confirmation requise.
- **Contextes locaux vs distants** : un cluster est local quand son serveur écoute sur une adresse de boucle (`127.0.0.1`, `localhost`, `::1`, `host.docker.internal`) — lu dans la configuration kubeconfig, sans appel réseau. Le cluster kind dédié (`kind-devzone`) est toujours local. Tout autre cluster (serveur sur une adresse distante) est distant. Le choix par défaut est d'abord le contexte courant de l'hôte (en pratique `docker-desktop`), puis kind dédié `kind-devzone`.
- **Cluster distant** : choisir un cluster distant nécessite une confirmation en terminal, ou `--confirmer CTX` sans terminal. Sans confirmation exacte, le choix est refusé. Quand le cluster de devzone est distant, le récapitulatif `devzone` affiche un avertissement `⚠ cluster distant : <contexte>`.
- **Namespace** : pour un contexte du poste (ceux de `hote.config`, recopié depuis le poste à chaque démarrage), le namespace fixé par `devzone utiliser -n` ne survit pas à un redémarrage ; pour les clusters kind du conteneur, il est gardé jusqu'au rebuild.

### Compte limité aux namespaces devzone

Le contexte `devzone` n'agit qu'avec un compte limité : shell, relais et agents n'ont jamais le rôle d'administrateur du cluster ([#430](https://github.com/SimBienvenueHoulBoumi/devzone/issues/430)).

- **Compte** : ServiceAccount `devzone-agent` du namespace `devzone-system`, lié au ClusterRole `edit` dans chaque namespace `devzone-*` par un RoleBinding. `edit` couvre lecture, écriture, secrets et NetworkPolicies du namespace ; ni RBAC ni quotas, et rien hors des namespaces `devzone-*` (la suppression d'un namespace, la lecture des nœuds restent des opérations d'administrateur).
- **Jeton** : TokenRequest de 24 h écrit dans le contexte `devzone` de `~/.kube/config` (user `devzone-agent`, entrée cluster copiée du contexte de l'hôte). Renouvelé à chaque démarrage du conteneur et par `devzone reparer` ; expiré, `devzone reparer` le renouvelle.
- **Administrateur réservé aux installeurs** : création du namespace, étiquette, RoleBinding et suppression passent par le contexte administrateur (`~/.kube/hote.config` pour les clusters de l'hôte, `~/.kube/config` pour les clusters kind). Le compte est posé par les installeurs sur un cluster encore vierge, utilisable au prochain renouvellement de jeton.
- **Sans cluster des services choisi** : `devzone reparer` ne renouvelle pas de jeton et le reste de l'application continue sur le contexte courant de kubectl.

### Isolement

- **NetworkPolicy `devzone-meme-namespace`** : pose une règle isolante dans un namespace : seuls les pods du même namespace peuvent joindre les services devzone (PostgreSQL, etc.). Cette règle est gérée par `devzone postgres autoriser <ns>` et `devzone postgres interdire <ns>`.
- **Que couvre l'isolation** :
  - Empêche qu'une application dans un namespace extérieur n'accède aux services PostgreSQL ou autres services devzone.
  - Permet à une application dans le même namespace de joindre les services sans restriction.
  - Les règles sont gérées via `kubectl --context devzone -n <ns> patch networkpolicy devzone-meme-namespace`.
- **Limites de l'isolation** :
  - Ne contrôle pas l'accès au niveau des bases de données PostgreSQL (c'est géré par les rôles et mots de passe PostgreSQL).
  - Ne s'applique pas aux cluster de l'hôte sans configuration explicite.
  - Les règles NetworkPolicy peuvent être retirées par `devzone postgres interdire <ns>`.
- **Vérification** : `devzone clusters` montre « isolé (NetworkPolicy) » pour le cluster des services, ⚠ si la règle manque dans un `devzone-*`.

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

## Sortie machine

Deux commandes affichent leur état sous forme d'objet JSON, pour les extensions
VS Code et les autres outils. La sortie texte n'est pas changée : ajoute
`--json` à la commande de ton choix.

- **Rien à faire, aucun secret** : chaque point à traiter a sa commande
  `devzone` prête à lancer (champ `commande`, `null` si rien à faire) ; aucun
  jeton, aucun mot de passe, jamais le contenu des identifiants (chemin seul,
  via le champ `identifiants`).
- **Robuste** : chaque rubrique est calculée à part. Si l'une échoue, sa valeur
  est `null`, le champ `erreurs` explique pourquoi, le JSON reste valide et le
  code de sortie vaut 0.
- **Stable et versionné** : les noms de champs sont en français, sans accent ni
  espace. Ajouter un champ reste dans `schema: 1` ; retirer ou renommer un champ
  fait passer `schema` à 2 : fonde ta lecture dessus.

`devzone etat --json` (le récapitulatif complet, rubrique par rubrique) :

```json
{
  "schema": 1,
  "devzone": { "version": "0.22.0", "disponible": "0.23.0" },
  "identite_git": { "ok": true, "nom": "…", "email": "…", "commande": null },
  "plateforme": { "nom": "github", "url": null,
                  "github": { "connecte": true, "workflow": true, "commande": null } },
  "outils": { "retards": [ { "paquet": "…", "figee": "…", "installee": "…" } ], "commande": "devzone appliquer" },
  "modules": [ { "nom": "postgres", "actif": true, "description": "…", "etat": "prêt sur docker-desktop…",
                 "echec": null, "commande": null } ],
  "docker_hote": true,
  "docker_hote_actif": true,
  "clusters": { "services": "docker-desktop", "services_distant": false,
                "travail": "docker-desktop", "travail_interne": false, "commande": null },
  "ports": [ { "port": 8080, "actif": true, "application": "…" } ],
  "identifiants": "/workspaces/devzone/.password",
  "alertes": [ { "code": "relais_docker", "message": "…", "commande": "devzone reparer" } ],
  "erreurs": {}
}
```

Les alertes possibles : `relais_docker`, `paquets`, `worktree`,
`cluster_distant` (services sur un cluster distant), `cluster_interne`
(cluster de travail de devzone, revenir avec `devzone utiliser <ton cluster>`).

`devzone agent etat --json` (sessions, écarts, droits modifiés) :

```json
{
  "schema": 1,
  "sessions": [ { "journal": "dz-337.log", "modele": "beam-free", "debut": "2026-11-06T13:17:33Z",
                  "dernier_ecrit": "2026-11-06 13:20:14", "en_cours": true } ],
  "ecarts": [ { "modele": "crouton-alpha-free", "cause": "pays", "fin": "2026-11-13T13:24:50Z" } ],
  "alertes_droits": [ "dz-361" ]
}
```

`en_cours` vaut `true` quand une session d'agent travaille encore sur ce
dossier. Un écart (`quota`, `pays`, `muet`…) prend fin à la date `fin` : un
outil peut relancer la consigne ensuite avec `devzone agent`.

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

