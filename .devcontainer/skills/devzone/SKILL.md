---
name: devzone
description: Use to work in a devzone container — modules and catalog, devzone agent, worktrees, guard.
---

<!-- devzone : skill set by devzone enable ai -->

# devzone skill (AI assistants)

This skill is for Claude Code (lead) and opencode (developer) in a devzone container. It is set by `devzone enable ai` in `~/.claude/skills/devzone/` and `~/.config/opencode/skills/devzone/` (volumes, kept across rebuilds). To customize it without it being replaced, remove the marker line above.

## Golden rule

Everything is done in the container, with the `devzone` commands, never by running the scripts of `.devcontainer/` by hand.

In bats tests, only use fake tools in a temporary `bin` folder: never a real system script (`devzone`, `kubectl`, `helm`…) under bats.

## Worktrees

Projects live in `workspace/`; ticket worktrees under `workspace/wt/`. A worktree is created and removed **in the container** (`git worktree add` / `git worktree remove`). Never `git worktree prune` from the host, nor a host tool (VS Code, GitHub Desktop). A worktree created on the workstation has an absolute path that the container cannot see: manage it on the side that created it.

## Modules and catalog

Modules are disabled by default, enabled on demand, without a rebuild:

- `devzone enable ai`: Claude Code and opencode (pinned versions), repowarden guard, default opencode configuration. Then log in: `claude` (then `/login`), `opencode auth login`.
- `devzone disable ai`: uninstalls the assistants; removes the guard and the default opencode configuration; keeps the state of `devzone agent`, the logs `workspace/.agents/` and the logins.
- `devzone enable kubernetes`: connects to the machine's cluster at each startup and installs metrics-server on local clusters.
- `devzone enable gitlab`: installs a test GitLab in the services cluster (namespace `devzone-gitlab*`).
- `devzone enable postgres`: shared PostgreSQL, one database per project (`devzone postgres create <project>`).
- `devzone enable mysql`: shared MySQL of the catalog, one database per project.
- `devzone enable argocd`: Argo CD of the services cluster, interface in the container at https://127.0.0.1:8443.
- `devzone disable <module>`: disables and applies at once.
- `devzone apply`: installs what is active.
- `devzone repair`: relaunches gitlab, postgres, mysql, argocd, labelled ports and the catalog watcher.
- `devzone status --json`: full summary in JSON, for tools (no secret; the `command` field of each item gives the command to run).

The application catalog is consulted with `devzone catalog`; a watcher applies the changes of `.devzone.modules` on the fly, and `devzone repair` relaunches it. MySQL is driven with `devzone mysql create <project>`, `devzone mysql list`, `devzone mysql delete <project>`, `devzone mysql volume [<name>|--delete <name>]` and `devzone mysql delete-data` (data kept by default).

The choice is specific to each devzone, kept in `.devzone.modules` of the devzone folder.

## Directing opencode (devzone agent)

`devzone agent <folder> <instruction-file>` directs opencode on an instruction, in the foreground or in parallel (`&`, one per ticket and per worktree).
- `devzone agent state`: sessions, discarded models and their cause.
- `devzone agent release <model>|--all`: lifts a model discard.

The log is `workspace/.agents/<folder>.log`. `--auto` avoids waiting for a permission; `< /dev/null` avoids a silent session.

## Guard and protected files

With `ai` active, the repowarden guard is plugged in for Claude Code and opencode: the agent is stopped before modifying `main`/`develop`, committing without `repowarden cc` or bypassing the hooks. `repowarden cc -m "…"` to commit.

Protected rights files (never written by an agent, fixed list, no variable changes it): `.devcontainer/opencode/agent.json`, `.devcontainer/opencode.jsonc`, `.repowarden.conf`, `.devcontainer/agent-rights.sh`. An agent that touches them is refused and the change is reverted in the tree.

## Kubernetes only

devzone is described with **the cluster**, **the pod** and **the nodes**; never "Docker" to describe devzone. Only **pods** are containers.

For a disposable test, create a disposable **pod** or **namespace** (`kubectl run`, `kubectl create ns`), then delete it. Do not run `docker`.

A guard stops agents that run `docker` or `docker-compose`; `DEVZONE_ALLOW_DOCKER=1` is reserved for an action on the **host** itself, never on the cluster.

## Kubernetes services and workspace

The services (PostgreSQL, MySQL, GitLab, Argo CD) live on the **devzone services cluster**, chosen once (`devzone cluster CTX`) and kept in the state. The kubectl `devzone` context is set on this cluster. Services namespaces: `devzone-*`. `devzone cluster` shows the cluster and the possible ones, `devzone clusters` gives the work/services view; the active `kubernetes` module connects to the machine's cluster and installs metrics-server at startup.

The development workstation can run in the cluster: `devzone workspace start|stop|status|shell|vscode|copy-to <folder>|copy-from <folder>` drives the Kubernetes workspace (run from the workstation).

## What falls to the maintainer

The developer (opencode) codes, tests and commits with `repowarden cc`; the lead (Claude Code) reviews, pushes, does the real test, follows CI and can move a PR to ready when all its jobs are green. Logins (GitHub, Claude Code, opencode), ticket validation, deployment approvals and release launches remain with the maintainer. The “repowarden” skill is already placed by `repowarden agents init`: just check that it is present.
