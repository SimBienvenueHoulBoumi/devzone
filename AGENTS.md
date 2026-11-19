# Règle du dépôt : Kubernetes seulement

devzone se décrit avec le cluster, le pod et les nœuds ; jamais « Docker ».
Seuls les pods sont des conteneurs. Pour un essai jetable : `kubectl run` ou
`kubectl create ns`, puis suppression. Le garde-fou arrête les agents qui
lancent `docker` ; `DEVZONE_ALLOW_DOCKER=1` est réservé à une action sur
l'hôte lui-même. Détail : `.devcontainer/skills/devzone/SKILL.md`.
