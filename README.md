# devzone

Zone de dev conteneurisée : Java 21 + Maven, Node LTS + pnpm, Python 3.12 + uv, Docker (in-docker), kubectl, helm, k9s, gh, repowarden (hooks git globaux) et ses outils : shellcheck, bats, actionlint, gitleaks, ruff, vulture.

## VS Code

| Action | Commande (`Cmd+Shift+P`) |
|---|---|
| Lancer | *Dev Containers: Reopen in Container* |
| Arrêter | *Remote: Close Remote Connection* — le conteneur s'arrête à la fermeture de la fenêtre |
| Reconstruire | *Dev Containers: Rebuild Container* (après modif de `.devcontainer/`) |

## CLI (sans VS Code)

Depuis le dossier `devzone/` :

| Commande | Action |
|---|---|
| `make up` | Lance le conteneur (le crée si absent) |
| `make shell` | Ouvre un shell dedans (lance si besoin) |
| `make stop` | Arrête le conteneur, état conservé |
| `make down` | Supprime le conteneur (caches Maven/pnpm conservés dans leurs volumes) |
| `make rebuild` | Reconstruit de zéro (après modif de `.devcontainer/`) |
| `make status` | État du conteneur |

`make` seul affiche cette liste. Les logs de `up`/`rebuild` vont dans `.devzone.log` ; seule la fin s'affiche en cas d'échec.

> Ne pas lancer `make up` pendant que VS Code ouvre ou reconstruit le conteneur : deux lancements simultanés créent des conteneurs en double.

## Organisation

```
devzone/
├── .devcontainer/   # définition du conteneur
└── workspace/       # tes projets (ignorés par git, chacun son dépôt)
```

## Notes

- Docker-in-Docker : démon isolé, ses images ne sont pas partagées avec Docker Desktop.
- Caches Maven (`~/.m2`) et pnpm stockés dans des volumes Docker (`devzone-m2`, `devzone-pnpm`) → conservés entre rebuilds.
- Cluster K8s local : `kind` ou `k3d` à lancer dans le conteneur via le Docker interne.
