# Project rule: Kubernetes only

devzone is described with the cluster, the pod and the nodes; never as "Docker".
Only pods are containers. For a disposable test: `kubectl run` or
`kubectl create ns`, then deletion. The guard stops agents that run
`docker`; `DEVZONE_ALLOW_DOCKER=1` is reserved for an action on the
host itself. Details: `.devcontainer/skills/devzone/SKILL.md`.
