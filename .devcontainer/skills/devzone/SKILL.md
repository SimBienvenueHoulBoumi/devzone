---
name: devzone
description: Utiliser pour travailler dans un conteneur devzone — modules et catalogue, devzone agent, worktrees, garde-fou.
---

<!-- devzone : skill posée par devzone activer ia -->

# Skill devzone (assistants IA)

Cette skill est pour Claude Code (lead) et opencode (développeur) dans un conteneur devzone. Elle est posée par `devzone activer ia` dans `~/.claude/skills/devzone/` et `~/.config/opencode/skills/devzone/` (volumes, gardés aux rebuilds). Pour la personnaliser sans qu'elle soit remplacée, retirer la ligne repère ci-dessus.

## Règle d'or

Tout se fait dans le conteneur, avec les commandes `devzone`, jamais en lançant les scripts de `.devcontainer/` à la main.

Dans les tests bats, n'utilise que de faux outils dans un dossier `bin` temporaire : jamais un script système réel (`devzone`, `kubectl`, `helm`…) sous bats.

## Worktrees

Les projets vivent dans `workspace/` ; les worktrees des tickets sous `workspace/wt/`. Un worktree se crée et se supprime **dans le conteneur** (`git worktree add` / `git worktree remove`). Jamais `git worktree prune` de l'hôte, ni un outil de l'hôte (VS Code, GitHub Desktop). Un worktree créé sur le poste a un chemin absolu que le conteneur ne voit pas : le gérer du côté qui l'a créé.

## Modules et catalogue

Les modules sont désactivés par défaut, activés à la demande, sans rebuild :

- `devzone activer ia` : Claude Code et opencode (versions figées), garde-fou repowarden, configuration opencode par défaut. Se connecter ensuite : `claude` (puis `/login`), `opencode auth login`.
- `devzone desactiver ia` : désinstalle les assistants ; retire le garde-fou et la configuration opencode par défaut ; garde l'état de `devzone agent`, les journaux `workspace/.agents/` et les connexions.
- `devzone activer kubernetes` : se connecte au cluster de la machine à chaque démarrage et installe metrics-server sur les clusters locaux.
- `devzone activer gitlab` : installe GitLab de test dans le cluster des services (namespace `devzone-gitlab*`).
- `devzone activer postgres` : PostgreSQL partagé, une base par projet (`devzone postgres creer <projet>`).
- `devzone activer mysql` : MySQL partagé du catalogue, une base par projet.
- `devzone activer argocd` : Argo CD du cluster des services, interface dans le conteneur sur https://127.0.0.1:8443.
- `devzone desactiver docker-hote` : retire le socket Docker de l'hôte (puis `make rebuild` sur le poste) ; `devzone activer docker-hote` le remet.
- `devzone desactiver <module>` : désactive et applique tout de suite.
- `devzone appliquer` : installe ce qui est actif.
- `devzone reparer` : relance relais Docker, gitlab, postgres, mysql, argocd, ports étiquetés et le veilleur du catalogue.
- `devzone etat --json` : récapitulatif complet en JSON, pour les outils (aucun secret, commande à lancer par point à traiter).

Le catalogue d'applications se consulte avec `devzone catalogue` ; un veilleur applique à chaud les changements de `.devzone.modules`, et `devzone reparer` le relance. MySQL se pilote avec `devzone mysql creer <projet>`, `devzone mysql liste`, `devzone mysql supprimer <projet>`, `devzone mysql volume [<nom>|--supprimer <nom>]` et `devzone mysql supprimer-donnees` (données gardées par défaut).

Le choix est propre à chaque devzone, gardé dans `.devzone.modules` du dossier devzone.

## Diriger opencode (devzone agent)

`devzone agent <dossier> <fichier-consigne>` dirige opencode sur une consigne, au premier plan ou en parallèle (`&`, une par ticket et par worktree).
- `devzone agent etat` : sessions, modèles écartés et leur cause.
- `devzone agent liberer <modèle>|--tous` : lève un écart de modèle.

Le journal est `workspace/.agents/<dossier>.log`. `--auto` évite l'attente d'une permission ; `< /dev/null` évite une session muette.

## Garde-fou et fichiers protégés

Avec `ia` actif, le garde-fou repowarden est branché pour Claude Code et opencode : l'agent est arrêté avant de modifier `main`/`develop`, de commiter sans `repowarden cc` ou de contourner les hooks. `repowarden cc -m "…"` pour commiter.

Fichiers de droits protégés (jamais écrits par un agent, listés fixes, qu'aucune variable ne change) : `.devcontainer/opencode/agent.json`, `.devcontainer/opencode.jsonc`, `.repowarden.conf`, `.devcontainer/agent-droits.sh`. Un agent qui les touche est refusé et le changement est annulé dans l'arbre.

## Services Kubernetes et workspace

Les services (PostgreSQL, MySQL, GitLab, Argo CD) vivent sur le **cluster des services de devzone**, choisi une fois (`devzone cluster CTX`) et gardé dans l'état. Le contexte `devzone` de kubectl est posé sur ce cluster. Namespaces des services : `devzone-*`. `devzone cluster` affiche le cluster et les possibles, `devzone clusters` donne la vue travail/services ; le module `kubernetes` actif relie au cluster de la machine et installe metrics-server au démarrage.

Le poste de développement peut tourner dans le cluster : `devzone workspace demarrer|arreter|etat|shell|vscode|copier-vers <dossier>|copier-depuis <dossier>` pilote le workspace Kubernetes (lancé du poste).

## Ce qui revient au mainteneur

Le développeur (opencode) code, teste et commite `repowarden cc` ; le lead (Claude Code) relit, pousse, fait l'essai réel, suit la CI et peut passer une PR en ready quand tous ses jobs sont verts. Les connexions (GitHub, Claude Code, opencode), la validation des tickets, les approbations de déploiement et le lancement des releases restent au mainteneur. La skill « repowarden » est déjà posée par `repowarden agents init` : vérifie seulement qu'elle est présente.
