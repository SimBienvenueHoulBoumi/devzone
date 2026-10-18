# Contribuer

## Tests

| Tests | Commande | Où | Durée |
|---|---|---|---|
| Commande `devzone` du conteneur et commande npm (unitaires) | `bats test/` | dans le conteneur | quelques secondes |
| Fonctionnels : un devzone construit et utilisé comme par un utilisateur (outils, modules, Kubernetes avec kind, hooks repowarden, redémarrage, rebuild) | `make test-fonctionnel` | sur ta machine (Docker, Node) | 5 à 10 min |
| CLI dans un vrai terminal : chaque commande tapée comme par un humain (pseudo-terminal), avec un délai maximal ; une commande qui attend une entrée échoue. Cibles `make` (`help`, `up`, `shell`, `status`, `stop`, `down`, `rebuild`, `desinstaller`), commande npm (`devzone <dossier>`, `desinstaller`, `--version`, `--help`), commande `devzone` du conteneur, scripts de démarrage | `make test-cli` | sur ta machine (Docker, Node, Python 3) | 10 à 15 min |
| Windows (local et CI) | `bash test/windows.sh` | macOS/Linux (local) ou Windows Git Bash (CI) | quelques secondes |

**Windows (CI) : ce qui est vérifié / ce qui n'est pas (conteneur, VS Code).** Le job `windows` vérifie sous `windows-latest` (checkout avec `core.autocrlf=true`, comme un poste Windows) : aucun CRLF dans les scripts (tout fichier suivi commençant par `#!`, plus le `Makefile`) ; empaquetage npm (`npm pack`) et installation de l'archive — dans un préfixe npm isolé sous `$TMP` (le global de la machine n'est jamais touché) ; `devzone --version`, `devzone --help`, option inconnue (avec sortie en erreur) ; `devzone <dossier>` avec `DEVZONE_SANS_DEMARRER=1` (création des fichiers attendus, dossier non vide refusé sans écrasement) ; `devzone desinstaller` hors d'un dossier devzone refusé. Le même parcours passe ensuite par `cmd`, c'est-à-dire le raccourci `.cmd` de npm, avec cette fois une installation globale réelle (le cas d'un utilisateur Windows). Ce qui n'est **pas** vérifié sous Windows CI : `make up` et le conteneur Linux (impossibles sur les runners Windows de GitHub), ainsi que VS Code et Docker Desktop (vérifiés à la main).

Les tests fonctionnels et ceux de la CLI travaillent sur une copie du dépôt, avec leurs propres volumes (`devzone-test-…`), puis suppriment tout (conteneur, volumes, image), même en cas d'échec : ton devzone, tes connexions et le cluster de ta machine ne sont jamais touchés (seul un cluster kind de test est utilisé). En CI, le workflow `fonctionnel` les lance (trois jobs : fonctionnel, cli et windows) sur chaque PR qui modifie `.devcontainer/`, `test/`, `bin/`, le `Makefile`, `scripts/`, `.gitattributes` ou `package.json`, et à la main (*Actions → fonctionnel → Run workflow*).



## Versions et livraison

Flux `develop` → `main`, géré par repowarden, **sans geste après le merge d'un ticket** :
1. Le travail entre dans `develop` (branche par défaut), par une PR liée à un ticket. **Son merge est la validation humaine.** Une PR de travail ouverte vers `main` est reciblée vers `develop` par la CI.
2. Le bot de release publie aussitôt une **préversion** `vX.Y.Z-next.N` et tient à jour la **PR de livraison** `develop` → `main`.
3. La GitHub App **merge la PR de livraison** dès que ses vérifications sont vertes (`repowarden`, et `livraison` : préversion publiée). Ce merge publie le tag `vX.Y.Z` et la [release GitHub](https://github.com/SimBienvenueHoulBoumi/devzone/releases). Une vérification rouge bloque la livraison, visible sur la PR.

`main` reste ainsi à jour avec `develop`. La version suit les Conventional Commits : `fix` → correctif, `feat` → mineure ; une livraison sans `fix` ni `feat` (documentation, CI…) met `main` à jour sans nouvelle version.

**Tickets** : à une version, le job `tickets` de `release.yml` passe les tickets `statut: préprod` en `statut: done` et les ferme, avec la version. repowarden ne le fait qu'à un tag stable : pour une livraison sans nouvelle version, le job `tickets-sans-version` lance le même suivi de repowarden, et les tickets sont fermés avec le commentaire « Publié dans **main, sans nouvelle version (<commit>)** ».

**Réglages, au choix du mainteneur** :

| Réglage | Où | Effet |
|---|---|---|
| Livraison automatique (défaut de devzone) | `release.yml`, job `release` : `delivery-auto: true` et `delivery-on-push: true` ; `.repowarden.conf` : `deliveryApproval = auto` | la PR de livraison est armée en merge automatique par la GitHub App et part dès que ses vérifications sont vertes (réglage officiel de repowarden ≥ 4.9) |
| Livraison manuelle | `release.yml` : `delivery-auto: false` (ou retiré) ; `.repowarden.conf` : `deliveryApproval = review` | la PR de livraison attend ton merge |
| Préversion à chaque merge (devzone) ou le soir | `release.yml`, job `release` : `preversion-on-push: true` ou rien | sans préversion à chaque merge, la livraison attend celle du soir |
| Préversion obligatoire avant une version stable (défaut, celui de devzone) | `release.yml`, job `release` : rien, ou `preversion-obligatoire: false` pour la désactiver | désactivée, la vérification `livraison` passe d'office (« préversion non exigée ») : la PR de livraison n'attend plus de préversion, mais la version stable n'a pas été testée en préversion |

Prérequis de la livraison automatique : la GitHub App du dépôt (`repowarden app init`, lancé sur ta machine ; voir [Dépannage](#dépannage)). Sans elle, un merge fait par le jeton des Actions ne déclencherait pas la release.



## Organisation

```text
devzone/
├── .devcontainer/
│   ├── Dockerfile              # image de base + outils figés (versions et sha256)
│   ├── devcontainer.json       # features (langages, Docker, Kubernetes, gh), volumes, extensions VS Code
│   ├── devcontainer-lock.json  # versions figées des features
│   ├── devzone                 # commande devzone : modules (ia, kubernetes), versions des assistants IA
│   ├── post-create.sh          # premier démarrage : droits des volumes, git, repowarden, modules actifs (sans question)
│   ├── demarrage.sh            # chaque démarrage : identité git, clusters, puis récapitulatif (devzone)
│   ├── kube-config.sh          # contextes kind ; module kubernetes : cluster de l'hôte, metrics-server
│   ├── metrics-server.sh       # metrics-server sur les clusters locaux (CPU et RAM dans k9s)
│   └── git-identite.sh         # identité git déduite du compte gh si elle manque
├── .github/workflows/
│   ├── fonctionnel.yml         # tests fonctionnels et de la CLI sous terminal (PR touchant le conteneur, les tests ou la CLI)
│   ├── repowarden.yml          # vérifications repowarden de chaque PR (PR mal visée reciblée vers develop)
│   ├── tickets.yml             # suivi des tickets : branche, PR brouillon, statuts jusqu'à la production
│   ├── release.yml             # préversions sur develop, livraison develop → main
│   └── nettoyage.yml           # branches mergées supprimées (main et develop conservées)
├── .repowarden.conf            # réglages repowarden : flux develop → main
├── Makefile                    # pilotage sans VS Code
├── scripts/
│   ├── lancer.sh               # make up / rebuild : étapes affichées, question du conteneur signalée
│   └── desinstaller.sh         # make desinstaller : retire tout ce que devzone a créé
├── bin/devzone                 # commande npm : npx devzone <dossier>, devzone desinstaller
├── package.json, LICENSE       # paquet npm devzone (licence GPL-3.0-only)
├── test/
│   ├── devzone.bats            # tests de la commande devzone (bats test/)
│   ├── cli.bats                # tests de la commande npm, du contenu du paquet et de scripts/lancer.sh
│   ├── fonctionnel.sh          # tests fonctionnels (make test-fonctionnel)
│   ├── cli-terminal.sh         # tests de la CLI dans un vrai terminal (make test-cli)
│   └── terminal.py             # lance une commande sous pseudo-terminal, avec délai maximal
└── workspace/                  # tes projets (ignorés par git, chacun son dépôt)
```

