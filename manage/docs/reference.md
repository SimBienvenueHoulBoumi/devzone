# Detailed reference

## Connections and identity

**GitHub (optional)**: used to push and open PRs on GitHub, for tickets and repowarden bots, and it provides the git identity automatically. Without GitHub, git works normally (local repositories, other hosts); only the identity is set by hand. To use it: `gh auth login -s workflow`. Git then goes through the `gh` token (https, even for `git@github.com:` remotes), with no ssh key to copy. The repositories under `/workspaces/devzone` are declared safe (`safe.directory`).
- **`workflow` permission**: without it, GitHub refuses any push that modifies `.github/workflows/` (common with repowarden). Account already logged in: `gh auth refresh -h github.com -s workflow`.
- **From `make shell`**, no browser opens from the container: copy the code shown by `gh` and open https://github.com/login/device by hand. The warning “No clipboard utilities available” is harmless.

**Git identity** (required to commit): without GitHub, set by hand (`git config --file ~/.config/git/config user.name "<name>"` and `user.email "<email>"`); with GitHub, deduced from the `gh` account at each startup as long as it is missing (`git-identity.sh`):
- name of the GitHub profile (otherwise the login);
- noreply email `<id>+<login>@users.noreply.github.com`: commits are attached to the account, the personal email is not exposed.

An identity already set is never replaced. For another email: `git config --file ~/.config/git/config user.email "<email>"`. After a `gh auth login` during a session: `devzone start`.

**AI assistants** (`ia` module, see [Modules](#modules)): `devzone enable ia`, then `claude` (then `/login`), `opencode auth login`.

Logins (**GitHub**, **git**, **Claude Code**, **opencode**) and caches (**Maven**, **Gradle**, **pnpm**) are **deliberately shared** between the devzone instances of a machine: they live in the Docker volumes (see [Data kept](#data-kept)). The repository contains no credentials.



## Platform: GitHub or GitLab

devzone is designed for GitHub; `devzone platform` chooses the platform the CLI connects to (`github` by default, current behavior, nothing changes):

```bash
devzone platform                  # shows the platform and its state
devzone platform github           # back to GitHub: glab and its configuration removed
devzone platform gitlab --url https://gitlab.example.com:3443
devzone platform gitlab           # without --url: the instance of the gitlab module (http://gitlab.localhost:8929)
```

- **Choice per instance**: kept across rebuilds in the state file (`$RACINE/.devzone.modules`, lines `platform=` and `gitlab_url=`), like the [modules](#modules).
- **glab** (GitLab CLI), installed **only** when GitLab is chosen: binary from the official gitlab.org release (chart of gitlab-org/cli), pinned version and verified SHA-256 checksum, in `~/.local/bin`; when going back to `github`, the binary and its configuration (`~/.config/glab-cli/`) are removed: the configuration of a service exists only while it is chosen.
- **Connection**: instance of the `gitlab` module → automatic, with the module's root token (`workspace/.gitlab/`, http protocol, never displayed); other instance (gitlab.com or self-hosted) → `glab auth login --hostname <host>`, interactive (login code to enter).
- **State**: the `platform` line shows the instance and “glab connected”, or “not connected” with the command to run. With `gitlab`, the GitHub-only lines report that they do not apply: repowarden (bots, tickets, workflows of the devzone repository) stays on GitHub only until it supports GitLab ([simdevWarden/repowarden#531](https://github.com/simdevWarden/repowarden/issues/531)). A connected `gh` remains useful for these tickets.
- **Test instance**: the [gitlab module](#gitlab) provides the container's local instance (user `root`, secrets in `workspace/.gitlab/`); as soon as it is active, `devzone platform gitlab` (without `--url`) targets it by default.
- **Updating glab**: in `.devcontainer/devzone`, `GLAB_VERSION` and the two checksums `GLAB_SOMME_ARM64` / `GLAB_SOMME_AMD64` (checksums.txt of the release), then `devzone platform gitlab --url URL` (glab is downloaded again only if it is missing or broken: remove it first, `rm ~/.local/bin/glab`).



## Starting a project

Your projects go into `workspace/` (`/workspaces/devzone/workspace` in the container), each with its own git repository. The repowarden hooks are active there by default.

**Existing project, already equipped with repowarden** (`.repowarden.conf` and workflows present): just clone it.

```bash
cd /workspaces/devzone/workspace
git clone https://github.com/<account>/<project>.git
cd <project>
repowarden            # state of the workstation and the repository, next step
```

**New project, or project without repowarden**:

```bash
cd /workspaces/devzone/workspace
mkdir <project> && cd <project> && git init -b main     # or git clone of an existing repository
# … first files, then a first commit: git add . && git cc
gh repo create <account>/<project> --private --source . --push   # GitHub repository (if absent)
repowarden bots       # CI, releases, tickets, GitHub App, protection: each with your agreement
repowarden            # check
```

`repowarden bots` asks for the flow (`main` only, or `develop` → `main`), shows what it is going to create, then waits for your confirmation; an existing file is never overwritten. It requires `gh` to be connected and administrator rights on the GitHub repository.

### Git worktrees

**Rule**: a workspace repository is handled from one side only. Worktrees are created **and** removed in the container (`git worktree add`, `git worktree remove`); never run `git worktree prune` on the host machine, nor let a host tool do it (VS Code, GitHub Desktop…).

**Why**: the workspace is mounted from the host (`/Users/…/devzone` on a Mac → `/workspaces/devzone`). git records the **absolute** path of each worktree in `.git/worktrees/<name>/gitdir`: `/workspaces/…` for a worktree created in the container, `/Users/…` for a worktree created on the Mac. Seen from the other side, this path does not exist: the worktree looks “prunable”, and a `git worktree prune` erases its metadata, which breaks the worktree where it was created.

**Reporting**: the state shown at startup (and by `devzone`) lists, without deleting anything, the worktrees of the devzone repository and of the workspace repositories whose path does not exist in the container: `⚠ worktree        /Users/…/wt-42 absent ici (créé hors du conteneur ?) : …`. Manage it from the side that created it (remove it there with `git worktree remove`, then recreate it in the container if needed).



## Modules

Optional features are modules, **disabled by default**, enabled on demand from the container, without a rebuild:

```bash
devzone                        # state: git identity, GitHub, tools, modules
devzone enable <module>       # enables and applies at once
devzone disable <module>    # disables and applies at once
```

| Module | Enabled | Disabled |
|---|---|---|
| `ia` | Claude Code and opencode installed (pinned versions), reinstalled at each rebuild, with the [repowarden guard](#ai-assistants-guard), a [default opencode configuration](#opencode-configuration) and the [devzone skill](#devzone-skill) placed in `~/.claude/skills/devzone/` and `~/.config/opencode/skills/devzone/`; to log in: `claude` (then `/login`), `opencode auth login` | uninstalled; the guard (hook and plugin), the default opencode configuration and the unmodified devzone skill are removed; the state of `devzone agent` (shared volume), the logs in `workspace/.agents/` and the logins remain | Python 3.12 on Ubuntu 24.04, installed by apt (no more devcontainer feature, no key server, #464) |
| `kubernetes` | at each startup: connection to your machine's cluster and metrics-server on local clusters (CPU and RAM in k9s) | no connection to your machine's cluster; kubectl, helm, k9s and kind remain installed, a kind cluster created by hand remains usable; metrics-server is removed from the clusters where devzone installed it |
| `gitlab` | test GitLab CE in the [services cluster](#devzone-cluster), namespace `devzone-gitlab` (pinned chart), Kubernetes runner, project `devzone/demo` with a pipeline; http://gitlab.localhost:8929; at least 8 GB of allocatable RAM (see [GitLab](#gitlab)) | Helm releases and namespace `devzone-gitlab` removed, Rails secret kept (`workspace/.gitlab/rails-secret.yaml`); nothing else touched |
| `postgres` | shared PostgreSQL 16 on the [devzone cluster](#devzone-cluster), one database per project (`devzone postgres create <project>`), reachable on `127.0.0.1:5432` in the container (see [PostgreSQL](#postgresql)) | namespace `devzone-postgres` (all databases) and `workspace/.postgres/` secrets deleted, after confirmation in a terminal; dedicated kind cluster deleted if it is no longer used |
| `argocd` | Argo CD on the [devzone cluster](#devzone-cluster), namespace `devzone-argocd` (pinned chart), server in `ClusterIP`; https://127.0.0.1:8443 in the container; at least 1 GB of allocatable RAM (see [Argo CD](#argo-cd)) | Helm release and namespace `devzone-argocd` removed, secret `workspace/.argocd/` deleted; the other services remain, under direct helm |

The `llm` module is removed (#669): `devzone apply` removes the `llm=` line from `.devzone.modules`; the `devzone-llm` namespace and its volume are not deleted automatically (`kubectl delete namespace devzone-llm` to free the disk).

### Minimum memory per module

Measurements from 16/11/2026.

| Module | Measured consumption | Allocatable memory required by devzone |
|---|---|---|
| Base cluster | ~4 GB | none |
| GitLab | ~3.6 GB | 8 GB |
| MySQL | ~0.5 GB | none |
| Argo CD | ~0.6 GB | 1 GB |

On Docker Desktop (kind), the check compares the minimum with the memory of a single node, so with the VM; on a cluster of real machines, with the sum of the nodes.

### Adjusting the RAM

- **Mac** (Docker Desktop): *Settings → Resources > Memory*. Other method: change `MemoryMiB` in the `settings-store.json` file of Docker Desktop (Docker must be fully quit, otherwise it rewrites the value).
- **Windows**: file `%UserProfile%\.wslconfig` with `[wsl2]` and `memory=<N>GB`, then `wsl --shutdown`. WSL2 takes 50 % of the RAM by default.
- **Linux**: nothing to adjust: there is no VM, the host's RAM is used.

The choice is **specific to each devzone** (instance) and kept in the folder `$RACINE/.devzone.modules` (mounted from the host, it survives rebuilds). At the first startup of an instance, if a Claude Code or opencode login already exists in the volumes, the `ia` module is not enabled: everything is disabled by default and the login is reported only once (“devzone enable ia to use it here”), not for a resumed state.

In the [Kubernetes workspace](#devzone-services-in-the-kubernetes-workspace), `gitlab`, `postgres` and `argocd` are installed from the workstation (`devzone workspace services enable <service>`); the pod only shows their presence in the cluster.

### Application commands

The internal scripts of `.devcontainer/` are not user commands: `devzone` wraps them.

```bash
devzone repair                 # relaunches gitlab, postgres, ports and credentials
devzone start                # full startup (git identity, clusters, relays, summary)
devzone metrics [context…]     # installs metrics-server on a local cluster
devzone use CTX [--confirm CTX]  # switches the kubectl working cluster
devzone clusters                       # view of the connected clusters (work and services)
```

`repair` shows `✔` or `✖` per item and returns code 1 as soon as an item fails. `use` never modifies the [services cluster](#devzone-cluster) (no `cluster=` line): a remote cluster requires `--confirm CTX` outside a terminal.

### AI assistants guard

With the `ia` module active, devzone plugs the [repowarden guard](https://github.com/simdevWarden/repowarden/blob/main/docs/agents.md) into Claude Code and opencode (`repowarden agents init --global`, at activation and at each startup; rerunning it changes nothing). In **any repository** of the container, the agent is stopped **before** its action, with the repowarden command to run instead, when it wants to modify `main` or `develop`, commit without `repowarden cc`, or bypass the hooks (`--no-verify`).

- **Where**: `~/.claude/settings.json` (`PreToolUse` hook) and `~/.config/opencode/plugins/repowarden-garde.js`, in the volumes: kept across rebuilds. An existing setting is completed, never overwritten.
- **Seeing it at work**: in a repository on `main`, ask the assistant to modify a file: it is refused (message `branche protégée`, *protected branch*) with the command to run.
- **Limits**: a safety net, not a wall. A change made by the shell (`sed -i`, `>` redirection, script) is only seen at commit time, by the hooks; a command hidden in `bash -c "…"` is not seen. Without `repowarden` or `jq`, nothing is blocked. `devzone disable ia` removes the guard (hook and plugin) and the default opencode configuration; the state of `devzone agent`, the logs in `workspace/.agents/` and the logins remain.

### Docker guard and Kubernetes rule

devzone is **Kubernetes first**: the vocabulary is **the cluster**, **the pod**, **the nodes**; only pods are containers. A disposable test is done in a disposable pod or namespace (`kubectl run`, `kubectl create ns`, then deletion). A guard stops agents that run `docker` or `docker-compose` as a command word (start of line, after `;`, `&&`, `||`, `|`, `$(`, a backtick, `(`, `sudo` or an assignment `VAR=value`), with a message pointing to kubectl; a simple mention (`grep docker file`, `git commit -m "docker"`) passes.

- **Two levels**: in the repository, versioned project files cover any agent working there, wherever it runs and whether `ia` is active or not: `.claude/settings.json` (`Bash` `PreToolUse` hook) and `.opencode/plugins/devzone-guard.js` (opencode 1.x) / `devzone-guard-v2.js` (opencode 2.x), simple re-exports of the embedded plugin `.devcontainer/ai/plugins/` (present in the clone and in the image). For folders other than this repository, `devzone enable ia` places the same entries in `~/.claude/settings.json` (via `jq`, without duplicates) and copies the two plugins into `~/.config/opencode/plugins/`; `devzone disable ia` removes only these entries (commands containing `docker-guard.sh`) and these plugins, the rest of `settings.json` and of the plugins stays intact.
- **Script path**: the embedded plugin (`.devcontainer/ai/plugins/`) resolves `../docker-guard.sh` from its own location; the global copy receives, at installation, the installed path (next to the `devzone` script), and the `DEVZONE_DOCKER_GUARD` variable replaces it if needed.
- **Bypass**: the agent's `DEVZONE_ALLOW_DOCKER` environment variable, set to 1, lets it through; reserved for an action on the **host** itself, never on the cluster.
- **Limit**: a safety net, not a wall. A `docker` command hidden in a script is not seen; without `python3` or `jq`, nothing is blocked.

### opencode configuration

With the `ia` module, devzone writes a ready-to-use opencode configuration in `~/.config/opencode/opencode.jsonc` (volume `devzone-opencode-config`): free models per role (`build`, `plan`, `general`, `explore`, title, summary, compaction), sharing and updates disabled. It is updated at each `devzone enable ia` and at each startup, as long as its marker first line `// devzone : default opencode configuration …` is present.

- **Default permissions**: what serves the work is allowed without asking (`edit`, `git`, `repowarden`, `gh` in read mode, reading and searching, project files, tests, linters and build); the rest requires your agreement (`ask`, including `webfetch`); possible secret leaks are forbidden (`deny`): `gh auth token`, `gh auth status --show-token`, `~/.config/gh/hosts.yml`, `*.credentials*`, `auth.json`, `~/.ssh/*`, the environment (`env`, `printenv`, `set`, `export -p`), `curl`/`wget`, `nc`, `ssh`, `scp`, `sudo`, `rm -rf /` and force pushes. The last matching pattern wins: the `deny` entries are at the end of the list.
- **Why `curl`/`wget` are forbidden**: a request can send data (token, file) outward. The network goes through `webfetch`, which remains available with your agreement.
- **Customizing it**: remove this marker line. devzone then keeps it as is and reports `configuration personnalisée, gardée`; to widen it, add an `allow` entry (for example one more command).
- **Changing the model**: edit `model` (default model), `small_model` (title) and the relevant `agent` entries; `opencode models` lists the available models.
- **Paid provider**: `opencode auth login` (the login stays in the volume `devzone-opencode-data`).
- **Host models (Ollama)**: devzone hosts no model; they live on the host (Ollama, `http://host.docker.internal:11434` by default, overridable via `DEVZONE_OLLAMA_URL`). Detection on demand via `/api/tags` (short timeout, embedding models are ignored, clean output and no write if Ollama does not answer). At `devzone enable ia` (and at `devzone apply`), the `devzone-host` provider (type `@ai-sdk/openai-compatible`, `baseURL = URL + /v1`) is merged into `~/.config/opencode/config.json` with the list of detected models (no name hard-coded), without overwriting the rest of the file; it is removed by `devzone disable ia`. `devzone enable ia` then reports the detection status (`devzone : N modèle(s) de l hôte (Ollama) branché(s)` or `devzone : aucun modèle Ollama détecté sur <URL> (modèles de l hôte non branchés)`), with exit code 0 in both cases. `devzone ai` lists the detected models and the default model (read-only). In the rotation of `devzone agent`, the host model is tried first. The internal name of the local model never contains “/” (characters outside `[A-Za-z0-9._-]` become “_”); the reference passed to opencode stays `devzone-host/<real-name>`.
- **Update check and report**: `devzone ai check` queries, for each detected model, the manifest of the registry (`DEVZONE_OLLAMA_REGISTRY`, otherwise `https://registry.ollama.ai`; a single GET, 5 s timeout, nothing downloaded) and compares its fingerprint with the local digest of `/api/tags`: `à jour` (*up to date*), `mise à jour disponible` (*update available*; the line `ollama pull <model>` to run on the host is shown, never executed) or `non vérifiable` (*not verifiable*: name with a slash such as `hf.co/…`, 404, registry unreachable). `devzone ai rapport` also shows the size, the measurements and the selected model with its reason (variable, measurement or rule). The default model is chosen by priority: `DEVZONE_HOST_MODEL`, otherwise the best measured model (file `DEVZONE_AI_MEASURES`, otherwise `~/.config/devzone/ia-mesures.json`, `{"<model>": {"reussite": 0..1, "tok_s": n, "date": "…"}}`, sorted by success then speed, among the detected models), otherwise the rule “name containing `coder` first, then smallest size, then name order”.
- **Running opencode in the background**: `opencode run --auto "…" < /dev/null`. Without `--auto`, any permission request is refused outright and the agent stops; without `< /dev/null`, it waits for its input and stays silent.

### devzone skill

With the `ia` module, devzone places the devzone skill (`.devcontainer/skills/devzone/SKILL.md`) in `~/.claude/skills/devzone/` and `~/.config/opencode/skills/devzone/` (volumes, kept across rebuilds). It recalls that everything is done in the container with the `devzone` commands (never the scripts), worktrees under `workspace/wt/`, modules, `devzone agent` (rotation, `etat`, `liberer`), the guard and the protected rights files, Kubernetes services (context `devzone`, `devzone-*` namespaces) and what falls to the maintainer (logins, Ready, merges).

- **Installation**: if absent, the skill is written from the template; if it carries the marker `<!-- devzone : skill set by devzone enable ia -->` and has not been modified, it is updated; if customized, it is kept.
- **Disabling**: `devzone disable ia` removes only the unmodified skill; a customized skill is kept.

The “repowarden” skill is already placed by `repowarden agents init`: just check that it is present.

### Directing opencode

Claude Code is the **lead** (design, instructions, review, tests, push, CI tracking); opencode is the **developer** (code, tests, `repowarden cc` commit). Several opencode sessions run in parallel, one per ticket and per worktree.

```bash
devzone agent [--model <m>[,<m2>…]] <folder> <instruction-file>  # requested models first (#420)
devzone agent <folder> <instruction-file>    # in the foreground
devzone agent <folder> <instruction-file> &  # several in parallel (or nohup)
devzone agent state                           # sessions, discarded models and their cause
devzone agent release <model>|--all         # lifts a model discard
devzone agent --pod <folder> <instruction>     # agent session in a disposable isolated pod (#222)
```

- **Launch**: `opencode run --auto -m opencode/<model> "<instruction>" < /dev/null` in the folder. The log is `workspace/.agents/<folder name>.log` (devzone state, outside the repository, ignored by git). `--auto` avoids waiting for a permission; `< /dev/null` avoids a silent session.
- **Free model rotation**: `opencode models opencode` provides the list (`*-free`, `big-pickle`), with a fixed fallback list. A shared, locked rank makes each launch start on the next model: two simultaneous sessions start on two different models.
- **Switching** according to the cause of the failure. The message is only searched in the last 30 lines of the attempt, and only if the exit code is non-zero or if opencode wrote its error line: displayed code containing “Free usage limit” that ends normally is not a failure.
  - **country** (`not available in your country`): model discarded for 7 days;
  - **quota** (`Free usage limit`), **filter** (`content filter`) and **silent** (nothing written in 45 s at start): model discarded for 1 h;
  - **network** (`ENOTFOUND`, `ECONNREFUSED`, `ETIMEDOUT`…): kept only if the network is down at the time of the error, otherwise treated as **other**. No discard. devzone waits for the network to come back (retry every 30 s, 30 min at most, log `=== network down, waiting`), then relaunches the same model, 3 times at most per model; then the next model. Without a return: stop, log `=== network unavailable`, code 4;
  - **other** (`Model is unavailable`, `Upstream request failed`…): next model, without discard.
- **Discards**: `devzone agent state` shows the cause and end time of each discard; `devzone agent release <model>` (or `--all`) lifts it.
- **Requested model** (`--model`, #420): ordered list of free model names (without the `opencode/` prefix), separated by commas. They are tried in this order, except the discarded ones; then the usual rotation resumes from the shared rank, without retrying a model already tried. An unknown name is refused before any launch (code 2) with the list of free models. A requested model that starts does not advance the shared rank. The log writes `=== requested model chosen: <m>` at startup and `=== requested model <m> excluded (<cause>), next` for a requested model that is discarded. `devzone agent state` (and `--json`, field `requested`) shows the requested model and the model used. Not handled with `--pod`. Journals written before this rename show `=== --modele :`; that header is no longer read, so `requested` is empty for them.
- A frozen session (nothing written for 10 min) is stopped and resumed in a new session, next model, with a resume instruction (`git status`, `git diff`, `git log`). All models discarded: `no free model available`, code 3.
- **Permissions**: `.devcontainer/opencode/agent.json` is the default configuration, merged with `OPENCODE_CONFIG_CONTENT` if it is defined. opencode applies the last matching rule: devzone's `deny` entries are re-added last after the merge, so the caller can add permissions but never remove a devzone prohibition. `webfetch` is allowed; `git push`, `git checkout/reset/restore/stash/clean`, `git branch -D`, GitHub writes, `gh api`, `curl`, `sudo`, `rm -rf` (except `./.essai`) and ticket/PR management by repowarden (`repowarden ticket …`, `repowarden proteger`, `repowarden run`) are forbidden; `git commit` remains allowed for `repowarden cc`. `~/bash32` is always protected (the bash 3.2 of the container).
- **Protected rights files**: during a session, `agent.json`, `.devcontainer/opencode.jsonc`, `.repowarden.conf` and `.devcontainer/agent-rights.sh` (fixed list, no variable changes it) are forbidden for writing by opencode (`permission.edit`, `deny` added last). As an agent can also write through the shell, `devzone agent` takes a snapshot of these files at launch and compares them after **each** session (normal end, error, silent, frozen): any change is reverted in the tree (never `reset` nor `rebase`), the log receives `=== ⚠ rights changed: <file>` (with the commit to remove before any push if the agent committed), and `devzone agent state` shows `⚠ rights changed (<project>)` until the next launch on this project. The exit code does not change. In addition, the repowarden guard (`agentsProtectedPaths` setting of `.repowarden.conf`, repowarden 4.17.1) refuses any agent, Claude Code as well as opencode, to write or commit these files, even before the end of the session; a human can always modify them.
- **Free model quota**: these models are limited; rotation and the one-hour discard avoid blocking a ticket when one is exhausted. For a paid provider: `opencode auth login`.



## Grouped credentials

The accounts created by devzone (`gitlab`, `postgres` and `argocd` modules) are grouped in `$RACINE/.password`, next to `.devzone.modules`.

```bash
devzone passwords          # regenerates the file and only shows its path
```

- **Format**: comment header, then one line per account, columns separated by tabs: `service`, `address`, `user`, `password`. Stable sort by service then user; no empty line.
- **Source**: the module files remain the reference (`workspace/.gitlab/root-password`, `workspace/.gitlab/dev-password`, `workspace/.postgres/admin-password`, `workspace/.postgres/<project>.env`, `workspace/.argocd/admin.env`). `.password` is a regenerated view, never a second copy to keep up to date.
- **Update**: `password_regenerate` (`.devcontainer/password.sh`) is called at the end of each creation, deletion or account change: installation, `create`, `delete` and `--new-password` of postgres; seed and uninstall of gitlab; installation and uninstall of argocd; devzone startup. A failure never prevents the operation; it shows a warning.
- **Protection**: file ignored by git (`.gitignore`) and rights **600** set before writing (`umask 077`, temporary file in the same folder, then `mv`). No command reads or displays its content; the summary and `devzone passwords` only cite the path. Without any account, the file is deleted.



## Several devzone instances on one machine

Several devzone instances can coexist on one machine (one per project, one per use): each instance is a folder of the workspace, with its own state and its own modules.

- **Modules**: **specific to each devzone**. The state lives in the instance's folder (`$RACINE/.devzone.modules`), mounted from the host: a second devzone starts with default values, without inheriting those of the first (an old global state, at the first devzone started after the update, is taken over once, by moving).
- **Platform** (GitHub or GitLab, [see above](#platform-github-or-gitlab)): also specific to each devzone, in the same state file, with the URL of its GitLab instance.
- **Logins** (**GitHub**, **git**, **Claude Code**, **opencode**) and **caches** (**Maven**, **Gradle**, **pnpm**): **deliberately shared** between the devzone instances of a machine, in the `devzone-*` volumes.
- **Full isolation**: a distinct volume prefix (as for the tests) gives each devzone its own volumes; see [For contributors](#for-contributors).



## Working on a project

- **repowarden hooks**: installed globally (`repowarden install --global --lang fr`), they apply to any repository cloned in the container (commit messages, secrets, formatting, tests). Then follow the project's rules (`AGENTS.md`, `CONTRIBUTING.md`): `repowarden ticket <n>`, `repowarden cc …`.
- **GitHub App** (proposed by `repowarden bots`, or `repowarden app init`): without it, the workflows act under the `github-actions` bot, whose actions trigger no other workflow (draft PR without CI, automatic merge without preview…); see [Troubleshooting](#troubleshooting).
- **repowarden CI checks** locally: `shellcheck`, `actionlint`, `bats test/`. actionlint is at the same version as the CI; shellcheck and bats are those of Ubuntu 24.04 and may differ slightly.



## Kubernetes

devzone provides the tools, not the cluster, and never creates one on its own. With the `kubernetes` module active (`devzone enable kubernetes`), it connects at each startup to the host's cluster if it exists and answers (in practice `docker-desktop`); otherwise, or in addition, create a cluster in the container:

```bash
kind create cluster          # ~2 min the first time
kubectl config get-contexts  # host clusters + kind clusters
devzone use <name>       # switches the kubectl working cluster
```

- **Active cluster**: the host's by default if it answers (in practice `docker-desktop`), otherwise a dedicated kind cluster `kind-devzone`. A choice made with `devzone use` is kept across restarts.
- **kind clusters**: run on the host's Docker (shared socket, #291). Their API listens on 127.0.0.1 **of the workstation**, never on the local network; `kind` (devzone wrapper) rewrites the address to `host.docker.internal` in the container's kubeconfig, keeping TLS verification: a cluster created by hand with `kind create cluster` is reachable straight away. The name is suffixed by instance when it is not the default instance. They restart with Docker Desktop, are kept by `make rebuild` and `make down`, and are deleted by `kind delete cluster` (or `make uninstall`).
- **CPU and RAM in k9s** (`kubectl top`): with the `kubernetes` module active, metrics-server is installed at startup on the **local** clusters that lack it (Docker Desktop, kind…), never on a remote cluster. After a `kind create cluster`: `devzone metrics` (or `devzone metrics <context>` for a specific cluster).
- **Host cluster**: `~/.kube` is mounted read-only, never modified; its adapted copy is `~/.kube/hote.config` (`127.0.0.1` replaced by `host.docker.internal`). After a cluster change on the host: `make stop && make up`.
- **Startup messages** (`kube-config : …`, `metrics-server : …`, summary): in the creation terminal, or by rerunning `devzone start`.

The `127.0.0.1` address of the host cluster is rewritten to `host.docker.internal` by `kube-config.sh` at startup, making the cluster reachable from the container. The API certificate includes `host.docker.internal` in its SANs (configured via `networking.apiServerAddress` and `kubeadmConfigPatches` in the kind config).

The host cluster is not reachable in two cases (kind still works):
- **Codespaces, remote machine**: no local `~/.kube`;
- **Linux with Docker Engine**: a kind or minikube cluster of the host listens on `127.0.0.1`, invisible from the container without the `kube-config.sh` rewrite. A cluster listening on all interfaces (k3s, kubeadm) is reachable.

## Kubernetes workspace

The development workstation can run in the cluster, with Kubernetes 1.30 or newer as the minimum prerequisite (native sidecars, and the BuildKit AppArmor profile). The chart `charts/devzone-workspace/` deploys a StatefulSet, with no privileged container nor node Docker:

- container `workspace` (image ghcr.io/simbienvenuehoulboumi/devzone-workspace:<version>), with `DOCKER_HOST=tcp://127.0.0.1:2475`, `BUILDKIT_HOST=tcp://127.0.0.1:1234`, `TESTCONTAINERS_RYUK_DISABLED=true` and `TESTCONTAINERS_CHECKS_DISABLE=true`;
- native sidecar `kubedock` (joyrex2001/kubedock:0.23.0, unprivileged), starts before `workspace`: a Docker API whose containers become pods of the namespace;
- native sidecar `buildkitd` (moby/buildkit:v0.34.2-rootless, UID 1000, unprivileged), starts before `workspace`: builds the images;
- two PVCs: `workspace` (the projects, mounted on `/workspaces/projets`) and `etat` (state);
- a ServiceAccount `devzone-workspace` with a Role limited to the namespace and a NetworkPolicy within the same namespace.

From the workstation:

```bash
devzone workspace start                # installs or updates the workspace
devzone workspace update [--version X.Y.Z] [--yes]  # moves to the latest stable release (pod recreated, #622)
devzone workspace start --image repo:tag   # image built by hand
devzone workspace stop                 # uninstalls the workspace
devzone workspace status                    # state of the pods
devzone workspace shell                   # shell in the workspace container
devzone workspace vscode                  # procedure: attach VS Code to the pod
devzone workspace copy-to <folder>   # copies a workstation folder to the pod's projects
devzone workspace copy-from <folder> # copies a pod project to the workstation
devzone workspace ports [start|stop|status] # applications and services from pod on workstation localhost
devzone workspace services enable <service> [options]  # installs gitlab, postgres or argocd in the cluster
devzone workspace services disable <service> [--yes]   # removes them
devzone workspace services status          # present or not, per namespace
devzone workspace argocd status            # Argo CD and its Applications (#516)
devzone workspace argocd app add <repo> [path] | app list | app remove <N>  # projects deployed by Argo CD
devzone workspace egress observation|strict|off  # egress proxy of --pod sessions (#633)
devzone workspace egress status                  # mode, ready or not, domains contacted
devzone workspace egress allow|deny <domain>    # adds or removes a domain from the strict list
```

The commands use the workstation's helm and kubectl, with the devzone context if it exists, otherwise the current context. The image is built by CI at each PR and published to ghcr.io at delivery.

The image comes from ghcr.io, tagged with the devzone version (`latest` from a clone of the repository); if missing, start reports it and uninstalls the workspace.

### Updating the workspace

`devzone workspace update` moves the workspace to the latest stable release of the devzone repository (tags `vX.Y.Z`; pre-releases such as `v0.48.0-next.1` are ignored), or to the version given with `--version X.Y.Z`. It sets the image, the charts and the `devzone-workspace` Argo CD Application to the same tag (without Argo CD, the local chart is redeployed with the new image), then reconciles the services managed by Argo CD (postgres, mysql).

When to use it: after a new devzone release, or when the pod runs an old image. Projects (`workspace` volume) and state are kept.

Order of operations:

1. the target version is read from the repository tags (`git ls-remote`, without gh or Docker); no release found, or repository unreachable: message, non-zero exit code, nothing changed;
2. the image `ghcr.io/simbienvenuehoulboumi/devzone-workspace:<version>` is checked before any write (anonymous registry token, then the manifest). Missing or registry unreachable: message, nothing changed. The release may have just been published: try again later. The token is never displayed;
3. if the Application is already at this version, the command shows `already up to date` and exits with 0, without writing anything;
4. otherwise it warns and asks for confirmation `[y/N]`. Without a terminal, `--yes` is mandatory, otherwise the command is refused.

**Warning: the pod `devzone-workspace-0` is recreated.** VS Code windows attached to the pod disconnect, and the processes launched in the pod stop. If the pod's ports no longer respond after the update, `devzone workspace ports start` restarts them.

```bash
devzone workspace update                  # latest stable release, with confirmation
devzone workspace update --yes            # without a question (mandatory without a terminal)
devzone workspace update --version 0.48.0 # a specific version
devzone workspace status                  # follow the deployment; the last line shows the version reached
```

### Projects in a volume

- **Mount**: the `workspace` PVC is mounted on `/workspaces/projets`, where the container starts (`workingDir`). Its size is set with `workspace.size` (20 Gi by default).
- **Retention**: the PVC carries the annotation `helm.sh/resource-policy: keep` and is never deleted by `helm uninstall`: `devzone workspace stop` removes the pod, not the projects. Losing them requires a manual deletion in the cluster.
- **Copies**: `devzone workspace copy-to <folder>` copies the workstation folder to `/workspaces/projets/<folder name>`; `devzone workspace copy-from <folder>` brings `/workspaces/projets/<folder name>` back into that workstation folder. Both go through `kubectl cp` (tar is present in the image).

### Direct creation in the cluster

`devzone <folder>` chooses the workstation mode from the cluster (#497):

- **Kubernetes** if `kubectl` and `helm` are present and the cluster answers (the `devzone` context if declared, otherwise the current context, within 5 s). The folder is created with `workspace=kubernetes` in `.devzone.modules`, then the workspace is installed in the cluster from the folder (like `devzone workspace start`).
- **Nothing** otherwise (#671): no more silent fallback to Docker. The command fails with exit code 1, creates nothing, says why the cluster does not answer, and shows, without running them, the ways to get one: a remote cluster (`aws eks update-kubeconfig`, `gcloud container clusters get-credentials`, `az aks get-credentials`, which declare it in your kubeconfig; it must be made the current kubectl context), Docker Desktop with Kubernetes enabled, or `minikube start -p devzone`. No cloud credential passes through devzone. **In a terminal** (#653), without options, the command offers a menu instead of the failure: 1) a **remote cluster**, a context of your kubeconfig (local clusters such as `docker-desktop`, `kind-*`, `minikube` or a `127.0.0.1` server are never offered as remote); you must **retype its name** to confirm, after a reminder of what will be installed (a pod, a volume, the `devzone-workspace` namespace, rights, a possible cost); devzone then makes it the current kubectl context; 2) a local **minikube** cluster: if minikube is absent, devzone shows the official installation command for the platform and never runs it; if present, it asks for confirmation, then runs `minikube start -p devzone` (`devzone` profile, driver chosen by minikube). The choice is kept only if the cluster then answers; otherwise the command fails as it does without a terminal. With `--kubernetes`, no menu. Still to do in #653: real tests (a remote context provided by its owner, a minikube created on a machine), choice of the minikube driver per platform, memory sizing.

Options: `--kubernetes` requires the cluster and fails without creating anything (the check happens before the files are copied). Without an option, the cluster must answer. The former `--docker` option (Docker workstation) is removed (#735): it is refused as an unknown option.

In this mode, Docker is not required on the workstation. The gh and opencode logins are done in the pod, at the first `make shell`.

A workspace already installed in the cluster (helm release `devzone-workspace`, or Argo CD Application of the same name) is announced at creation: the new folder drives it too, and `devzone workspace start` updates it by `helm upgrade`, without loss (volumes remain).

### The cluster does not answer

`devzone workspace start` (so `make up` and `make shell`) checks the cluster first, before Argo CD, helm and waiting for the pod (#565). An unreachable cluster gives a single message, exit code 1, and nothing else is launched; the workspace already installed is neither modified nor deleted. The message gives the cause:

- **Docker Desktop stopped**: `✖ Docker Desktop is stopped: the Kubernetes cluster of this machine runs inside it. Start Docker Desktop, then: make shell`. This is the case when the context is `docker-desktop` (or the cluster is named `docker-desktop` and answers on `127.0.0.1` or `localhost`) and `docker info` fails. The workstation's Kubernetes runs inside Docker Desktop: start it, then `make shell`.
- **Docker answers, not the cluster**: `✖ Kubernetes cluster <context> unreachable (<server>): enable Kubernetes in Docker Desktop (Settings → Kubernetes) or check kubectl config get-contexts`. Enable Kubernetes in Docker Desktop (Settings → Kubernetes), or check the context.
- **Other context**: `✖ Kubernetes cluster <context> unreachable (<server>)`, followed by `Check the contexts: kubectl config get-contexts`.

To have Docker Desktop start at each login: Settings → General → Start Docker Desktop when you sign in.

### Applications and services on the workstation's localhost

`devzone workspace start` starts a watcher on the workstation (`manage/scripts/workspace/ports-workspace.sh`), and `devzone workspace stop` stops it along with all its `kubectl port-forward` processes. `devzone workspace ports [start|stop|status]` drives it on its own.

- **Pod**: every 3 s, `kubectl exec` into the pod reads `ss -ltnH`. Each listening TCP port ≥ 1024 (except kubedock 2475 and BuildKit 1234) is relayed to `127.0.0.1:<same port>` of the workstation, never on the local network (`--address 127.0.0.1`). A server started in the pod (`npm run dev`) is therefore reachable at http://localhost:5173 without a command; a port that disappears has its relay stopped.
- **devzone services**: with the `postgres` module active in `.devzone.modules`, `svc/postgres` of the `devzone-postgres` namespace is relayed to `127.0.0.1:5432`, and pgAdmin (`svc/pgadmin`) if it exists, by the same mechanism. With the `mysql` module active, `svc/mysql` of the `devzone-mysql` namespace is relayed to `127.0.0.1:3306`. When Argo CD is installed (and `argocd` is not `off`), the https port of `svc/argocd-server` is relayed to `127.0.0.1:8443` (#516).
- **Cluster applications (#611)**: at each round, a single `kubectl get svc -A` lists the Services; each TCP port of a Service is relayed, except: headless Services (without a cluster IP), ExternalName, the `kubernetes` Service of the `default` namespace, the `kube-system`, `kube-public`, `kube-node-lease`, `local-path-storage` namespaces and those of the devzone modules (`devzone-system`, `devzone-workspace`, `devzone-postgres`, `devzone-mysql`, `devzone-argocd`, `devzone-gitlab`, `devzone-llm`), the Services annotated `devzone.io/relay: "false"`, and the ports of `ports_exclus=` in `.devzone.modules`. `devzone-app-demo` and the other application namespaces remain relayed. Local port: the Service's port if it is ≥ 1024 and free; otherwise the first free port starting from `port + 8000` (80 → 8080), incrementing (beyond 65000, starting from 20000). A port already relayed (devzone services, pod) or taken on the workstation is never assigned. The assignment is kept in `.devzone.workspace-ports/apps/<namespace>.<service>.<port>`: it stays the same as long as the Service exists, and disappears with it (and its relay too). When the Service comes back with the same name and port, it takes the same local port again if it is still free. Cap of 30 application relays: beyond that, a warning once per port, without relay. `devzone workspace ports status` shows one line per relayed application: `http://127.0.0.1:<local port>  <namespace>/<service>:<port>`.
- **Port already taken on the workstation** (`lsof`, otherwise `nc -z`): a single line `⚠ port <n> déjà pris sur le poste, non relayé` in `.devzone.workspace-ports/journal.log` and in `ports etat`, without retry loops.
- **Single watcher**: `mkdir` lock and pid in `.devzone.workspace-ports/` in the devzone folder; a second `start` answers "already running".
- **Safety guard**: the watcher never runs during automatic tests (fake kubectl and lsof).

### devzone services in the Kubernetes workspace

The `gitlab`, `postgres` and `argocd` modules live in the cluster, but the workspace pod has no kubeconfig and its service account is limited to its namespace (#430): it can neither install a service nor read its namespaces. Since #528:

- **State in the pod**: `devzone status` judges whether a service is present through the cluster DNS (`gitlab-webservice-default.devzone-gitlab.svc`, `postgres.devzone-postgres.svc`, `argocd-server.devzone-argocd.svc`), like the catalog does. Present → `✔ module postgres active: … (postgres.devzone-postgres.svc)`; absent → `⚠ module gitlab not in the cluster: on the workstation, devzone workspace services enable gitlab` (module active in `.devzone.modules`) or `○ module … optional` (inactive). No "failed" status coming from an installer: the failure mark is not read in the pod. `devzone status --json` carries the same values (`state`, `command`, `failed` set to `null`).
- **Pod startup**: `devzone apply` (run by `workspace-init.sh`) no longer installs these services; it writes them (`installed from the workstation`) and clears the failure marks of earlier startups. In the pod, `devzone enable gitlab` or `devzone disable postgres` refuse (code 2) and point to the command to run on the workstation, without touching the state.
- **Installing from the workstation**: `devzone workspace services enable <service> [options]` (the options of `devzone enable`, for example `--context CTX` for postgres) and `devzone workspace services disable <service> [--yes]` (`--yes` is required: there is no terminal in the pod to confirm). The workstation creates a `devzone-services-admin` service account in `devzone-workspace`, bound to `cluster-admin` for the duration of the operation, asks it for a one-hour token (`kubectl create token`, kubectl 1.24 or newer), then runs the usual installer **in the workspace pod** (`kubectl exec`, script `.devcontainer/services-admin.sh`): the token goes through standard input, never as an argument nor displayed, and lives only in a temporary kubeconfig of the pod (rights 600, contexts `devzone-admin` and `devzone`), deleted at the end. The state and secrets (`workspace/.postgres/`, `workspace/.gitlab/`, `workspace/.argocd/` under `/workspaces/projets`) remain in the pod, as on the Docker workstation. At the end, even on failure: the pod's relays are stopped (access goes through the cluster DNS and `devzone workspace ports`), the `cluster=` line of the state is restored as before, the service account and the ClusterRoleBinding are deleted. `devzone workspace services status` says, per namespace, what is installed. Since #516, `argocd` is installed or removed by the workstation itself (helm), and `postgres` goes through an Argo CD Application when Argo CD is active (see [Argo CD in the Kubernetes workspace](#argo-cd-in-the-kubernetes-workspace)).
- **Out of scope**: Argo CD as the source of the services (#516); `mysql` and the catalog (already through DNS, #515); the `devzone postgres create …` commands in the pod, which still require a kubeconfig.

### Building an image in the workspace

In the Kubernetes workspace pod, the BuildKit client `buildctl` (same version as the `buildkitd` sidecar) is installed in the image and talks to the pod's BuildKit sidecar (#514, official archive https://github.com/moby/buildkit/releases/tag/v0.34.2).

```bash
devzone build <folder> [--tag <name>]
```

- Without `--tag`: `buildctl build --frontend dockerfile.v0 --local context=<folder> --local dockerfile=<folder> --output type=cacheonly` (validation/cache only).
- With `--tag <name>`: output `--output type=image,name=<name>,push=false` (image loaded into the sidecar's cache).
- Outside the pod, `devzone build` refuses with “use docker build on the Docker workstation”.

The image cache stays in the filesystem of the `buildkitd` sidecar: it is lost when this container restarts.

### Editing from the workstation

**VS Code**: `devzone workspace vscode` displays the procedure. Extensions “Kubernetes” and “Dev Containers”; in the Kubernetes view, with the `devzone` context: namespace `devzone-workspace`, pod `devzone-workspace-0`, container `workspace` → “Attach to Running Kubernetes Container”, then open the folder `/workspaces/projets`.

**IntelliJ (JetBrains Gateway)**: Gateway installs the IDE backend in the pod and opens it in a light client on the workstation. The connection goes over SSH: it needs the pod's SSH server and its port forwarding to the workstation, which come with the workspace ports (#401).

1. Gateway → *Remote Development* → *New Connection* → *SSH*: host `127.0.0.1`, port forwarded from the pod, user `vscode`.
2. Folder opened by the backend: `/workspaces/projets/<project>`.

While waiting for these two points, edit the project on the workstation through copies: `devzone workspace copy-to <folder>` before, `devzone workspace copy-from <folder>` after.

### Developing devzone and repowarden in the pod

The working clones, the ticket worktrees and the agents live in the pod; the workstation only keeps the control.

1. **Clone** (from the workstation): `devzone workspace clone <url> [<name>]` makes an HTTPS `git clone` into `/workspaces/projets/<name>` in the pod (the default name is that of the repository), connects the pod's git credentials to `gh`, copies your git identity from the workstation into the clone and installs the hooks there (`repowarden install`). Rerun, it does nothing; a folder that exists with another remote is refused. Examples: `devzone workspace clone https://github.com/SimBienvenueHoulBoumi/devzone` and `…/repowarden`.
2. **One worktree per ticket** (in the pod): `devzone ticket <n> [--repo devzone|repowarden]` creates `/workspaces/projets/devzone-wt/dz-<n>` (or `/workspaces/projets/repowarden-wt/rw-<n>`), runs `repowarden ticket <n>` there (branch created from develop and linked) and shows the path. Once the PR is merged: `devzone ticket done <n>` removes the worktree and the local branch; it refuses if the worktree is not clean or if the branch still exists on origin. In the tools container, the same command uses `/workspaces/devzone` and `workspace/wt/dz-<n>` (devzone only).
3. **Agent**: `devzone agent /workspaces/projets/devzone-wt/dz-<n> <instruction>` from the workstation launches opencode directly in this pod folder, without a copy (a `/workspaces/projets/…` path absent from the workstation designates the pod); `--local` keeps the tools container. `devzone workspace start` runs `repowarden agents init --global` in the pod when the `ia` module is active there: an agent is stopped there before modifying develop.

4. **Agent in an ephemeral pod** (`--pod`): `devzone agent --pod <folder> <instruction>` launches opencode in an ephemeral Kubernetes pod dedicated to the session. The pod is created with limited resources (2 CPU, 4 Gi memory), a mandatory affinity to the `devzone-workspace-0` workspace pod, and restricted mounts: the ticket worktree at the same path as in the workspace (`/workspaces/projets/<repo>-wt/<name>` via subPath), the repository `.git` at the same path (`/workspaces/projets/<repo>/.git` via subPath), and state subfolders (.config/opencode, .local/share/opencode, .local/state/oc-lancer, .local/npm read-only). The pod isolates the worktree and the host's configuration files: the network is not filtered (that is #220), the workstation kubeconfig, `~/.config/gh`, `~/.claude` and the other worktrees are not isolated and remain accessible; as the repository `.git` is mounted, the references of the other branches are readable and writable there. The pod is always deleted at the end, even on failure or interruption (trap). Without `--pod`, the current `devzone agent` behavior is strictly unchanged.

   **Egress proxy (#220, disabled by default)**: when the workspace chart is rendered with `egressProxy.enabled=true`, an HTTP(S) proxy (Squid) is deployed (`egress-proxy`, port 3128). Two modes (`egressProxy.mode`):
   - `observation`: the proxy accepts everything and logs, without NetworkPolicy (nothing is blocked). Session pods receive `HTTP_PROXY`/`HTTPS_PROXY=http://egress-proxy:3128` and `NO_PROXY=localhost,127.0.0.1,.svc,.cluster.local`.
   - `strict`: the proxy only allows `egressProxy.allowedDomains` (default `.opencode.ai`, `.npmjs.org`, `.github.com`); a NetworkPolicy limits the outbound traffic of pods carrying the label `devzone.io/agent-session` to the proxy (3128) and to DNS (kube-system UDP/TCP 53). A guard init container tries 20 times (1 s) a direct connection `curl --noproxy "*"` to `https://opencode.ai` and only lets the agent start when the connection fails; if the restriction never becomes effective, the session is refused (“egress restriction never became effective: session refused”), to cover the 1 to 2 s window at startup.

   Reading the contacts: `kubectl logs deploy/devzone-workspace-egress-proxy -c access-log -n <namespace>`. Limits: the workspace itself remains open; only `devzone agent --pod` sessions are filtered; in strict mode, tools that ignore `HTTPS_PROXY` are blocked. Without `egressProxy.enabled=true`, the chart rendering and the session pod manifest remain identical.

   **Workstation commands (#633)**: `devzone workspace egress observation|strict|off` sets the mode; `status` shows the mode (label `devzone.io/egress-mode` of the `egress-proxy` service, otherwise `egress off`), whether the proxy is ready, the number of allowed domains and, from the last 2000 lines of the access log, each domain contacted with its access count and its state (`allowed`, `refused`, or `observed` in observation mode). `allow <domain>` and `deny <domain>` manage the added list (`egressProxy.extraDomains`): a domain must be lowercase, with at least one dot, an optional leading dot, no space, comma, `*` nor `/`. `deny` only removes added domains; the base list (`.opencode.ai`, `.npmjs.org`, `.github.com`) is changed in `egressProxy.allowedDomains` of the chart.

   The mode and the added domains are stored in `.devzone.modules` (`egress=`, `egress_domains=`) and replayed at each `devzone workspace start` and `devzone workspace update`. Each change redeploys the Argo CD Application at the same image tag: the workspace pod is not recreated, and the command waits for the proxy to be ready (120 s). Without an Argo CD Application (direct installation), the setting is kept and `devzone workspace start` applies it.

   Example path: `devzone workspace egress observation` (let the sessions work), `devzone workspace egress status` (the domains contacted), `devzone workspace egress allow <domain>` for each legitimate domain that is missing, then `devzone workspace egress strict` (only `--pod` sessions are filtered; the workspace stays open).
5. **Push**: `git push` from the worktree, over HTTPS with the `gh` credentials; the PR is made as everywhere else.
6. **Stale copies**: `devzone workspace copy-to` refuses to overwrite a pod folder that is a git clone of another remote; `devzone workspace status` reports the old `repogarde/` and `wt/` copies (whose `.git` points outside the pod) with the command to remove them, to run after a backup.

Remaining on the workstation: `make up` and `make rebuild`, `devzone workspace start` and the devcontainer image.

### Testcontainers and Docker in the workspace

- `docker` and Testcontainers talk to kubedock (`DOCKER_HOST=tcp://127.0.0.1:2475`): nothing to configure, and the workstation's Docker socket is not mounted.
- Each container launched by Testcontainers becomes a pod of the namespace, created and deleted by kubedock. Ryuk is disabled (`TESTCONTAINERS_RYUK_DISABLED=true`): kubedock cleans up by itself.
- Container ports are relayed by kubedock (`--port-forward --reverse-proxy`): nothing to publish on the pod.
- The `workspace` container starts only once kubedock and BuildKit are reachable (startupProbe, 60 s at most).
- Testcontainers features not supported by kubedock 0.23.0: networks, mounts and compose are not tried (#410).
- **Foreground containers**: `docker run --rm` does not attach the output, and terminated pods or `--rm` ones may stay in `Completed` (a kubedock 0.23.0 limit, observed). Use `docker run -d` then `docker logs`, or Testcontainers (which reads the logs). To limit the accumulation, kubedock is launched with `--reapmax` and `--prune-start` (https://github.com/joyrex2001/kubedock/blob/master/config.md).
- Images built by BuildKit (`BUILDKIT_HOST=tcp://127.0.0.1:1234`, `devzone build`) stay in the filesystem of the `buildkitd` sidecar: the cache is lost when this container restarts.

### Security: workspace without Docker

- **No privileged container**: neither kubedock, nor BuildKit, nor the workspace has `privileged: true`. A `helm template` test (`manage/test/workspace-without-docker.bats`) fails if such a container appears.
- **Rootless BuildKit**: UID 1000, `--oci-worker-no-process-sandbox` (the BuildKit documentation recommends it for Kubernetes, with its caveats). seccomp and AppArmor are `Unconfined` (`buildkit.unconfined`), otherwise `mount` and `unshare` are blocked. This profile is the only security relaxation of the workspace: it does not grant any privilege.
- **No workstation socket**: the host's Docker socket (#291) is not mounted, and no node socket is shared.
- **Listening**: kubedock and BuildKit listen only on `127.0.0.1` of the pod, without TLS. No port is declared (neither `containerPort` nor `hostPort`), and the Service only exposes the workspace HTTP.
- **RBAC**: the service account has a Role (not a ClusterRole) limited to the namespace, with the rights kubedock 0.23.0 uses: pods (get, list, watch, create, delete), pods/log (get), pods/exec and pods/portforward (create), services and configmaps (list, create, delete). No rights on secrets nor deployments. The pod can thus launch containers and run them in the namespace, without writing anything outside it.
- **Relayed ports**: test containers are reachable by the other pods of the namespace (the NetworkPolicy allows it). Do not put any secret in them.
- **Isolation**: the workspace sees all the test containers of its namespace, including those launched by other projects. A project must not rely on isolation between its containers and those of another project.

## GitLab

The `gitlab` module provides a test GitLab instance in the [services cluster](#devzone-cluster), namespace `devzone-gitlab` (suffixed by instance).

```bash
devzone                        # state: git identity, GitHub, tools, modules
devzone enable gitlab         # enables and installs GitLab in the services cluster
devzone disable gitlab      # uninstalls GitLab and deletes its namespace
devzone gitlab migrate          # installs, then offers to delete the old kind cluster
devzone gitlab migrate --yes    # same, without confirmation
devzone gitlab new-password [root|dev]  # random password (root or dev) regenerated
devzone apply              # applies the active modules
devzone is-enabled gitlab           # code 0 if GitLab is active
```

- **Resources**: at least 8 GB of **allocatable RAM in the services cluster** (sum of the nodes, refused otherwise); about 8 GB used once GitLab is installed. Too heavy for GitHub CI: tested by hand.
- **Duration** (measured): full installation about 7 min (including the GitLab chart, awaited up to `GITLAB_ATTENTE`, 1200 s by default); a rerun on a ready instance about 35 s (nothing is reinstalled or pushed again).
- **What is installed**: namespace `devzone-gitlab<instance>` in the cluster chosen for the services, labelled and isolated by NetworkPolicy; the chart wrapper [`charts/devzone-gitlab`](#devzone-charts) (#538) pins the dependencies `gitlab` 9.11.16 (GitLab 18.11 CE) and `gitlab-runner` 0.88.2, from `https://charts.gitlab.io` (no published OCI repository); `Chart.lock` committed, `helm dependency build` before installation. Its `values.yaml` keeps the former values (`gitlab` and `gitlab-runner`): without cert-manager, Prometheus, registry nor KAS, nginx with one replica and services as `ClusterIP` (ingress disabled); Kubernetes executor, internal URL and job clone in the same namespace.
- **Argo CD holds the chart** (#538): with the `argocd` module active and installed, the installation is the Application `devzone-gitlab` (chart `charts/devzone-gitlab` at the revision), not a helm pass. A `gitlab` release previously installed by helm is adopted (its release secrets are deleted, the objects remain). Without Argo CD (or a development clone at `0.0.0`), `helm upgrade --install` of the same chart, in two passes: the runner is held at zero replicas until its Secret is written by the seed.
- **Runner secret**: the seed writes the Secret `gitlab-runner-secret` (key `runner-token`, read from `workspace/.gitlab/runner-token`, never on a command line); the chart reads it through `runners.secret`.
- **Seed outside the installation**: `devzone gitlab seed` reruns the seed alone (relay, waiting for GitLab, data). In the workspace pod, `devzone workspace services seed gitlab` does it through `services-admin.sh seed gitlab`; it is the only seed action (the other services have none).
- **Test data**: group `devzone`, project `devzone/demo` (Python, ruff and pytest pipeline), user `dev`, registered runner. On a rerun, nothing is recreated.
- **Access in the container**: http://gitlab.localhost:8929, user `root`. The name `gitlab.localhost` points to `127.0.0.1` in `/etc/hosts` (entry `127.0.0.1	gitlab.localhost # devzone:gitlab`, set at activation and at each startup, replaced if its address differs, removed at deactivation). Two `kubectl port-forward` relays listen on `127.0.0.1:8929` and `127.0.0.1:2224`: `svc/gitlab-webservice-default` (8929→8181) and `svc/gitlab-gitlab-shell` (2224→22), in the instance's namespace (PID and log in `workspace/.gitlab-web/` and `workspace/.gitlab-ssh/`). They are essential for curl and git over HTTP: libcurl resolves any `*.localhost` name to the loopback without reading `/etc/hosts` (RFC 6761). ssh and glab read `/etc/hosts` and go through the same relay.
- **Access from the workstation**: GitLab is not published directly on the network; the port-forward listens in the container. From the workstation, use `devzone port 8929` (and `devzone port 2224` for SSH) if needed.
- **Old cluster**: a kind cluster `gitlab<instance>` created before #396 is no longer used. The `devzone` summary displays `⚠ old kind-gitlab cluster<instance>: devzone gitlab migrate` as long as it exists. `devzone gitlab migrate` installs GitLab in the services cluster, then deletes the old cluster after confirmation (`--yes` without a terminal); without a terminal and without `--yes`, the installation is done and the old cluster is kept (code 2). The test data of the old cluster is not migrated.
- **Secrets**: root password, root token, password of `dev` and runner token in `workspace/.gitlab/` (rights 600, ignored by git, never displayed). Root password: `cat workspace/.gitlab/root-password`.
- **Rails secrets**: the `gitlab-rails-secret` secret of the `devzone-gitlab` namespace is kept in `workspace/.gitlab/rails-secret.yaml` (600, ignored by git) at the first installation, then reapplied before `helm upgrade --install` on a reinstallation: the chart reuses it and browser sessions remain valid, without 422.
- **Reinstallation**: failing that, if the secrets were lost, the end of the installation and the summary warn: “GitLab réinstallé : si le navigateur affiche 422, supprimez les données de site de gitlab.localhost” (*GitLab reinstalled: if the browser shows 422, delete the site data of gitlab.localhost*).
- **Regenerable password**: `devzone gitlab new-password [root|dev]` applies a random password through `gitlab-rails runner` in the toolbox pod, then updates the source file and the grouped `.password`; nothing is displayed, only the path.
- **Deactivation**: `devzone disable gitlab` stops the two relays, uninstalls the Helm releases `gitlab` and `gitlab-runner`, deletes the namespace `devzone-gitlab<instance>` and the rest of `workspace/.gitlab/`, but **keeps `rails-secret.yaml`**: “Rails secret kept in workspace/.gitlab/rails-secret.yaml (browser sessions valid on reinstallation)”. The secret only goes with a deliberate full uninstallation (`devzone disable gitlab --yes`, or answering `o` to the confirmation). The services cluster and its current context are not touched.

### End-to-end test: `devzone test-gitlab`

`devzone test-gitlab` replays on the workstation the real test of the GitLab module and platform, which the GitHub CI cannot run (8 GB of RAM). The script is `.devcontainer/gitlab/test-gitlab.sh`.

```bash
devzone test-gitlab              # steps 1 to 7
devzone test-gitlab --complet    # disables, checks that nothing remains, then reinstalls
devzone test-gitlab --statut     # also publishes the gitlab-integration status on HEAD
```

- **Steps**, each timed: 1 module active (otherwise activated); 2 state “ready” and runner online; 3 `gitlab.localhost` resolved to `127.0.0.1` and TCP relays active on 8929 and 2224 (`gitlab.sh hote-poser` and `relais-lancer`), otherwise ✖ with the missing address or port; 4 pipeline of `devzone/demo` re-run on `main` and awaited until `success`; 5 SSH clone (disposable ed25519 key) and HTTP clone authenticated by a credential helper (Basic `oauth2` + token read from the file, never in process arguments, the URL nor `.git/config`); 6 `gitlab` platform with `glab repo clone`, then back to the previous platform; 7 integration suite `test/gitlab/` of repowarden ([#533](https://github.com/simdevWarden/repowarden/issues/533)): folder absent at the ref → step skipped with the reason; failure → output kept in `${TMPDIR:-/tmp}/devzone-test-gitlab-repowarden.log` (token masked) and cited in the reason. With `--complet`, a step 8 comes before the others: `devzone disable gitlab`, then a check that there remains neither namespace `devzone-gitlab<instance>` (name computed as `gitlab.sh` does), nor container labelled `devzone.instance=<instance>` of the module on the host's Docker, nor `workspace/.gitlab/`, nor the `# devzone:gitlab` line in `/etc/hosts`.
- **Summary**: one line per step (✔/✖/skipped, duration, reason) and a total; the exit code is 0 only without ✖ (a skipped step does not fail). A token is never displayed.
- **Guaranteed cleanup** by `trap … EXIT`: SSH key removed from GitLab, temporary folders deleted, previous platform restored, even if a step fails.
- **Variables**: `GITLAB_TEST_PIPELINE` (pipeline timeout, 600 s by default), `GITLAB_TEST_INTERVALLE` (pipeline polling interval, 5 s by default), `REPOWARDEN_TEST_REF` (ref of the integration suite, `develop` by default), `DEVZONE_ROOT` (repository root, as for `gitlab.sh`).
- **Indicative duration**: a few tens of seconds on an already ready instance; several minutes if the module must be installed (about 7 min), and more with `--complet`, which reinstalls.
- **`--statut`**: publishes the result as the `gitlab-integration` commit status (`success`/`failure`, short summary as description) on `HEAD` of the current repository, through `gh api repos/<repo>/statuses/<sha>` with the maintainer's token. Clear refusal if `gh` is not connected. See the rule in [Contributing](contributing.md).


## PostgreSQL

The `postgres` module provides a shared PostgreSQL: one database and one user per project, on the [devzone cluster](#devzone-cluster).

```bash
devzone enable postgres [--context CTX]   # installs (choice of the cluster the first time)
devzone postgres create <project>             # database + user <project>, credentials in workspace/.postgres/<project>.env
devzone postgres create <project> --new-password
devzone postgres list                      # databases and owners
devzone postgres psql [<project>]            # psql console in the pod (superuser without project)
devzone postgres delete <project> [--yes] # database, user and .env file
devzone disable postgres                 # removes PostgreSQL and ALL its databases
```

- **What is installed**: `charts/devzone-postgres` (helm release `postgres`, #559), StatefulSet `postgres` (pinned image `postgres:16.x-alpine`), 5 Gi persistent volume (`POSTGRES_TAILLE`), Service `postgres:5432`, namespace `devzone-postgres` labelled `app.kubernetes.io/managed-by=devzone`. No Bitnami chart nor image.
- **Access**: a `kubectl port-forward` relay makes the service reachable on `127.0.0.1:5432` **in the container** (`POSTGRES_PORT` for another port); relaunched at each startup and by `devzone apply`. PID and log: `workspace/.postgres/relais.*`.
- **Databases per project**: name in lowercase, digits and `_`. `create` is idempotent: the password is kept (unless `--new-password`); `REVOKE CONNECT … FROM PUBLIC`: a project does not connect to another project's database. The `<project>.env` file (600) contains `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` and `DB_URL` (JDBC).
- **Secrets**: password of the `postgres` superuser in the secret `postgres-admin` and in `workspace/.postgres/admin-password` (600); never regenerated as long as the secret exists; never displayed.
- **Deactivation**: namespace deleted (volume included), `workspace/.postgres/` deleted, dedicated kind cluster deleted if it no longer carries any service. `make uninstall` also deletes the namespace of a host cluster.

## MySQL

The `mysql` catalog provides a shared MySQL (one database per project), on the [devzone cluster](#devzone-cluster), namespace `devzone-mysql`, reachable on `127.0.0.1:3306` in the container.

```bash
devzone enable mysql
devzone mysql create <project> [--new-password]
devzone mysql list
devzone mysql delete <project> [--yes]
devzone mysql volume                 # lists the *-mysql-0 PVCs, marks the mounted one
devzone mysql volume <name>          # reapplies the StatefulSet on this volume (data kept)
devzone mysql volume --delete <name> [--yes]
devzone disable mysql             # removes StatefulSet, service and secret; volume kept
devzone mysql delete-data [--yes]  # deletes the namespace and the volumes (confirmed)
```

- **Volumes**: before installation, if a single `*-mysql-0` PVC exists in the namespace, it is reused; none → claim `donnees`; several → refused with the list and `devzone mysql volume <name>`. `devzone mysql volume <name>` reapplies the StatefulSet on the chosen PVC without deleting the data. `--delete` asks for `[y/N]` confirmation in a terminal (`--yes` without a terminal) and refuses if the volume is mounted. The summary reports `⚠ volume <pvc> non utilisé : devzone mysql volume` (*volume unused*).
- **Uninstalling and deleting the data**: `devzone disable mysql` removes the StatefulSet, the service and the secret, keeps the volume (PVC) and the databases, and displays `✔ mysql retiré du cluster ; volume <pvc> et bases gardés : devzone mysql volume`. In a terminal, the question is “Disabling mysql removes the server, the volume and the databases stay. Also delete the devzone-mysql namespace and its volumes?”: a `oui` (or `--yes` without a terminal) also deletes the `devzone-mysql` namespace and its volumes; a refusal keeps the volume and the databases, the server leaves anyway; without a terminal and without `--yes`, the data stays. `devzone mysql delete-data [--yes]` does this deletion alone: `[y/N]` confirmation in a terminal, `--yes` mandatory otherwise (otherwise refused with the exact command). The namespace and the volumes go, `workspace/.mysql/root.env` is kept; `devzone mysql volume` then lists the remaining volumes.

## devzone charts

Each devzone service has its own chart in `charts/` (#538): a single definition per service, the single source of the installation on the Docker workstation, in the container and through Argo CD.

- `charts/devzone-mysql`: the shared MySQL of the catalog (the only MySQL definition, also installed by direct helm through `.devcontainer/chart-direct.sh`). The secret `<name>-admin` (root password) stays created separately, never by the chart.
- `charts/devzone-postgres`: the shared PostgreSQL (same model).
- `charts/devzone-argocd`: wrapper of the official `argo-cd` chart (version pinned in `Chart.yaml`, `Chart.lock` pins the version and the digest of the dependency), minimal devzone values in `values.yaml`. The dependency is built before installation (`helm dependency build`); the tgz thus built is not committed (`.gitignore`).

Each chart is checked by `helm lint` and `helm template` (`manage/test/chart-*.bats`), without a cluster.

### devzone chart convention

The code assumes that each service has a chart `charts/devzone-<service>` (#554): the calls (`services.sh`, `catalog-argocd.sh`, `argocd-services*.sh`, `argocd-workspace.sh`) build this path from the service name. The convention below is the rule these calls assume.

**Folder and `Chart.yaml`**

- The folder is called `charts/devzone-<service>`, `<service>` in lowercase, digits and hyphens (`[a-z0-9-]+`).
- `name` is exactly the folder name. `type: application`.
- `version` is a semver (`0.1.0`). `appVersion` is the version of the packaged software, never empty.
- `description` is in English and cites the ticket that introduced the chart (`#NNN`).

**Two families**

- **Service**: the chart carries its own templates (StatefulSet, Service, etc.). Its rules:
  - the namespace is never hard-coded, only `{{ .Release.Namespace }}`;
  - each object carries `app.kubernetes.io/name=<service>`, `app.kubernetes.io/part-of=devzone` and `app.kubernetes.io/managed-by=devzone`;
  - no `kind: Secret` in the templates: the secrets are created separately, by devzone (#538);
  - no `Ingress` nor `LoadBalancer`: access goes through the workstation's `kubectl port-forward` relay;
  - the common values below are present in `values.yaml`.
- **Wrapper**: the chart has only `dependencies:` (an official chart, pinned). Its dependency is an exact version, preferably in `oci://`, its values live under the key of the official chart, and `Chart.lock` is committed. A repository without `oci://` produces a warning.

The family is deduced from the chart: `dependencies:` present = wrapper, otherwise service.

**Common values keys**

| Key | Meaning | Example |
|---|---|---|
| `image` | image of the main container, with its pinned version | `mysql:8.4` |
| `size` | size of the data volume (PVC) | `5Gi` |
| `memory` | memory requested (`requests`) of the main container | `1Gi` |
| `port` | Service port (the container listens on its own port) | `3306` |
| `claim` | name of the volume claim template mounted by the container | `donnees` |
| `resources` | other container resources (`requests`/`limits` of CPU, etc.) | `requests: {cpu: 100m}` |

`devzone-workspace` is an exception: it is the workstation itself, whose volumes are set by `workspace.size` and `persistence`, not by these keys.

**Check**

The script `manage/scripts/ci/check-charts.sh` applies the convention to each folder of `charts/` and to any `charts/devzone-<x>` reference in the code; it runs `helm lint` and the rendering when helm is present. A failure is shown as `✖ charts/<x> : <rule>` and fails the check. Before applying a chart, devzone checks that `charts/devzone-<service>/Chart.yaml` exists and carries `name: devzone-<service>`; otherwise it stops before any call to `kubectl` or `helm`, exits with code 2 and shows `✖ <service> : chart charts/devzone-<service> missing or misnamed (manage/docs/reference.md#devzone-charts)`. The catalog callers (`app.sh`, `mysql.sh`) receive this failure as an ordinary failure and exit with code 1.

**Adding a service**: create `charts/devzone-<service>` according to the family, add the useful common values, run `bash manage/scripts/ci/check-charts.sh`, then a test `chart-<service>.bats` (lint and rendering).

## Argo CD

The `argocd` module provides Argo CD on the [devzone cluster](#devzone-cluster). On the Docker workstation, it is a module like the others (below); in the [Kubernetes workspace](#argo-cd-in-the-kubernetes-workspace), Argo CD is installed by default and holds the devzone deployments (#516).

```bash
devzone enable argocd      # installs Argo CD in the services cluster
devzone disable argocd   # uninstalls Argo CD, the other services remain
devzone argocd status         # state of the module
devzone argocd init [--repo <url>|--none]  # GitOps repository (GitHub): created, designated, or none
devzone <folder> --gitops <github|none|<url>>  # folder creation with the GitOps repository (same repository as above)
devzone argocd apply        # applies the instance's .argocd.conf
devzone argocd app add <repo> [path] [--name N] [--revision R] [--namespace NS] [--token T] [--username U]  # a project deployed by Argo CD
devzone argocd app list     # Applications of the projects, sync and health
devzone argocd app remove <N>  # removes the Application and its resources
```

The projects are declared in `.argocd.conf` at the root of devzone and, if there is one, in the user's GitOps repository: see [GitOps repository and `.argocd.conf`](#gitops-repository-and-argocdconf).

- **What is installed**: the [wrapper chart `charts/devzone-argocd`](#devzone-charts), which takes over the official `argo-cd` chart at a pinned version (`10.14.0`, dependency declared in `Chart.yaml`, `Chart.lock` commits the fingerprint), namespace `devzone-argocd` labelled `app.kubernetes.io/managed-by=devzone` and isolated by NetworkPolicy. Minimal values (in `charts/devzone-argocd/values.yaml`): one replica per component, without Dex nor notifications, server as `ClusterIP`, without Ingress nor LoadBalancer. The installation first builds the dependency (`helm dependency build`), then installs the local chart, on the workstation as in the container; the same wrapper serves Argo CD itself when it deploys itself (#538).
- **Memory**: the installation is refused under about 1 GB of allocatable memory in the cluster, with the message to enlarge it.
- **Access**: a `kubectl port-forward` relay makes the interface reachable at https://127.0.0.1:8443 **in the container** (`ARGOCD_PORT` for another port); relaunched at each startup and by `devzone apply`. PID and log: `workspace/.argocd/relais.*`.
- **Projects**: `devzone argocd app add <repo> [path]` declares an Application `app-<N>` (name taken from the repository, or `--name`), revision `HEAD` (or `--revision`), resources in the namespace `devzone-app-<N>` (or `--namespace`), automatic sync with `prune` and `selfHeal`. A **public GitHub** repository needs nothing else; a **private** repository takes `--token T` (and `--username U`, `root` by default), stored in a repository Secret `repo-<N>` of `devzone-argocd` (label `argocd.argoproj.io/secret-type=repository`), never in the Application. The **devzone GitLab** is given with its usual URL (`http://gitlab.localhost:8929/<group>/<project>.git`): it is rewritten to the cluster service (`http://gitlab-webservice-default.devzone-gitlab.svc:8181/…`, the only address Argo CD reaches), the module's root token (`workspace/.gitlab/root-token`) is used unless `--token` is given, and the NetworkPolicy of `devzone-gitlab` is opened to the devzone namespaces (same rule as `devzone postgres authorize`). `app remove <N>` deletes the Application, its resources, its repository Secret and the namespace `devzone-app-<N>`. The limited account (#430) manages all of this thanks to the aggregated roles of the chart (`createAggregateRoles`). Demo repository: https://github.com/SimBienvenueHoulBoumi/devzone-argocd-demo (`k8s/`).
- **Password**: read from the `argocd-initial-admin-secret` Secret, stored in `workspace/.argocd/admin.env` (600) then taken into [`.password`](#grouped-credentials); user `admin`, never displayed.
- **Deactivation**: `helm uninstall` of the release and deletion of the namespace `devzone-argocd`, then of `workspace/.argocd/`; **the other services remain**, under direct helm.

### Argo CD in the Kubernetes workspace

In Kubernetes workspace mode, Argo CD becomes devzone's deployment means (#516). Everything is driven from the workstation (`manage/scripts/workspace/argocd-workspace.sh`, `argocd-services.sh`), which has the cluster administrator rights; the pod has none.

```bash
devzone workspace start                      # installs Argo CD if missing, then the workspace (Application) and .argocd.conf
devzone workspace services enable argocd     # installs Argo CD (or reinstalls it) from the workstation
devzone workspace services disable argocd    # removes it; the services remain, under direct helm
devzone workspace argocd status              # installed or not, GitOps repository, Applications (sync, health, revision)
devzone workspace argocd init [--repo <url>|--none]   # GitOps repository: created on GitHub, designated, or none
devzone workspace argocd apply               # applies .argocd.conf (Applications added, removed)
devzone workspace argocd app add <repo> [path] [--name N] [--revision R] [--namespace NS] [--token T] [--username U]
devzone workspace argocd app list | app remove <N>
```

#### GitOps repository and `.argocd.conf`

The declarations do not stay in the cluster: they live in a **GitOps repository specific to the user**, which Argo CD follows, and in a **configuration file** of the devzone folder, `.argocd.conf`, in the same form as `.repowarden.conf`:

```ini
[argocd]
    repo = https://github.com/<login>/devzone-argocd.git   # none: direct application, without repository

[services]
    postgres = on          # mysql, gitlab: same (#538)

[app demo]
    repo = https://github.com/argoproj/argocd-example-apps
    path = guestbook
    revision = HEAD
    namespace = devzone-app-demo

[app interne]
    repo = http://gitlab.localhost:8929/devzone/interne.git   # devzone GitLab: URL rewritten to the cluster service
    path = k8s
    username = root
    token-file = workspace/.gitlab/root-token                 # never the token itself, only its path
```

- **The file is the declaration**: versioned with the devzone folder (it is not ignored by git), written by devzone (`argocd init`, `app add`, `app remove`) and applied by `devzone workspace argocd apply` and `workspace start`: each `[app N]` becomes the Application `app-N`; a project Application absent from the file is removed (with its resources, its repository Secret and its namespace `devzone-app-N`). It can also be edited by hand, then `apply`.
- **`[services]` section** (#538): the services deployed in the cluster are declared there (`postgres = on|off`, then `mysql`, `gitlab`). For each service `on`, the reconciliation (by `apply` or `workspace start`) creates the labelled and isolated namespace `devzone-<svc>`, the secret **separately** (generated or re-read password, mirror `workspace/.<svc>/`, `.password`), then the Application `devzone-<svc>` (chart `charts/devzone-<svc>` of the devzone repository at the revision); a service `off` sees its Application removed with its resources, **the namespace and the volumes remain** (the data is kept); deleting the data remains the explicit command `devzone workspace services disable <svc> --yes`. The `<svc>=on` lines of `.devzone.modules` are read for compatibility when the section does not yet carry the service, and the section wins as soon as it carries it.
- **GitOps repository**: `devzone workspace argocd init` creates `<login>/devzone-argocd` (private, `gh repo create` with the workstation's `gh` connection) if it is missing and notes it in `[argocd] repo`; `workspace start` does it without an option. `--repo <url>` designates an existing GitHub repository; `--none` gives up (the Applications are applied directly, as without a repository). Without `gh` connected: a notice, direct application. The same option accompanies the folder creation: `devzone <folder> --gitops <github|none|<url>>`.
- **What goes into the repository**: a root Application `devzone` (the only object applied by `kubectl`) follows the `apps/` folder; `workspace start`, `services enable|disable postgres` and `app add|remove` write or remove `apps/<name>.yaml` through the GitHub API (`gh api`, without clone nor local commit), then request a `refresh` (Argo CD reads Git only every 3 min). Argo CD reads the repository with the workstation's `gh auth token` (`DEVZONE_GITOPS_TOKEN` for another one), stored in the repository Secret `repo-devzone-argocd`. The service secrets stay created separately, never in Git.
- **Private repositories and devzone GitLab**: `--token T` stores the token in `workspace/.argocd/tokens/<N>` (600, outside Git) and notes `token-file`; a `gitlab.localhost` URL is rewritten to `http://gitlab-webservice-default.devzone-gitlab.svc:8181/…` (the only address Argo CD reaches), the module's root token serves by default (`workspace/.gitlab/root-token` on the workstation, otherwise the one of the pod), and the NetworkPolicy of `devzone-gitlab` is opened to the devzone namespaces.
- **A GitLab as GitOps repository** (and not only as the source of a project): batch B.

- **By default**: `devzone workspace start` installs Argo CD (wrapper chart `charts/devzone-argocd`, at least 1 GB of allocatable memory, otherwise a warning and the workspace goes through direct helm) **unless** the workstation's `.devzone.modules` carries `argocd=off`. `services disable argocd` writes this line; `services enable argocd` sets it back to `on`.
- **Password and interface**: the `admin` password is read from `argocd-initial-admin-secret`, stored in `workspace/.argocd/admin.env` of the **workstation** (600) and in the workstation's [`.password`](#grouped-credentials); never displayed. The [port watcher](#ports-to-the-workstation) relays the https port of the `argocd-server` service to `https://localhost:8443` (127.0.0.1 only, self-signed certificate to accept).
- **The workspace is an Application**: `devzone workspace start` creates the Application `devzone-workspace` (chart `charts/devzone-workspace` of the public devzone repository, revision `v<package version>`, parameters `image.tag`, `image.repository` with `--image`, `image.pullPolicy=Always` for `latest`) in place of `helm upgrade --install`. An existing helm release is **adopted**: its release secrets are deleted, no resource is recreated; the pod restarts only if the chart changed since the release (a devzone update, as before). `devzone workspace stop` deletes the Application (the pod goes, the volumes remain); without an Application, `helm uninstall` as before. A **development clone** (version `0.0.0`) stays on direct helm, because its local chart is not in Git; the environment variable `DEVZONE_ARGOCD_REVISION` (a branch or a tag) forces a revision, for tests.
- **PostgreSQL through Argo CD**: with Argo CD active, `devzone workspace services enable postgres` writes `[services] postgres = on` and reconciles: namespace `devzone-postgres` (labelled, isolated by NetworkPolicy), secret `postgres-admin` **separately** (password generated on the workstation, or re-read from an existing secret; mirror `workspace/.postgres/admin-password` of the workstation, `.password` updated), then the Application `devzone-postgres` (chart `charts/devzone-postgres`; the chart is the single definition: the direct helm path installs it with `.devcontainer/chart-direct.sh`, an existing installation is adopted without recreation). `selfHeal` recreates what is deleted by hand. `disable postgres` removes the Application, **the namespace, the volumes and the databases remain**; `disable postgres --yes` also deletes the namespace and its data (mirror `workspace/.postgres` included). Without Argo CD, the path of #528 (installer in the pod) remains.
- **Projects**: declared in `.argocd.conf` (below), same commands as in the container, prefixed by `devzone workspace argocd`.
- **Secrets outside Git**: the Kubernetes secrets are created by devzone, never in the repository; the Applications only reference them. No additional operator (Sealed Secrets, External Secrets): a development workstation has no central vault, and devzone already keeps its passwords in `.password`.
- **Removal**: `services disable argocd` first removes the finalizer of each Application then deletes it **without cascade** (the resources remain), uninstalls the release and the namespace; the services continue under direct helm.
- **Batch B** (remains of #538, steps 3 to 6): Applications `mysql` and `gitlab`, services on the Docker workstation, GitLab as GitOps repository.

## Ports to the workstation

`devzone port` makes the applications that listen **inside** the devzone container accessible from the workstation: one `alpine/socat` relay per port, on the host's Docker (#290).

```bash
devzone port <n>              # opens 127.0.0.1:<n> of the workstation → <n> of the container
devzone port                  # list: port, ● active or ○ stopped, application behind it
devzone port --close <n>     # removes the relay and the port from the state
devzone port auto on|off     # enables or stops the automatic watcher
devzone port exclure <n>      # removes a port from the automatic list
devzone port inclure <n>      # puts a port back into the automatic list
```

- **Relay**: container `devzone-<instance>-port-<n>`, labelled `devzone.instance=<instance>` and `devzone.port=<n>`, pinned image `SOCAT_IMAGE=alpine/socat:1.8.0.3` (`.devcontainer/ports.sh`). It publishes `-p 127.0.0.1:<n>:<n>` only, with `--restart unless-stopped`.
- **Automatic watcher (#394)**: `.devcontainer/ports-auto.sh` watches the ports listening in the container every 2 s (`ss -ltnH`). A port not already relayed, not excluded, not a devzone service (5432, 8929, 2224) and not a bridge of the watcher is relayed: an internal bridge on the container's IP if the application only listens on `127.0.0.1`/`::1`, then the workstation relay `devzone-<instance>-auto-<n>`. A port gone for more than 10 s removes the bridge and the relay. A port already taken on the workstation is marked busy and is no longer retried. Only one watcher runs (`mkdir` lock in `/tmp/devzone-ports-auto/`, refreshed at each round; a dead instance is replaced). The watcher stops by itself if the state folder disappears. It only runs on the request of the startup scripts: any other call is refused (code 2), and shows the command to run (`devzone repair`). In the Kubernetes workspace (`DEVZONE_WORKSPACE` set to `kubernetes`), it does not start (#517): the ports go through `devzone workspace ports`.
- **Deactivation**: `devzone port auto off` stops the watcher and removes the automatic relays; `devzone port auto on` reactivates it: the watcher restarts at the next container startup or through `devzone repair`. At startup, the automatic relays of a previous session are removed.
- **Network and IP**: read by `docker inspect "$(hostname)"` on the host's Docker; the relay joins the container by its IP on its Docker network. devzone container not found (host Docker absent): clear refusal, code 1.
- **State**: line `ports=8080,3000` in `$RACINE/.devzone.modules`, sorted and without duplicates; `--close` removes the port. An already open relay is idempotent (message, code 0).
- **Startup**: `devzone start` relaunches each relay of the state toward the container's current IP (it changes at each restart). A failure shows a warning without blocking startup; `devzone repair` takes it up again without restarting.
- **Refusal, code 1**: non-numeric port or outside 1-65535; host Docker unreachable; port already taken on the workstation (failure of `docker run`, “port is already allocated” or “address already in use”), the state remaining unchanged.
- **Several instances**: the relay name and the label carry `DEVZONE_INSTANCE`; two instances that want the same workstation port: the second one receives the refusal `déjà utilisé` (*already used*).
- **Summary**: line `ports to the workstation` with `8080 ●, 3000 ○`, or `none (devzone port <n>)`.
- **Uninstalling**: `make uninstall` removes the containers labelled `devzone.instance` (see the README, “Uninstalling”).
- **Spring Boot**: the application must listen on `0.0.0.0` (default). A `server.address=127.0.0.1` makes it unreachable from the relay.

## devzone cluster

The modules that deploy a service (`postgres`, `gitlab`) are installed on **a single cluster**, chosen once and kept in the state (`cluster=` in `$RACINE/.devzone.modules`).

- **Local vs remote cluster**: a cluster is considered **local** when its server listens on a loopback address (`127.0.0.1`, `localhost`, `::1`, `host.docker.internal`), read from the kubeconfig, with no network call. The dedicated kind cluster (`kind-devzone`) is always local. Any other cluster (server on a remote address) is **remote**.
- **Choice**: at the first activation. `--context CTX` first; otherwise, in a terminal, a menu: the default cluster is the current context of the host kubeconfig if it answers and is local (in practice `docker-desktop`), otherwise the dedicated kind cluster `kind-devzone`. The choice is kept in the state and reused at restarts. The menu offers the **local** clusters first, then the **dedicated kind cluster**, and finally the **remote** clusters (marked “remote”); without a terminal: `kind-devzone`. The host clusters only appear with the [`kubernetes` module](#kubernetes) active.
- **Remote cluster**: choosing a remote cluster requires a confirmation in a terminal, or `--confirm CTX` without a terminal. Without the exact confirmation, the choice is refused. When the devzone cluster is remote, the `devzone` summary shows a warning `⚠ cluster distant : <context>`.
- **View / change**: `devzone cluster` shows the cluster and the possible ones; `devzone cluster CTX [--confirm CTX]` moves the active services there (uninstalled from the old one, installed on the new one). **The data is not migrated**: confirmation in a terminal, `--yes` without a terminal.
- **Host cluster**: devzone only creates its namespaces labelled `app.kubernetes.io/managed-by=devzone` there, and deletes them at deactivation. Disabling the `kubernetes` module makes this cluster unreachable for the services.
- **Current context**: kind clusters are created without switching to them; `devzone use CTX` only switches the kubectl working cluster, never the devzone services cluster. If you end up on an internal cluster (kind-devzone), go back with `devzone use <your cluster>`.
- **Namespace**: for a workstation context (those of `hote.config`, copied from the workstation at each startup), the namespace set by `devzone use -n` does not survive a restart; for the kind clusters of the container, it is kept until the rebuild.

- **Two notions**: `★` marks the kubectl working cluster (kubectl, k9s, helm), `●` the devzone services cluster (`devzone cluster`). A context may carry both marks. `devzone clusters` shows the view.
- **Rebuild**: the kubectl choice is written to `~/.kube/config`, which is not in a volume; a rebuild restarts on the host cluster.

### Services cluster and devzone context

- **Single cluster**: all services (PostgreSQL, GitLab, etc.) live on a single cluster chosen via `devzone cluster CTX`. The choice is kept in the state (`cluster=` in `$RACINE/.devzone.modules`) and survives restarts.
- **devzone context**: the kubectl `devzone` context is set on the services cluster (cluster and user taken from the current context). It is restored on the new cluster when `devzone cluster` moves the services. See `changer_cluster` in `cluster.sh`.
- **Cluster move**: `devzone cluster CTX [--yes]` moves PostgreSQL: deletion in the old cluster, installation in the new one. The data is not migrated, hence the required confirmation.
- **Local vs remote contexts**: a cluster is local when its server listens on a loopback address (`127.0.0.1`, `localhost`, `::1`, `host.docker.internal`), read from the kubeconfig, with no network call. The dedicated kind cluster (`kind-devzone`) is always local. Any other cluster (server on a remote address) is remote. The default choice is first the host's current context (in practice `docker-desktop`), then the dedicated kind cluster `kind-devzone`.
- **Remote cluster**: choosing a remote cluster requires a confirmation in a terminal, or `--confirm CTX` without a terminal. Without the exact confirmation, the choice is refused. When the devzone cluster is remote, the `devzone` summary shows a warning `⚠ cluster distant : <context>`.
- **Namespace**: for a workstation context (those of `hote.config`, copied from the workstation at each startup), the namespace set by `devzone use -n` does not survive a restart; for the kind clusters of the container, it is kept until the rebuild.

### GitLab as GitOps repository (container)

`devzone argocd init --gitlab` creates the project `devzone/devzone-argocd` on devzone's GitLab, through the API (no clone), private, with a first commit. It designates the repository in `[argocd]` (`repo` = internal URL, `provider = gitlab`): the Argo CD repository Secret takes this URL, with the user `oauth2` and the root token.

- The root token comes from `workspace/.gitlab/root-token`, passed to `curl` through a configuration file with mode 600 (never as an argument, never displayed).
- The files `apps/<name>.yaml` are written by `PUT` (existing) or `POST` (new) on `/projects/:id/repository/files/:path`, and removed by `DELETE`; a file with identical content is not rewritten.
- The backend is `.devcontainer/argocd/gitops-gitlab.sh`; `gitops.sh` selects it when `provider = gitlab`.
- Not done: the workstation command (`devzone workspace argocd init --gitlab`, through `kubectl exec` in the pod) remains to be wired.

### Services held by Argo CD in the container

With the `argocd` module installed and reachable, `devzone enable postgres|mysql` declares the service as an Application `devzone-<service>` (chart `charts/devzone-<service>` of the devzone repository at the revision): the `[services]` section of `.argocd.conf` switches to `on`, then the reconciliation applies the isolated namespace, the administrator secret (created separately, mirrored in `workspace/.<service>/admin-password`, never displayed) and the Application; devzone waits for the pods, then restarts the relay.

- **`devzone disable postgres|mysql`**: the Application goes with its resources; the namespace and the volumes remain, then the usual removal of the service follows.
- **`devzone disable argocd`**: the Applications of `postgres`, `mysql` and `gitlab` are removed *without* their resources (finalizer removed first, `gitops_delete_application … keep`); `[services]` switches to `off` for postgres and mysql. Argo CD is then uninstalled and the services remain, under direct helm, without being recreated (adoption by `kubectl apply`, see `postgres.sh` and `mysql.sh`).
- **GitLab** keeps its Application from step 4 (`gitlab/argocd.sh`): its namespace may carry an instance suffix, which the reconciliation (`services_ns_of`) does not know.
- The hook is `.devcontainer/argocd/services-hook.sh`, called by `change_module` of `devzone`; return code 0 (done by Argo CD), 3 (direct helm path), 1 (failure).

### Account limited to devzone namespaces

The `devzone` context only acts with a limited account: the shell, relays and agents never hold the cluster administrator role ([#430](https://github.com/SimBienvenueHoulBoumi/devzone/issues/430)).

- **Account**: ServiceAccount `devzone-agent` of the namespace `devzone-system`, bound to the ClusterRole `edit` in each `devzone-*` namespace by a RoleBinding. `edit` covers reading, writing, secrets and NetworkPolicies of the namespace; neither RBAC nor quotas, and nothing outside the `devzone-*` namespaces (deleting a namespace and reading the nodes remain administrator operations).
- **Token**: a 24 h TokenRequest written into the `devzone` context of `~/.kube/config` (user `devzone-agent`, cluster entry copied from the host context). Renewed at each container startup and by `devzone repair`; once expired, `devzone repair` renews it.
- **Administrator reserved for the installers**: creating the namespace, the label, the RoleBinding and the deletion go through the administrator context (`~/.kube/hote.config` for host clusters, `~/.kube/config` for kind clusters). The account is set up by the installers on a still-blank cluster, and is usable at the next token renewal.
- **Without a chosen services cluster**: `devzone repair` does not renew any token and the rest of the application continues on kubectl's current context.

### Isolation

- **NetworkPolicy `devzone-meme-namespace`**: sets an isolating rule in a namespace: only the pods of the same namespace can reach the devzone services (PostgreSQL, etc.). This rule is managed by `devzone postgres authorize <ns>` and `devzone postgres forbid <ns>`.
- **What the isolation covers**:
  - Prevents an application in an outside namespace from accessing PostgreSQL or other devzone services.
  - Allows an application in the same namespace to reach the services without restriction.
  - The rules are managed via `kubectl --context devzone -n <ns> patch networkpolicy devzone-meme-namespace`.
- **Limits of the isolation**:
  - Does not control access at the PostgreSQL database level (that is handled by the PostgreSQL roles and passwords).
  - Does not apply to host clusters without an explicit configuration.
  - The NetworkPolicy rules can be removed by `devzone postgres forbid <ns>`.
- **Verification**: `devzone clusters` shows `isolé (NetworkPolicy)` for the services cluster, and ⚠ if the rule is missing in a `devzone-*` namespace.

## Data kept

The container is disposable; what matters lives in Docker volumes, on your machine.

| Volume | Content | `make stop` | `make down` | `make rebuild` |
|---|---|---|---|---|
| `devzone-gh` | GitHub login (`gh`) | kept | kept | kept |
| `devzone-git` | git identity (`~/.config/git/config`) | kept | kept | kept |
| `devzone-claude` | Claude Code login and settings | kept | kept | kept |
| `devzone-opencode-config`, `devzone-opencode-data` | opencode login and settings | kept | kept | kept |
| `devzone-agent` | state of `devzone agent` (discarded models, rank), shared among devzone instances | kept | kept | kept |
| `devzone-config` | modules enabled (`devzone enable`): old user state, taken over once | kept | kept | kept |
| `devzone-m2`, `devzone-pnpm` | Maven (`~/.m2`) and pnpm caches | kept | kept | kept |
| `devzone-gradle` | Gradle cache (`~/.gradle`) | kept | kept | kept |
| internal Docker volume | images and kind clusters of the container | kept | kept | kept |
| `workspace/` (host folder) | your projects | kept | kept | kept |

Everything else in the container (packages installed by hand, files outside these locations) is lost at `make down` and `make rebuild`. The internal Docker is isolated: its images are not shared with Docker Desktop.



## Updating devzone

A devzone folder keeps its version in `.devzone.version`: the version, then a sha256 fingerprint (computed by node) for each file copied from the package. The command is run **on the workstation**, in the folder:

```bash
cd mon-devzone
devzone update              # installed package version
npx devzone@latest update   # latest published version
```

- **Already up to date**: folder version equal to the package version and no package file missing → `déjà à jour`, code 0. The message recalls `npx devzone@latest update` for the latest published version.
- **Locally modified files**: their fingerprint differs from that of the manifest (without a manifest, from that of the package). They are listed and a confirmation is requested. `--yes` answers yes for a script; without a terminal and without `--yes`, the command refuses (code 1) and touches nothing.
- **Backup**: any replaced or deleted file is copied to `.devzone.backup/<YYYYMMDD-HHMMSS>/`, with the same tree. This folder is added to the devzone `.gitignore`.
- **Replacement**: the package files are copied again, the files of the old manifest that no longer exist are deleted, as well as the old `core/` and `scripts/` trees at the root. `.gitignore` is completed with the missing lines, never overwritten.
- **Never touched**: `workspace/`, `.devzone.modules`, `.devzone.packages`, `.password`, `.app`, `.devzone.log`, the Docker volumes.
- **Rebuild**: the new `.devzone.version` is written, then `make rebuild` is proposed with confirmation in a terminal. `--sans-reconstruire` skips this step; without a terminal, the rebuild is indicated but never launched.
- **State key (#733, batch 4)**: `plateforme=` of `.devzone.modules` becomes `platform=`. `.devcontainer/rename-legacy-files.sh` rewrites it once, with its value (if `platform=` already exists, only the old line is removed), at each run that launches the script; the other lines do not move.
- **Old names (#733)**: `.devzone.paquets`, `.devzone.sauvegarde`, `.devzone.ports-workspace`, `.devzone.etat`, `.devzone.catalogue-veilleur`, `.devzone-empreinte` (skills) and the `-echec-` markers become `.devzone.packages`, `.devzone.backup`, `.devzone.workspace-ports`, `.devzone.state`, `.devzone.catalog-watcher`, `.devzone-fingerprint` and `-failed-`. `.devcontainer/rename-legacy-files.sh` renames them once, with their contents, at container startup, at `devzone update`, at `devzone workspace update` and at `devzone workspace migrate`. A new name already present is never overwritten; a second run does nothing.

A folder created before this manifest has an “unknown” version: all files that differ from the package are treated as modified (backup, then confirmation).

In the container, the `devzone` summary reads `$RACINE/.devzone.version` and the latest published version (`npm view devzone version`, at most once a day, cache under `~/.cache/devzone/`, 5 s timeout, silent offline). If it is more recent: `○ devzone X.Y.Z disponible : sur le poste, devzone update`.

## Updating a tool

| Tool | Where | Then |
|---|---|---|
| k9s, actionlint, gitleaks, kind | `.devcontainer/Dockerfile`: `ARG …_VERSION` **and** the `sha256` fingerprints (arm64 + amd64), by `bash manage/scripts/ci/versions.sh --apply <tool> <version>` | publish a version, then `devzone workspace update` |
| Go | `.devcontainer/Dockerfile`: `GO_VERSION` **and** the `sha256` fingerprints `GO_SHA256_ARM64` / `GO_SHA256_AMD64` (go.dev), by `bash manage/scripts/ci/versions.sh --apply go <version>`; keep `go.mod` and `.github/workflows/go.yml` at the same version | publish a version, then `devzone workspace update` |
| uv, ruff, vulture, pytest | `.devcontainer/Dockerfile`: `ARG …_VERSION` | publish a version, then `devzone workspace update` |
| repowarden | `.devcontainer/versions.env`: `REPOWARDEN_VERSION=x.y.z` | `devzone apply` (or `make rebuild`) |
| Claude Code, opencode | `.devcontainer/devzone`: one line per package, `IA_CLAUDE=@anthropic-ai/claude-code@x.y.z` and `IA_OPENCODE=opencode-ai@x.y.z` | `devzone enable ia` (or `make rebuild`) |
| glab (gitlab platform) | `.devcontainer/devzone`: `GLAB_VERSION` and the checksums `GLAB_SOMME_ARM64` / `GLAB_SOMME_AMD64` | `rm ~/.local/bin/glab` then `devzone platform gitlab --url URL` |
| metrics-server | `.devcontainer/metrics-server.sh`: `VERSION` | `devzone metrics` on a new cluster |
| Java, Node, Python, Docker, kubectl, helm, gh | `.devcontainer/devcontainer.json` (features), pinned versions in `devcontainer-lock.json` | `npx @devcontainers/cli upgrade --workspace-folder .` then `make rebuild` |

Fingerprint of an archive: `curl -fsSL <url> | shasum -a 256`.

**Tools of the image** (Go, k9s, actionlint, gitleaks, kind): `bash manage/scripts/ci/versions.sh --tools` prints one `tool pinned upstream` line per tool behind its upstream release (go.dev for Go, the latest GitHub release otherwise), nothing when all are up to date. A line ending with `majeure` is a new major version: it is never applied alone. `bash manage/scripts/ci/versions.sh --apply <tool> <version>` rewrites the version and recomputes both fingerprints from the arm64 and amd64 archives, nothing else in the Dockerfile; it is refused when an archive cannot be fetched, when go.dev publishes another checksum for it, or for a major version, unless `--major` is given.

**Automatic upgrades**: the versions of `repowarden` and of the AI assistants (`IA_CLAUDE`, `IA_OPENCODE`) are compared every hour with npm by the `versions` workflow (`.github/workflows/versions.yml`). For each outdated package, it opens or updates a ticket, proposes a design there (“Conception proposée”, *proposed design*), creates its branch, applies the upgrade (`manage/scripts/ci/versions.sh --appliquer`), commits and pushes: the draft PR opens and CI tests the container. The maintainer confirms the design on the ticket (“Conception retenue”, *retained design*, expected by the `ticket` check), then moves the PR to ready. One line per package: two upgrades open at the same time (Claude Code and opencode) are merged one after the other without conflict. By hand: *Actions → versions → Run workflow*; locally, `bash manage/scripts/ci/versions.sh` lists the outdated packages. Without a new version, the job stops after the comparison; there is no cross-trigger from repowarden, which would require a token from another owner.

The tools of the workspace image (Go, k9s, actionlint, gitleaks, kind: the `ARG` lines of the Dockerfile) follow the same flow, with one difference for now: the hourly run only lists them in the job summary; a manual run (*Actions → versions → Run workflow*) is the one that opens the ticket and the PR, until that path has been checked for real. `versions.sh --tools` compares them with their upstream release, `versions-tools-plan.sh` plans the bumps, and `versions.sh --apply <tool> <version>` replaces the version and both sha256 fingerprints, nothing else. At most 3 tools per run; the others wait for the next run. A next major version is never applied by the workflow: it is only listed in the job summary, and it is applied by hand with `--major`. Run the workflow with `dry_run` ticked to write nothing (no ticket, no branch, no push): the job summary then shows what would be done. The workflow itself can only be checked in CI, not on a dry run locally.

**Catching up without a rebuild**: the state shown at startup (and by `devzone`) compares the installed tools with their frozen version. A line `⚠ outils          repowarden 4.9.2 installé, 4.12.0 figé : devzone apply` signals a gap; `devzone apply` reinstalls repowarden at the frozen version and the active modules. `✔ outils          versions figées` indicates that everything matches. Tools installed by `apt` or by the image (Java, Node, Python, …) are not concerned.



## Keeping system packages

A package installed by hand (`sudo apt install tree`) is lost at the next rebuild. `devzone packages` maintains the list of packages to reinstall after a rebuild:

| Action | Command |
|---|---|
| List | `devzone packages`: ✔ installed packages, ○ packages to install |
| Add | `devzone packages add <name>…`: validates (`apt-cache`), installs, adds to the list |
| Remove | `devzone packages remove <name>`: removes it from the list and uninstalls |
| Apply | `devzone packages apply`: installs the missing packages |

The list is re-read at post-create, and the state of the packages not yet installed is shown in the summary (`⚠ paquets : …`). `devzone packages apply` can be run again.

## Machine output

Two commands display their state as a JSON object, for the VS Code extensions and other tools. The text output is not changed: add `--json` to the command of your choice.

- **Nothing to do, no secret**: each item to process has its ready-to-run `devzone` command (`command` field, `null` if nothing is to be done); no token, no password, never the content of the credentials (path only, through the `credentials` field).
- **Robust**: each section is computed separately. If one fails, its value is `null`, the `errors` field explains why, the JSON stays valid and the exit code is 0.
- **Stable and versioned**: field names are in English, without accents or spaces. Since #733, with no aliases: `nom`→`name`, `actif`→`active`, `etat`→`state`, `echec`→`failed`, `commande`→`command`, `outils`→`tools`, `plateforme`→`platform`, `disponible`→`available`, `identite_git`→`git_identity`, `identifiants`→`credentials`, `alertes`→`alerts`, `erreurs`→`errors`, `retards`→`outdated`, `paquet`/`figee`/`installee`→`package`/`frozen`/`installed`, `travail`→`work`, `travail_interne`→`internal_work`, `services_distant`→`services_remote`, `connecte`→`connected`. The fields `docker_hote` and `docker_hote_actif` are removed (#735). This renaming moves `schema` from 1 to 2: a reader written for `schema: 1` must be updated. Adding a field stays within `schema: 2`; removing or renaming a field moves `schema` to 3: base your reading on it.

`devzone status --json` (the full summary, section by section):

```json
{
  "schema": 2,
  "devzone": { "version": "0.22.0", "available": "0.23.0" },
  "git_identity": { "ok": true, "name": "…", "email": "…", "command": null },
  "platform": { "name": "github", "url": null,
                "github": { "connected": true, "workflow": true, "command": null } },
  "tools": { "outdated": [ { "package": "…", "frozen": "…", "installed": "…" } ], "command": "devzone apply" },
  "modules": [ { "name": "postgres", "active": true, "description": "…", "state": "ready on docker-desktop…",
                 "failed": null, "command": null } ],
  "clusters": { "services": "docker-desktop", "services_remote": false,
                "work": "docker-desktop", "internal_work": false, "command": null },
  "ports": [ { "port": 8080, "active": true, "application": "…" } ],
  "credentials": "/workspaces/devzone/.password",
  "alerts": [ { "code": "packages", "message": "…", "command": "devzone packages apply" } ],
  "errors": {}
}
```

The possible alerts are: `packages`, `worktree`, `cluster_distant` (services on a remote cluster), `cluster_interne` (devzone's working cluster; go back with `devzone use <your cluster>`).

`devzone agent state --json` (sessions, discards, modified rights), schema 2:

```json
{
  "schema": 2,
  "sessions": [ { "journal": "dz-337.log", "model": "beam-free", "start": "2026-11-06T13:17:33Z",
                  "last_written": "2026-11-06 13:20:14", "requested": null, "running": true } ],
  "exclusions": [ { "model": "crouton-alpha-free", "cause": "pays", "end": "2026-11-13T13:24:50Z" } ],
  "rights_alerts": [ "dz-361" ]
}
```

`running` is `true` when an agent session is still working on this folder. A discard (`quota`, `pays`, `muet`…) ends on the `end` date; a tool can then rerun the instruction with `devzone agent`.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `✖ Docker introuvable` (`npx devzone`, `make up`, `make rebuild`, `make uninstall`) | Docker is not installed | install Docker Desktop (macOS, Windows, Linux: https://docs.docker.com/desktop/) or, under Linux, Docker Engine (https://docs.docker.com/engine/install/), then rerun the command |
| `✖ Docker est installé mais ne répond pas (arrêté ?)` | Docker Desktop closed, or the Docker service stopped (Linux) | start Docker Desktop (Linux without Docker Desktop: `sudo systemctl start docker`), then rerun the command. After `npx devzone mon-devzone`, the folder is already created: `cd mon-devzone && make shell` |
| `✖ Docker refuse l'accès` | Linux: account outside the `docker` group | `sudo usermod -aG docker $USER`, then a new session (or `newgrp docker`), then rerun the command |
| `make up` or `make rebuild` seems frozen | a long step (first image build: several minutes), or a question asked in the container | `make` shows a sign of life with the last log line at least every 30 s: follow the detail with `tail -f .devzone.log`. A question (line ending with `[y/N]`, `?`…) is reported and the launch stops: [report it](https://github.com/SimBienvenueHoulBoumi/devzone/issues), then `make rebuild`. Earlier devzone version, frozen on “Configurer les bots … ? [o/N]” (invisible): `Ctrl+C`, update devzone, then `make rebuild`; the bots are configured by hand in the container: `repowarden bots` |
| `git push` refused: “refusing to allow an OAuth App to create or update workflow … without `workflow` scope” | `gh` token without the `workflow` permission | `gh auth refresh -h github.com -s workflow` |
| `devzone` shows `⚠ worktree … absent ici`; or a broken worktree (“not a git repository: …/.git/worktrees/…”) | worktree created on the other side (host ↔ container), or metadata erased by a `git worktree prune` run on the other side | see [Git worktrees](#git-worktrees): manage each worktree on the side that created it, never `git worktree prune` on the host |
| PR blocked, run `action_required`, banner “Approve workflows to run” | PR opened or pushed by the `github-actions` bot: for `pull_request` events `opened`, `synchronize` and `reopened`, GitHub waits for the approval of a person with write access ([GitHub doc](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow)) | check the changes (especially `.github/workflows/`), then *Approve workflows to run*; to stop having to do this: `repowarden app init` in the project |
| Delivery PR blocked: `aucune préversion vX.Y.Z-next.N` (*no preview*) | the preview is not published yet (without `preversion-on-push`, it goes out in the evening) | wait for the evening one, *Actions → release → Run workflow* on `develop`, `preversion-on-push: true`, or stop requiring it: `preversion-obligatoire: false` |
| Delivery PR left open | a red check (see the PR), `delivery-auto: false`, or the GitHub App absent or uninstalled (warning in the `release` run) | fix the check; install the App (`repowarden app init` on your machine) |
| `repowarden app init` from `make shell`: the page `http://127.0.0.1:…` does not open, or GitHub does not come back | the page is served in the container, unreachable from your machine's browser | run the command **on your machine**: `npx -y repowarden app init --repo <account>/<repo>` |
| `repowarden app init`: `nom déjà utilisé` (*name already used*) | a previous attempt created the App without retrieving its credentials | delete the orphan App (*GitHub → Settings → Developer settings → GitHub Apps*), or use `--nom <other-name>` |
| `git commit`: “Please tell me who you are” | git identity missing | with GitHub: `gh auth login -s workflow` then `devzone start`; without GitHub: `git config --file ~/.config/git/config user.name "<name>"` and `user.email "<email>"` |
| `gh auth login`: “Press Enter to open … in your browser”, nothing opens | no browser in the container (`make shell`) | open https://github.com/login/device by hand and enter the code |
| `k9s`: `Error: exit status 1` then its help; `kubectl`: `localhost:8080` … `connection refused` | no active cluster (`kubernetes` module disabled, or no cluster on your machine) | `devzone enable kubernetes` (your machine's cluster), `kind create cluster`, or `devzone use <name>` |
| `claude` or `opencode`: “command not found” | `ia` module disabled | `devzone enable ia` |
| `devzone` shows `✖ module ia         en échec : installation incomplète (journal npm : …)` | installation of Claude Code or opencode failed (network, package); the failure message names the packages and the npm log | read the cited log, then `devzone apply` to retry (or `devzone disable ia`) |
| `devzone enable ia` or `devzone apply` shows nothing new for several minutes | installation of Claude Code and opencode (several hundred MB): announced, then a line `… toujours en cours (N s)` every 30 s | wait for the line `Claude Code et opencode installés` or the failure message |
| Empty CPU and RAM in k9s | metrics-server absent from the cluster | `devzone metrics` |
| Two devzone containers | `make up` run while VS Code was opening the container | `make down`, then a single launch |
| Windows (Git Bash, MSYS): `~/.kube` not found | `HOME` and `USERPROFILE` concatenated in the mounted path | launch from VS Code or PowerShell |
| No `~/.kube` on the host | Docker creates it empty at startup (under Linux with Docker Engine, it belongs to root) | nothing to do: the container starts anyway |

### Resuming the test container build (#685)

The `fonctionnel` job builds the container with the devcontainers CLI. SDKMAN (Java, Maven) sometimes serves a corrupt archive (“Stop! The archive was corrupt”): its 5 attempts then fall into the same failure, and the build fails for reasons unrelated to the code (observed twice, #661 and run 44596691628).

`build_with_retry` (`manage/test/journal-error.sh`, used by `manage/test/functional.sh`) redoes the build **only once** when the new part of the log contains this pattern, **after a pause** of 120 s (adjustable with `BUILD_RETRY_WAIT`): an immediate retry fell back into the same failure of the download server (run 44612039534, two corrupt builds 75 s apart). The message (“one retry of the build in 120s”) and a log line say so. Another failure is never retried, and an identical second failure makes the job fail: a real problem is not hidden. A pattern left in the log of an earlier launch does not count.

### Automatic CI rerun (#656)

The `bats (macos-latest)` job sometimes gets no runner: it stays queued for about fifteen minutes, then is cancelled without a single step (“never started”), and `tests-conteneur` then fails, deliberately (#522). The workflow `.github/workflows/relance-ci.yml` reruns this case **only once**, without intervention.

- **Trigger**: the `fonctionnel` run ends in failure (`workflow_run`).
- **Decision** (`bash manage/test/ci-container.sh relancer <repo> <run> <attempt>`): rerun (`gh run rerun --failed`) only if at least one job never started (cancelled, without runner, without step) **and** no other job, except `tests-conteneur`, failed, expired or was cancelled during its run. A real test failure is never hidden, nor a job cancelled by a more recent run.
- **A single rerun**: the workflow only runs at attempt 1; the rerun is attempt 2, so there is no loop. The job log says what was decided.
- **Minimal rights**: `actions: write` on this workflow alone. It fetches the default branch (never the PR's code) and only uses the run identifier.
- **Limit**: a `workflow_run` workflow only runs from the default branch: it acts only after the first delivery that contains it in `main`. The repowarden repository has the same default, to be handled there.
- **Disabling**: delete the file, or “Disable workflow” in the GitHub Actions tab. The diagnosis of `tests-conteneur` (#636) keeps indicating the manual rerun command.

## Removed names

The commands, subcommands and options of devzone are written in English (#502, #557, #695). The old French names are no longer accepted, neither as aliases nor with a warning: devzone refuses the old name, shows the new one on the error output, exits with code 1 and does nothing (no folder is created):

```
✖ « activer » a été renommé : devzone enable
✖ « liste » a été renommé : devzone port list
✖ « --oui » a été renommé : --yes
```

### Commands

| Old name | New name |
|---|---|
| `devzone actif` | `devzone is-enabled` |
| `devzone activer` / `desactiver` | `devzone enable` / `disable` |
| `devzone appliquer` | `devzone apply` |
| `devzone aide` | `devzone help` |
| `devzone catalogue` | `devzone catalog` |
| `devzone demarrer` / `arreter` / `etat` | `devzone start` / `stop` / `status` |
| `devzone ia` | `devzone ai` |
| `devzone mots-de-passe` | `devzone passwords` |
| `devzone paquets` | `devzone packages` |
| `devzone plateforme` | `devzone platform` |
| `devzone reparer` | `devzone repair` |
| `devzone utiliser` | `devzone use` |
| `devzone mettre-a-jour` / `desinstaller` | `devzone update` / `uninstall` |
| `devzone workspace demarrer` / `arreter` / `etat` | `devzone workspace start` / `stop` / `status` |
| `devzone workspace copier-vers` / `copier-depuis` | `devzone workspace copy-to` / `copy-from` |
| `devzone workspace aide` | `devzone workspace help` |
| `devzone workspace ports demarrer` / `arreter` / `etat` | `devzone workspace ports start` / `stop` / `status` |

### Subcommands

| Command | Old name | New name |
|---|---|---|
| `postgres`, `mysql` | `creer`, `liste`, `supprimer`, `supprimer-donnees`, `etat`, `installer`, `desinstaller` | `create`, `list`, `delete`, `delete-data`, `status`, `install`, `uninstall` |
| `postgres`, `mysql` | `autoriser`, `interdire` | `authorize`, `forbid` |
| `gitlab` | `migrer`, `nouveau-mdp`, `etat`, `installer`, `desinstaller`, `relais-etat` | `migrate`, `new-password`, `status`, `install`, `uninstall`, `relay-status` |
| `argocd` | `etat`, `installer`, `desinstaller` | `status`, `install`, `uninstall` |
| `postgres`, `mysql`, `gitlab`, `argocd` | `relais-lancer`, `relais-arreter` | `relay-start`, `relay-stop` |
| `packages` | `ajouter`, `retirer`, `appliquer`, `lister` | `add`, `remove`, `apply`, `list` |
| `catalog` | `lister`, `synchroniser`, `appliquer`, `desinstaller` | `list`, `sync`, `apply`, `remove` |
| `port` | `ouvrir`, `fermer`, `liste`, `relancer`, `exclure`, `inclure` | `open`, `close`, `list`, `restart`, `exclude`, `include` |

### Options

| Old | New |
|---|---|
| `--oui` | `--yes` (everywhere: `disable <module> --yes` confirms the deletion of the data) |
| `--contexte` | `--context` |
| `--confirmer` | `--confirm` |
| `--nouveau-mdp` | `--new-password` |
| `--fermer` | `--close` |
| `--supprimer` (`mysql volume`) | `--delete` |

The following environment variables are not commands: they are not covered by this refusal.

| Old | New |
|---|---|
| `conseil` | `advice` |
| `GARDER=connexions` | `KEEP=logins` |
| `CONFIRMER=oui` | `CONFIRM=yes` |

## For contributors

The application commands (`devzone repair`, `start`, `metrics`, `use`) replace the direct scripts for the user. The internal scripts remain callable during development and by the tests:

```bash
bash .devcontainer/startup.sh
bash .devcontainer/metrics-server.sh
```

The tests isolate Kubernetes (`kube_isole` of `manage/test/commun.bash`: `HOME`, `KUBECONFIG` and `DEVZONE_KUBE_HOST` under the test's temporary folder). `cluster.sh` accepts `--confirm CTX` and keeps `DEVZONE_CLUSTER_REMOTE=<context>` for the tests and the CI. A direct context change (`kubectl config use-context CTX`) should only be done in an isolated test. The volume isolation uses `DEVZONE_VOLUMES=<prefix>`. `DEVZONE_NO_START=1` makes `devzone <folder>` create the folder without launching the workspace (the command is displayed): this is the mode used by the tests and the CI.
