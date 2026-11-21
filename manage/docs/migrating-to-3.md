# Migrating to devzone 3.0

devzone 3.0 uses English everywhere a user or a script reads a name: environment variables, files, state keys, JSON keys, answers and the words of the outputs. There is no alias for the old names, except the one-time automatic move of the files you already have (see [Files and folders](#files-and-folders)). `devzone update` (or `devzone workspace update`) does that move for you.

What you must do yourself: rename the variables and keys in your own scripts, CI and tooling that read them. Everything else below is for reference.

## Environment variables

| Before | Now |
|---|---|
| `DEVZONE_RACINE` | `DEVZONE_ROOT` |
| `DEVZONE_ETAT` | `DEVZONE_STATE` |
| `DEVZONE_KUBE_HOTE` | `DEVZONE_KUBE_HOST` |
| `DEVZONE_INTERACTIF` | `DEVZONE_INTERACTIVE` |
| `DEVZONE_DANS_CONTENEUR` | `DEVZONE_IN_CONTAINER` |
| `DEVZONE_SANS_DEMARRER` | `DEVZONE_NO_START` |
| `DEVZONE_RECONSTRUIRE` | `DEVZONE_REBUILD` |
| `DEVZONE_CLUSTER_DISTANT` | `DEVZONE_CLUSTER_REMOTE` |
| `DEVZONE_COMMANDE` | `DEVZONE_COMMAND` |
| `DEVZONE_ECHEC` | `DEVZONE_FAILED` |
| `DEVZONE_PROGRESSION` | `DEVZONE_PROGRESS` |
| `DEVZONE_SIGNE_DE_VIE` | `DEVZONE_HEARTBEAT` |
| `DEVZONE_ATTENTE_QUESTION` | `DEVZONE_QUESTION_WAIT` |
| `DEVZONE_IA_MESURES` | `DEVZONE_AI_MEASURES` |
| `DEVZONE_IMAGE_COPIE` | `DEVZONE_IMAGE_COPY` |
| `DEVZONE_DOCKER_GARDE` | `DEVZONE_DOCKER_GUARD` |
| `DEVZONE_CATALOGUE`, `_ATTENTE`, `_REEL`, `_VEILLEUR_DIR` | `DEVZONE_CATALOG`, `_WAIT`, `_REAL`, `_WATCHER_DIR` |
| `DEVZONE_PAQUETS_APT`, `_APTCACHE`, `_DPKG_QUERY`, `_MAJ`, `_MARQUE`, `_SUDO` | `DEVZONE_PACKAGES_APT`, `_APTCACHE`, `_DPKG_QUERY`, `_UPDATE`, `_MARKER`, `_SUDO` |
| `DEVZONE_PORTS_AUTO_DELAI`, `_DELAI_DISPARITION`, `_PAS`, `_REEL`, `_RETARD` | `DEVZONE_PORTS_AUTO_DELAY`, `_DISAPPEARANCE_DELAY`, `_STEP`, `_REAL`, `_LATE` |
| `DEVZONE_PORTS_WORKSPACE_PAS`, `_REEL` | `DEVZONE_PORTS_WORKSPACE_STEP`, `_REAL` |
| `DEVZONE_KIND_REEL` | `DEVZONE_KIND_REAL` |
| `DEVZONE_EGRESS_PAS` | `DEVZONE_EGRESS_STEP` |
| `DEVZONE_WORKSPACE_ATTENTE`, `_PAS` | `DEVZONE_WORKSPACE_WAIT`, `_STEP` (same role as the names that already existed) |
| `DEVZONE_AGENT_ETAT` | `DEVZONE_AGENT_STATE` |
| `DEVZONE_AGENT_PAS` | `DEVZONE_AGENT_STEP` |
| `DEVZONE_AGENT_PAUSE_RANG` | `DEVZONE_AGENT_PAUSE_RANK` |
| `DEVZONE_AGENT_RESEAU_MAX`, `_RESEAU_PAS` | `DEVZONE_AGENT_NETWORK_MAX`, `_NETWORK_STEP` |
| `DEVZONE_AGENT_VERROU_MAX` | `DEVZONE_AGENT_LOCK_MAX` |
| `DEVZONE_AGENT_FIGEE` | `DEVZONE_AGENT_FROZEN` |
| `DEVZONE_AGENT_ECART_PAYS` | `DEVZONE_AGENT_COUNTRY_EXCLUSION` |

The variables that switch a real action on (`DEVZONE_*_REAL`) and `DEVZONE_IN_CONTAINER` now take the value `yes` instead of `oui`.

The variables of the host socket relay (`DEVZONE_RELAIS_*`) are gone with the relay (see [Removed](#removed)).

## Answers

The prompts read `[y/N]` and accept `y`, `Y` or `yes`. The old `o` and `oui` are not accepted any more. `--yes` is unchanged.

## Files and folders

These are renamed once, automatically, when the pod starts and by `devzone update` and `devzone workspace update`. A name is moved only when the old one exists and the new one does not: an existing new name is never overwritten, and a second run does nothing. When both names are folders, the entries of the old folder that the new one lacks are moved into it, and the old folder is removed only when it is left empty; a file present on both sides stays in the old folder, and a message on stderr names it.

| Before | Now |
|---|---|
| `.devzone.paquets` | `.devzone.packages` |
| `.devzone.sauvegarde/` | `.devzone.backup/` |
| `.devzone.ports-workspace/` | `.devzone.workspace-ports/` |
| `.devzone.etat` | `.devzone.state` |
| `.devzone.catalogue-veilleur/` | `.devzone.catalog-watcher/` |
| `.devzone.modules-echec-<module>` | `.devzone.modules-failed-<module>` |
| `.devzone-empreinte` (next to each `SKILL.md`) | `.devzone-fingerprint` |
| `/tmp/devzone-paquets.echec` | `/tmp/devzone-packages.failed` |

The old French markers written in `SKILL.md`, `opencode.jsonc` and the header of `.devzone.modules` are no longer recognised. `devzone enable ia` writes the English ones again.

## State file keys

In `.devzone.modules`, the line `plateforme=<value>` becomes `platform=<value>`. It is rewritten once, automatically, with the value kept. If `platform=` already exists, the old line is only removed.

## JSON output (`schema: 2`)

`devzone status --json`, `devzone catalog json` and the ports output use English keys. `schema` is now `2`. A reader written for `schema: 1` must be updated.

| Before | Now |
|---|---|
| `nom` | `name` |
| `actif` | `active` |
| `etat` | `state` |
| `echec` | `failed` |
| `commande` | `command` |
| `outils` | `tools` |
| `plateforme` | `platform` |
| `disponible` | `available` |
| `identite_git` | `git_identity` |
| `identifiants` | `credentials` |
| `alertes` | `alerts` |
| `erreurs` | `errors` |
| `retards` | `outdated` |
| `paquet`, `figee`, `installee` | `package`, `frozen`, `installed` |
| `travail`, `travail_interne` | `work`, `internal_work` |
| `services_distant` | `services_remote` |
| `connecte` | `connected` |

The alert code `paquets` is now `packages`. In `catalog/mysql/app.conf`, `nom=` is now `name=`.

## Words of the outputs

The `status` output of the modules (gitlab, postgres, argocd, mysql) and the states of the catalog use English words, which scripts may match:

| Before | Now |
|---|---|
| `désactivé` | `disabled` |
| `prêt`, `prêt sur <context>` | `ready`, `ready on <context>` |
| `en échec`, `en échec sur` | `failed`, `failed on` |
| `relais arrêté` | `relay stopped` |
| `runner en ligne`, `runner hors ligne` | `runner online`, `runner offline` |
| catalog: `disponible`, `installée`, `attendue`, `echec` | `available`, `installed`, `expected`, `failed` |

## Removed

- The relay of the host Docker socket and the option that controlled it: `docker-hote` (a `docker-hote=…` line in `.devzone.modules` is ignored, `devzone enable docker-hote` answers "unknown module"), `DEVZONE_RELAIS_*`, the relay line of `devzone status` and `devzone repair`, the alert `relais_docker`, and the JSON fields `docker_hote` and `docker_hote_actif`. devzone no longer talks to the host Docker socket.
- The Docker workstation option `--docker` of `devzone <folder>`: refused as an unknown option. Create the devzone with `--kubernetes` (the cluster must answer).
- The Docker check on the host before `devzone <folder>`: creation no longer uses Docker.
- `devzone workspace migrate`: copy of a Docker workstation (its folders and its `devzone-*` volumes) to the cluster. Projects moved earlier stay in the pod.
- `devzone workspace revert [--bring-back]`: back to the Docker workstation.
- `devzone workspace clean-docker`: removal of the `devzone-*` Docker volumes.
- The old French names `migrer`, `revenir`, `nettoyer-docker` and the option `--rapatrier`: refused with exit code 1 and a notice that the command or option was removed, without creating any folder.
- Old French command names stay refused with the new name, as since 1.1.0 (see [Removed names](reference.md#removed-names)).

## Checking your own scripts

Search them for the old names of the tables above, for `oui` answers, and for the JSON keys of `schema: 1`.
