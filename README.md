# devzone

[![npm](https://img.shields.io/npm/v/devzone)](https://www.npmjs.com/package/devzone) [![License GPL-3.0-only](https://img.shields.io/badge/licence-GPL--3.0--only-blue)](https://github.com/SimBienvenueHoulBoumi/devzone/blob/main/LICENSE)

Your Linux development workstation, ready in one command, identical on Mac, Windows and Linux.

- An identical Ubuntu for the whole team.
- Tools and services ready: Java, Node, Python, Docker, Kubernetes, PostgreSQL, GitLab when needed.
- AI agents supervised by repowarden.
- Local and free: nothing is hosted.
- An update with `devzone update`, and added tools that survive the rebuild (devzone packages).

## Why devzone?

Each alternative has its limits:

- **WSL**: Windows only, and specific to each workstation.
- **Virtual machine**: heavy, slow to start.
- **Hosted environments** (Codespaces, Gitpod…): cloud, quotas, network.

devzone avoids them: the same environment on every workstation, on your machine.

## Limits

- No systemd: the services provided by devzone start with devzone, not with `systemctl`.
- No graphical desktop: everything happens in a terminal or in VS Code.
- The terminal keeps the cluster administrator; agents only have the account limited to the `devzone-*` namespaces (`edit` role, token renewed every 24 h). Only the installers act as administrator ([#430](https://github.com/SimBienvenueHoulBoumi/devzone/issues/430)).

## How it works

devzone prepares an Ubuntu environment with pinned tool versions, and runs it in one of these two places:

- **inside the Kubernetes cluster** of your machine, by default, as soon as a cluster answers at creation: the workstation is a pod `devzone-workspace-0` (namespace `devzone-workspace`);
Nothing is hosted: everything runs on your machine. `workspace/` is kept across rebuilds, and the projects of the workstation stay in the pod's volume. The mode of each workstation is written in `.devzone.modules` (`workspace=kubernetes`); the details are in the [reference](manage/docs/reference.md#kubernetes-workspace).

## Quick start

### Prerequisites

- **Kubernetes (default mode)**: a Kubernetes 1.30 or newer cluster that answers, with `kubectl` and `helm` on the machine. On Mac and Windows, the simplest is the Docker Desktop cluster: *Settings → Kubernetes → Enable Kubernetes*. devzone itself does not need Docker in this mode, but the Docker Desktop cluster stops with Docker Desktop (if the cluster does not answer, see [Frequently asked questions](#frequently-asked-questions)). Details in the [Kubernetes workspace](manage/docs/reference.md#kubernetes-workspace).
- Node and npm (for `npx` or the global installation).
- `make` (needed for `make shell`; on Windows without `make`, see the table “Day to day”).

On Windows: it is recommended to clone with Git for Windows (the scripts keep LF line endings thanks to `.gitattributes`, and the npm command finds the `bash` it requires).

The npm package ships a compiled `devzone` binary for Linux, macOS and Windows (amd64 and arm64): the command runs in Go when a binary exists for your platform, and in bash otherwise.

#### Minimum memory per module

Measurements from 16/11/2026.

| Module | Measured consumption | Allocatable memory required by devzone |
|---|---|---|
| Base cluster | ~4 GB | none |
| GitLab | ~3.6 GB | 8 GB |
| MySQL | ~0.5 GB | none |
| Argo CD | ~0.6 GB | 1 GB |

On Docker Desktop (kind), the check compares the minimum with the memory of a single node, so with the VM; on a cluster of real machines, with the sum of the nodes.

- **Adjusting the RAM**:
  - **Mac** (Docker Desktop): *Settings → Resources > Memory*. Other method: change `MemoryMiB` in Docker Desktop's `settings-store.json` file (Docker fully quit otherwise, it rewrites the value).
  - **Windows**: file `%UserProfile%\.wslconfig` with `[wsl2]` and `memory=<N>GB`, then `wsl --shutdown`. WSL2 takes 50 % of the RAM by default.
  - **Linux**: nothing to adjust: there is no VM, the host's RAM is used.

### Launch in one command

Two ways via npm. Without installation, on each use:

```bash
npx devzone mon-devzone
cd mon-devzone
make shell
```

You can also install it once and for all:

```bash
npm install -g devzone
devzone --version
devzone --help
devzone mon-devzone
cd mon-devzone
make shell
```

With a GitHub account, the option `--gitops <github|none|<url>>` sets up the GitOps repository as soon as the folder is created:

```bash
npx devzone mon-devzone --gitops github
```

Or fetch the code directly:

```bash
git clone https://github.com/SimBienvenueHoulBoumi/devzone.git
cd devzone
make shell
```

You can also use VS Code: open the `mon-devzone` (or `devzone`) folder, then *Dev Containers: Reopen in Container*.

At each startup, a summary tells you what is ready or what remains to be done. Its labels are in English, and `devzone` shows it again on request. Extract, without a git identity configured:

```text
devzone: state (devzone to show it again)
  ✖ git identity    needed to commit: gh auth login -s workflow (automatic),
                    ou git config --file ~/.config/git/config user.name "<nom>" et user.email "<email>"
  ✔ plateforme     github
  ✔ GitHub          connecté
  ○ module ai         optional, assistants IA : Claude Code, opencode: devzone enable ai
  ○ module kubernetes optional, connexion au cluster de l'hôte et metrics-server au démarrage: devzone enable kubernetes
  ○ module gitlab     optional, GitLab de test dans le cluster des services: devzone enable gitlab
```

A line `○ GitHub … optional` replaces `✔ GitHub connecté` as long as `gh` is not connected. The full list of commands is in `devzone --help`.

The first launch takes 4 to 5 min as measured, plus the download of the base images on a new machine.

### A cluster at creation

At creation, devzone needs a Kubernetes cluster that answers.

```text
devzone mon-devzone
  │
  ├─ cluster answers ─────▶ workspace in the cluster (Kubernetes)
  │                         make shell opens the pod
  │
  └─ otherwise ───────────▶ nothing is created: devzone lists the ways
                            to get a cluster, then you rerun
```

Without a cluster, in a terminal, devzone offers to choose a remote cluster (a context of your kubeconfig, whose name you retype to confirm) or to create a minikube; without a terminal, it stops and shows commands to copy (it never runs them, and no cloud credential passes through it): a remote cluster (`aws eks update-kubeconfig`, `gcloud container clusters get-credentials`, `az aks get-credentials`, which declare it in your kubeconfig; make it the current kubectl context), or a local cluster (Docker Desktop: *Settings → Kubernetes → Enable Kubernetes*, or `minikube start -p devzone`). Details in [manage/docs/reference.md](manage/docs/reference.md#direct-creation-in-the-cluster).

### Check that everything works

```bash
java -version
node -v
python3 --version
repowarden --version
```

With an active Kubernetes cluster: `kubectl get nodes`.

**Optional step**: `gh auth login -s workflow` to enable GitHub (push, PR and repowarden tickets).

## Your first project

Your projects go into `workspace/` (kept on your machine, even after `make down` or `make rebuild`).

Example:
```bash
cd workspace
git clone https://github.com/ton-compte/ton-projet.git
# or
mkdir mon-projet && cd mon-projet && git init -b main
```

To learn more: [Starting a project](https://github.com/SimBienvenueHoulBoumi/devzone/blob/main/manage/docs/reference.md#starting-a-project).

## What devzone contains

| Area | Tools |
|---|---|
| Languages | Java 21 + Maven + Gradle, Node LTS + pnpm, Go 1.27.4, Python 3.12 (apt) + uv |
| Containers, Kubernetes | Host Docker (shared socket), kubectl, helm, k9s, kind; connection to the host cluster (`kubernetes` module); Testcontainers (`TESTCONTAINERS_HOST_OVERRIDE`); mounts (`$LOCAL_WORKSPACE_FOLDER`) |
| GitHub (or GitLab), quality | gh, or glab connected to a GitLab instance (`devzone platform gitlab` in the container, [manage/docs/reference.md](manage/docs/reference.md#platform-github-or-gitlab)); repowarden (global git hooks), shellcheck, bats, actionlint, gitleaks, ruff, vulture, pytest |
| AI assistants | Claude Code, opencode (`ai` module, disabled by default) |

## Installing a tool that stays

A tool installed by hand (`sudo apt install tree`) does not survive a `make rebuild`: the image is rebuilt from scratch. For a tool that must stay, `devzone packages` keeps the list of packages to reinstall:

```sh
devzone packages
devzone packages add tree
devzone packages remove tree
devzone packages apply
```

- `devzone packages` shows the list: ✔ installed packages, ○ packages to install;
- `devzone packages add <nom>…` validates each package (apt-cache), installs it, then adds it to the list;
- `devzone packages remove <nom>` removes it from the list and uninstalls it;
- `devzone packages apply` installs the missing packages after a rebuild.

The list lives in `.devzone.packages` at the root of the devzone folder, outside the repository. A package that fails is reported in the summary (⚠ packages: …); `devzone packages apply` can then be run again.

## Day to day

| Action | VS Code (`Cmd+Shift+P`) | `make` | Without `make` (Windows) |
|---|---|---|---|
| Launch | *Dev Containers: Reopen in Container* | `make up` | `npx @devcontainers/cli up --workspace-folder .` |
| Open a shell | VS Code terminal | `make shell` | `npx @devcontainers/cli exec --workspace-folder . bash` |
| Stop | *Remote: Close Remote Connection* (the container stops with the window) | `make stop` | — |
| Remove the container | — | `make down` | — |
| Rebuild (after a change to `.devcontainer/`) | *Dev Containers: Rebuild Container* | `make rebuild` | `npx @devcontainers/cli up --workspace-folder . --remove-existing-container` |
| Status | — | `make status` | — |
| **Uninstall** (everything devzone created, after confirmation) | — | `make uninstall` | `npx devzone uninstall` |

In Kubernetes mode (workstation created while the cluster was answering), the same table applies to the pod `devzone-workspace-0`: `make up`, `make shell` and `make stop` control it, and `make rebuild` is refused, because nothing needs rebuilding on the machine. The GitLab, PostgreSQL and Argo CD services are installed from the workstation: `devzone workspace services enable postgres` (see [the reference](manage/docs/reference.md#devzone-services-in-the-kubernetes-workspace)). You can also develop there: `devzone workspace clone <url>` makes a working clone in the pod, `devzone ticket <n>` creates the worktree of a ticket there and `devzone agent` launches opencode there without a copy ([developing in the pod](manage/docs/reference.md#developing-devzone-and-repowarden-in-the-pod)). Argo CD is installed by default there and keeps the deployments: interface at https://localhost:8443 (password `admin` in `.password`), GitOps repository `<login>/devzone-argocd` created on your GitHub, projects declared in `.argocd.conf` (`devzone workspace argocd app add <repo>`); see [Argo CD in the Kubernetes workspace](manage/docs/reference.md#argo-cd-in-the-kubernetes-workspace).

In the container, `devzone --version` shows the version of the workspace image, and `devzone --help` lists all the commands. Extract:

```text
  devzone enable <module>                  enable and apply at once
  devzone use CTX [--confirm CTX]          switch the kubectl working cluster
  devzone port [<n>|--close <n>]           relay of a container port to the workstation
```

### Updating devzone

At creation, the folder keeps its version in `.devzone.version`: the version, then the sha256 fingerprint of each file copied from the package. To bring an existing folder to the package version:

```bash
cd mon-devzone
devzone update
```

For the latest published version, without a global installation:

```bash
cd mon-devzone
npx devzone@latest update
```

The command shows the folder's version and the package's, and does nothing if they are equal. Otherwise, it backs up the replaced or deleted files to `.devzone.backup/<date>/`, lists the locally modified files and asks for confirmation (`--yes` for a script; without a terminal, `--yes` is required), replaces the package files, removes the old trees (`core/`, `scripts/`), completes `.gitignore` without overwriting it, then proposes `make rebuild`. `--no-rebuild` skips this proposal; without a terminal, the rebuild is never launched.

`workspace/`, `.devzone.modules`, `.devzone.packages`, `.password`, `.app`, `.devzone.log` and the Docker volumes are never touched.

The old names of files and folders (`.devzone.paquets`, `.devzone.sauvegarde`, `.devzone.ports-workspace`, `.devzone.etat`, `.devzone.catalogue-veilleur`) are renamed once only, with their contents, by `.devcontainer/rename-legacy-files.sh`: at container startup and at update. A new name already present is never overwritten.

The Kubernetes workspace is updated separately: `devzone workspace update` moves it to the latest stable release (or `--version X.Y.Z`), image, charts and Argo CD at the same tag. **The pod `devzone-workspace-0` is recreated**: the VS Code windows attached to the pod are disconnected. The image is checked on ghcr.io before any write, and nothing changes if it does not exist yet. Details in the [reference](manage/docs/reference.md#updating-the-workspace).

In the container, the `devzone` summary reports a more recent published version (npm check at most once a day, without blocking offline): `○ devzone X.Y.Z disponible : sur le poste, devzone update`.

## Options

**Mode at creation**: `--kubernetes` (workspace in the cluster, refused without a cluster). Without an option, the cluster must answer, otherwise nothing is created (see [A cluster at creation](#a-cluster-at-creation)).

**`ai` module**: enables Claude Code and opencode (pinned versions), with the repowarden guard that stops them before they modify `main` or `develop` or commit without `repowarden cc` (see [manage/docs/reference.md](manage/docs/reference.md#ai-assistants-guard)). To enable it: `devzone enable ai`. They are uninstalled when the module is disabled, but your logins stay in their volumes. The module also sets up a guard that stops the `docker` commands of agents: devzone is Kubernetes first, only pods are containers (`kubectl`, or a disposable pod, instead).

**Models on your computer**: devzone hosts no model. If Ollama runs on your machine, `devzone enable ai` detects its models and connects them to opencode (nothing is installed or downloaded). `devzone ai` lists them with the default model, `devzone ai check` says whether each one is up to date without downloading anything, and `devzone ai rapport` details the selected model and why (the `DEVZONE_HOST_MODEL` variable, a measurement, or the rule “a code model first, then the smallest”). Details in [manage/docs/reference.md](manage/docs/reference.md#opencode-configuration). The `llm` module (model hosted in the cluster) has been removed: devzone hosts no model.

**`kubernetes` module**: enables, at each startup, the connection to the host cluster and the installation of metrics-server on local clusters (to see CPU and RAM in k9s). To enable it: `devzone enable kubernetes`. Without this module, kubectl, helm, k9s and kind remain installed.

**GitHub or GitLab platform**: GitHub by default (new architecture). To serve a team on GitLab: `devzone platform gitlab --url URL` (or without `--url` when the `gitlab` module is enabled, for the test instance): glab is installed (pinned version, checksum verified) and connected to the instance, and `devzone` shows it instead of the `gh` checks. `devzone platform github` goes back (glab removed). GitLab is reachable directly from the workstation without a temporary relay. Details in [manage/docs/reference.md](manage/docs/reference.md#platform-github-or-gitlab).

**`postgres` module**: a shared PostgreSQL, one database per project (see [Connecting to PostgreSQL](#connecting-to-postgresql)). To enable it: `devzone enable postgres`.

**`argocd` module**: Argo CD on the devzone cluster, interface at https://127.0.0.1:8443 in the container (see [Argo CD](manage/docs/reference.md#argo-cd)). To enable it: `devzone enable argocd`.

**`devzone agent --pod` option**: launches an agent session in an isolated disposable pod (ticket #222). The pod is created with limited resources (2 CPU, 4 Gi memory), restricted mounts of the workspace and the state, and a mandatory affinity to the workspace pod. It isolates: the ticket's worktree at the same path as in the workspace, the repository's `.git`, and state subfolders (.config/opencode, .local/share/opencode, .local/state/oc-lancer, .local/npm read-only). It does NOT isolate: the network (unfiltered, that is #220), the host kubeconfig, `~/.config/gh`, `~/.claude`, the other worktrees, and, since the repository's `.git` is mounted, the git references of the other branches remain readable and writable there. Without `--pod`, the current `devzone agent` behavior is strictly unchanged.

These modules are disabled by default, can be enabled on demand from the container (without a rebuild), and their choice is kept from one startup to the next.

The `devzone` command is written in English, subcommands and options included (`enable`, `disable`, `platform`, `packages`, `update`, `uninstall`, `status`, `use`; `postgres create`, `packages add`, `gitlab new-password`, `port --close`, `cluster --yes`). The old French names are refused with the new name; the full table is in [Removed names](manage/docs/reference.md#removed-names).

## Where are my credentials?

The accounts created by devzone are grouped in `.password`, at the root of devzone (next to `.devzone.modules`). One line per account, columns separated by tabs:

```text
# service	address	user	password
gitlab	http://gitlab.localhost:8929	root	…
postgres	127.0.0.1:5432	postgres	…
postgres:monprojet	127.0.0.1:5432/monprojet	monprojet	…
argocd	https://127.0.0.1:8443	admin	…
```

The file is readable by you only (600) and ignored by git: never copy it or commit it. It is regenerated at each creation, deletion or change of account (`gitlab`, `postgres` and `argocd` modules, GitLab seed, startup):

```sh
devzone passwords                  # regenerates the file and only shows its path
devzone postgres create <projet>         # creation, or new password with --new-password
devzone postgres delete <projet>     # deletion of the account and its line
devzone gitlab new-password [root|dev]  # random password (root or dev) regenerated
```

The module files remain the source: `workspace/.postgres/<projet>.env`, `workspace/.postgres/admin-password`, `workspace/.gitlab/root-password`, `workspace/.gitlab/dev-password` and `workspace/.argocd/admin.env`.

The GitLab Rails secret is kept in `workspace/.gitlab/rails-secret.yaml` (600) and reapplied on a reinstallation; failing that, if the secret was lost, the summary warns: “GitLab reinstalled: if the browser shows 422, delete the site data of gitlab.localhost”.

## Connecting to PostgreSQL

The `postgres` module installs a shared PostgreSQL 16 on the devzone cluster: one database and one user per project. All commands are run in the container (`make shell`).

```sh
devzone enable postgres          # the first time: choice of the cluster (dedicated kind or host cluster)
devzone postgres create monprojet  # database and user "monprojet"
```

The credentials are written to `workspace/.postgres/monprojet.env` (readable by you only, never committed):

```text
DB_HOST=127.0.0.1
DB_PORT=5432
DB_NAME=monprojet
DB_USER=monprojet
DB_PASSWORD=…
DB_URL=jdbc:postgresql://127.0.0.1:5432/monprojet
```

PostgreSQL is reachable on `127.0.0.1:5432` from the container. Spring Boot example (`application.yaml` of a project stored in `workspace/<dossier>/<projet>/`):

```yaml
spring:
  config:
    import: optional:file:../../.postgres/monprojet.env[.properties]
  datasource:
    url: ${DB_URL}
    username: ${DB_USER}
    password: ${DB_PASSWORD}
```

Other commands: `devzone postgres list`, `devzone postgres psql monprojet` (console), `devzone postgres delete monprojet`, `devzone cluster [CTX]` (to see or change the cluster). Details in [manage/docs/reference.md](manage/docs/reference.md#postgresql).

### Viewing the database contents

In the container:

```sh
devzone postgres list              # the databases and their owner
devzone postgres psql monprojet     # SQL console connected to the database "monprojet", with its user
```

In the console (`\q` to exit):

| Command | Shows |
|---|---|
| `\conninfo` | the database and user of the connection |
| `\dt` | the tables of the database |
| `\d task` | the structure of a table: columns, types, indexes, keys |
| `\dn` | the schemas |
| `SELECT * FROM task LIMIT 10;` | the first rows of a table |
| `SELECT * FROM flyway_schema_history;` | the Flyway migrations applied (if the project uses Flyway) |

`devzone postgres psql`, without a project name, opens the console as the `postgres` superuser: all databases (`\l`), all users (`\du`). Reserve it for administration: a mistake there touches the databases of all projects.

### Connecting from the workstation (IntelliJ, DBeaver, psql)

devzone's relay makes PostgreSQL reachable **inside the container** only (pending [#292](https://github.com/SimBienvenueHoulBoumi/devzone/issues/292)). For a client installed on the workstation, open a tunnel in a **workstation** terminal (the Mac Terminal, not the container's one), and leave it open:

```sh
kubectl --context docker-desktop -n devzone-postgres port-forward svc/postgres 5432:5432
```

(`docker-desktop`: the host's Kubernetes, devzone's by default; `15432:5432` if a local PostgreSQL already occupies port 5432 of the workstation.)

Then, in the client, a PostgreSQL connection: host `localhost`, port `5432`, database, user and password read in `workspace/.postgres/monprojet.env` (`DB_NAME`, `DB_USER`, `DB_PASSWORD`). In IntelliJ: *View → Tool Windows → Database → + → Data Source → PostgreSQL*, then *Test Connection* (Database window: IntelliJ Ultimate; *Database Navigator* plugin otherwise).

“Connection refused”: the tunnel is not running, or it was started in the container. A database recreated (`devzone postgres delete` then `create`, or `create --new-password`) has a new password: update it in the client.

### Rights: one user per database

A project's user owns **its** database (it creates tables, indexes, data in it) and nothing else: it cannot create a database, nor connect to another project's. Hence, in a client, `[42501] ERROR: permission denied to create database`. This is intended (projects do not see each other). For a new database: `devzone postgres create <projet>`, which gives it its own user and its `.env` file.

> The `gitlab` module also has its own PostgreSQL (`gitlab-postgresql`): it belongs to GitLab, do not put your databases in it.

## See my application in the browser

On the Kubernetes workstation, `devzone workspace start` starts a port watcher: each TCP port ≥ 1024 that listens in the pod is relayed to `127.0.0.1` of the workstation, at the same number, by `kubectl port-forward`. A server started in the pod (`npm run dev`, port 5173) therefore answers at `http://localhost:5173`, without a command. The enabled services (PostgreSQL, MySQL, Argo CD) are relayed too, on their usual port. The Services of applications deployed in the cluster are relayed the same way, each on a local port (80 → 8080; a port already taken elsewhere becomes another port): `devzone workspace ports status` shows their URL `http://127.0.0.1:<port>`. A Service can be excluded with the annotation `devzone.io/relay: "false"`. The watcher is driven with `devzone workspace ports start|stop|status`; details in the [reference](manage/docs/reference.md#applications-and-services-on-the-workstations-localhost).

On the Docker workstation, an application launched **inside** the container (for example a Spring Boot with `./gradlew bootRun` on port 8080) is not reachable from the workstation: the devzone container publishes no port. As soon as it listens in the container, the **automatic port watcher** (`.devcontainer/ports-auto.sh`) sets up an `alpine/socat` relay (pinned version) on the host's Docker, from `127.0.0.1:<port>` of the workstation to the container's port: `http://localhost:<port>` **without a command**. The relay disappears when the application stops.

```sh
devzone port             # list: manual and automatic relays, ● active or ○ stopped
devzone port auto off    # stops the watcher: no more automatic relay
devzone port --close <n> # removes a manual relay and its port from the state
```

`devzone port <n>` also opens a manual relay: same mechanism on the workstation side, `alpine/socat` container, name `devzone-<instance>-port-<n>`.

From the workstation: `http://localhost:8080`. The manual relay is recreated automatically at container startup, toward the container's current address; it is removed by `make uninstall` (label `devzone.instance`). The automatic relay disappears with the application.

Spring Boot listens on `0.0.0.0` by default: do not set `server.address` to `127.0.0.1`, otherwise the relay cannot reach the application. A port already taken on the workstation, an invalid port or an unreachable host Docker are refused with a non-zero exit code. Details in [manage/docs/reference.md](manage/docs/reference.md#ports-to-the-workstation).

## Frequently asked questions

- **Docker absent or stopped**: `npx devzone`, `make up`, `make rebuild` and `make uninstall` check Docker first and tell you what to do: install it (Docker Desktop, or Docker Engine on Linux), start Docker Desktop, or, on Linux, add your account to the `docker` group (`sudo usermod -aG docker $USER`, then a new session). With `npx devzone mon-devzone`, the folder is created anyway: once Docker is started, `cd mon-devzone && make shell`.
- **Access to the host's Docker socket**: the host machine's Docker socket is mounted in the container. This grants administrator access to the host's Docker, including for AI agents. It is a deliberate security trade-off documented in the Limits section. To restrict access, use the mechanisms specific to Docker Desktop/Linux.
- **The first launch is long**: this is normal (building the image, downloading the base images). It takes 4 to 5 min as measured, plus the download of the base images on a new machine.
- **`make` is missing on Windows**: you can use `npx @devcontainers/cli` (see the table “Day to day”) or Git Bash. The scripts are compatible (LF line endings).
- **The Kubernetes cluster does not answer**: devzone never creates a cluster. At creation, without a cluster that answers (within 5 s), nothing is created: the command fails (code 1), says why and lists the ways to get a cluster (see [A cluster at creation](#a-cluster-at-creation)):

  ```text
  ✖ Kubernetes not reachable: cluster <contexte> unreachable (<serveur>). Nothing created.
  ```

  `devzone workspace start` (so `make up` and `make shell`) checks the cluster first and stops without changing anything. The message gives the cause:

  - **Docker Desktop stopped**: `✖ Docker Desktop is stopped: the Kubernetes cluster of this machine runs inside it. Start Docker Desktop, then: make shell`. Start Docker Desktop, then `make shell`. To have it start at each login: *Settings → General → Start Docker Desktop when you sign in*.
  - **Docker answers, not the cluster**: `✖ Kubernetes cluster <contexte> unreachable (<serveur>): enable Kubernetes in Docker Desktop (Settings → Kubernetes) or check kubectl config get-contexts`. Enable Kubernetes in Docker Desktop (*Settings → Kubernetes → Enable Kubernetes*).
  - **Other cluster**: `✖ Kubernetes cluster <contexte> unreachable (<serveur>)`, followed by `Check the contexts: kubectl config get-contexts`. Check the chosen context, or change it with `devzone use CTX`.

  Details in the [reference](manage/docs/reference.md#the-cluster-does-not-answer).
- **Git identity problem when committing**: set it once. With GitHub: `gh auth login -s workflow` (the identity is deduced automatically). Without GitHub: `git config --file ~/.config/git/config user.name "<nom>"` and `git config --file ~/.config/git/config user.email "<email>"`.
- **`make up` seems stuck**: it shows its steps and a sign of life at least every 30 s; the full log is in `.devzone.log`.

## Changing cluster

```sh
devzone clusters                    # view: contexts, type, state, namespace
devzone use CTX [-n NS]        # switches the kubectl working cluster
devzone use -n NS              # changes only the namespace of the current cluster
```

The shell prompt shows `⎈ ctx/ns` (cyan if local, bold red if remote otherwise). A rebuild restarts on the host's cluster: the kubectl choice is written to `~/.kube/config`, which is not in a volume.

## Uninstalling

```bash
make uninstall
```

This command removes the container, the image `vsc-devzone-…`, the `devzone-*` volumes, the events of the host's Docker and the kind clusters created on the host, the `devzone-postgres` namespaces and the `app.kubernetes.io/managed-by=devzone` labels on the host's clusters, as well as any metrics-server installed by devzone. Resources are filtered by the `devzone.instance` label to target only the current instance. It **never touches** `workspace/` (your projects). To keep your logins (GitHub, git, Claude Code, opencode and modules): `make uninstall KEEP=logins` (old `GARDER=connexions` still accepted).

With the command installed globally (`npm install -g devzone`), you can also run, in the devzone folder:

```bash
devzone uninstall
```

Same effect as `make uninstall`. Then only, to remove the command from your machine:

```bash
npm uninstall -g devzone
```

This command only removes the `devzone` command from your machine; it deletes neither the container, nor the volumes, nor the folder.

## Removed names

Commands, subcommands and options are written in English. The old French names are removed: devzone refuses them, shows the new name and does nothing.

```
✖ « activer » was renamed: devzone enable
```

The full table (commands, subcommands, options) is in [the reference](manage/docs/reference.md#removed-names).

## Going further

- [Detailed reference](https://github.com/SimBienvenueHoulBoumi/devzone/blob/main/manage/docs/reference.md)
- [Contributing](https://github.com/SimBienvenueHoulBoumi/devzone/blob/main/manage/docs/contributing.md): tests, delivery process and organization

## License

devzone is free software, distributed under the [GNU General Public License version 3](https://github.com/SimBienvenueHoulBoumi/devzone/blob/main/LICENSE).


### Egress proxy for agent sessions (disabled by default)

Limits the outbound network of sessions launched with `devzone agent --pod` through an HTTP(S) proxy (Squid) in the workspace namespace. Everything is disabled by default: without activation, the chart rendering and the manifest of the session pods remain identical.

- **Modes**: `observation` (the proxy accepts everything and logs, no cut-off, to build the list); `strict` (only the domain list is allowed, and a NetworkPolicy limits the output of the session pods to the proxy and DNS).
- **Enable** (Helm): `egressProxy.enabled=true` and `egressProxy.mode=observation` or `strict` (list: `egressProxy.allowedDomains`, default `.opencode.ai`, `.npmjs.org`, `.github.com`).
- **Reading the contacts**: `kubectl logs deploy/devzone-workspace-egress-proxy -c access-log -n <namespace>`.
- **Guard (strict)**: a window of 1 to 2 s exists at startup before the restriction is scheduled; an init container waits for direct access to be closed (20 tries, 1 s) and refuses the session if the restriction never becomes effective.
- **Limits**: the workspace itself remains open; only `devzone agent --pod` sessions are filtered; tools that ignore `HTTPS_PROXY` are blocked in strict mode.
- **Commands** (#633): `devzone workspace egress observation|strict|off`, `egress status` (domains contacted and their state), `egress allow|deny <domaine>`. The setting is kept in `.devzone.modules` and replayed at each `workspace start` and `workspace update`; the pod is not recreated.
- **Path**: `devzone workspace egress observation`, then `egress status` to see the domains contacted, `egress allow <domaine>` for those missing, and finally `devzone workspace egress strict`.
