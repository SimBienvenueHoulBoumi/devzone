# devzone

Zone de dev conteneurisée : Java 21 + Maven, Node LTS + pnpm, Python 3.12 + uv, Docker (in-docker), kubectl, helm, k9s, gh, et [repowarden](https://github.com/simdevWarden/repowarden) (hooks actifs, shellcheck, bats, actionlint, gitleaks, ruff, vulture).

## VS Code

| Action | Commande (`Cmd+Shift+P`) |
|---|---|
| Lancer | *Dev Containers: Reopen in Container* |
| Arrêter | *Remote: Close Remote Connection* — le conteneur s'arrête à la fermeture de la fenêtre |
| Reconstruire | *Dev Containers: Rebuild Container* (après modif de `.devcontainer/`) |

## CLI (sans VS Code)

Depuis le dossier `devzone/` :

```bash
# Lancer (crée le conteneur si absent, sinon le redémarre)
npx @devcontainers/cli up --workspace-folder .

# Ouvrir un shell dedans
npx @devcontainers/cli exec --workspace-folder . bash

# Arrêter (conserve le conteneur et son état)
docker stop $(docker ps -q --filter "label=devcontainer.local_folder=$PWD")

# Supprimer le conteneur (les caches Maven/pnpm restent dans leurs volumes)
docker rm -f $(docker ps -aq --filter "label=devcontainer.local_folder=$PWD")

# Reconstruire de zéro
npx @devcontainers/cli up --workspace-folder . --remove-existing-container
```

## Organisation

```
devzone/
├── .devcontainer/   # définition du conteneur
└── workspace/       # tes projets (ignorés par git, chacun son dépôt)
```

## Premier lancement

```bash
gh auth login              # tickets, PR, protection (repowarden ticket, repowarden proteger…)
repowarden                 # état : hooks actifs, outils présents
```

Les hooks de repowarden s'appliquent à tous les projets du `workspace/` (commits, branches, secrets, formatage, tests). Versions d'actionlint et gitleaks identiques à la CI de repowarden, empreintes vérifiées à l'installation.

## Notes

- Docker-in-Docker : démon isolé, ses images ne sont pas partagées avec Docker Desktop.
- Caches Maven (`~/.m2`) et pnpm stockés dans des volumes Docker (`devzone-m2`, `devzone-pnpm`) → conservés entre rebuilds.
- Cluster K8s local : `kind` ou `k3d` à lancer dans le conteneur via le Docker interne.
