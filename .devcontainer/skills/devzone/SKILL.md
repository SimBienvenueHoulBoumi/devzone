<!-- devzone : skill posée par devzone activer ia -->

# Skill devzone (assistants IA)

Cette skill est pour Claude Code (lead) et opencode (développeur) dans un conteneur devzone. Elle est posée par `devzone activer ia` dans `~/.claude/skills/devzone/` et `~/.config/opencode/skills/devzone/` (volumes, gardés aux rebuilds).

## Règle d'or

Tout se fait dans le conteneur, avec les commandes `devzone` — jamais les scripts de `.devcontainer/` ni `devzone <commande>` sur le vrai dépôt.

## Worktrees

Les projets vivent dans `workspace/` ; les worktrees des tickets sous `workspace/wt/`. Un worktree se crée et se supprime **dans le conteneur** (`git worktree add` / `git worktree remove`). Jamais `git worktree prune` de l'hôte, ni un outil de l'hôte (VS Code, GitHub Desktop). Un worktree créé sur le poste a un chemin absolu que le conteneur ne voit pas : le gérer du côté qui l'a créé.

## Modules

Les modules sont désactivés par défaut, activés à la demande, sans rebuild :

- `devzone activer ia` : Claude Code et opencode (versions figées), garde-fou repowarden, configuration opencode par défaut. Se connecter ensuite : `claude` (puis `/login`), `opencode auth login`.
- `devzone desactiver ia` : désinstalle les assistants ; retire le garde-fou et la configuration opencode par défaut ; garde l'état de `devzone agent`, les journaux `workspace/.agents/` et les connexions.
- `devzone activer kubernetes` : se connecte au cluster de la machine à chaque démarrage et installe metrics-server sur les clusters locaux.
- `devzone activer gitlab` : installe GitLab de test dans le cluster des services (namespace `devzone-gitlab*`).
- `devzone activer postgres` : PostgreSQL partagé, une base par projet (`devzone postgres creer <projet>`).
- `devzone desactiver <module>` : désactive et applique tout de suite.
- `devzone appliquer` : installe ce qui est actif.

Le choix est propre à chaque devzone, gardé dans `$RACINE/.devzone.modules`.

## Diriger opencode (devzone agent)

`devzone agent <dossier> <fichier-consigne>` dirige opencode sur une consigne, au premier plan ou en parallèle (`&`, une par ticket et par worktree).
- `devzone agent etat` : sessions, modèles écartés et leur cause.
- `devzone agent liberer <modèle>|--tous` : lève un écart de modèle.

Le journal est `workspace/.agents/<dossier>.log`. `--auto` évite l'attente d'une permission ; `< /dev/null` évite une session muette.

## Garde-fou et fichiers protégés

Avec `ia` actif, le garde-fou repowarden est branché pour Claude Code et opencode : l'agent est arrêté avant de modifier `main`/`develop`, de commiter sans `repowarden cc` ou de contourner les hooks. `repowarden cc -m "…"` pour commiter.

Fichiers de droits protégés (jamais écrits par un agent, listés fixes, qu'aucune variable ne change) : `.devcontainer/opencode/agent.json`, `.devcontainer/opencode.jsonc`, `.repowarden.conf`, `.devcontainer/agent-droits.sh`. Un agent qui les touche est refusé et le changement est annulé dans l'arbre.

## Services Kubernetes

Les services (PostgreSQL, GitLab) vivent sur le **cluster des services de devzone**, choisi une fois (`devzone cluster CTX`) et gardé dans l'état. Le contexte `devzone` de kubectl est posé sur ce cluster. Namespaces des services : `devzone-*`. Le module `kubernetes` actif relie au cluster de la machine et installe metrics-server au démarrage.

## Ce qui revient au mainteneur

Le développeur (opencode) code, teste et commite `repowarden cc` ; le lead (Claude Code) relit, pousse, fait l'essai réel et suit la CI. Les connexions (GitHub, Claude Code, opencode), les Ready et les fusions (merge) relèvent du mainteneur. La skill « repowarden » est déjà posée par `repowarden agents init` : vérifie seulement qu'elle est présente.
