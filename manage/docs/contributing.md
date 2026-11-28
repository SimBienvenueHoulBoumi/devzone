# Contributing

## Tests

| Tests | Command | Where | Duration |
|---|---|---|---|
| Go unit tests / command tests | `GOTOOLCHAIN=local go test ./... -count=1 -timeout 90s` | in the devzone workspace (pod) | a few seconds |
| Functional pod workspace on kind: builds the workspace image, loads it into kind, installs `charts/devzone-workspace`, exercises `devzone workspace start|status|stop` and a module command | `make test-fonctionnel` | on a machine/runner with kind, kubectl, helm, Node, and a container engine for image build | 10 to 20 min |
| CLI in a real terminal: host CLI checks with a maximum delay; no container mode | `make test-cli` | on your machine (Node, Python 3, make) | under a minute |
| Windows (local and CI) | `bash manage/test/windows.sh` | macOS/Linux (local) or Windows Git Bash (CI) | a few seconds |

## Repository checks

Run these from the repository root: `go run ./cmd/devzone-checks english`, `go run ./cmd/devzone-checks layout` and `go run ./cmd/devzone-checks names`. The layout check refuses any Go file over 250 lines; the names check refuses a forbidden word in a tracked file or folder name. Both cover tracked files and new files that git does not ignore.

**GitLab rule**: a PR that touches `.devcontainer/gitlab/` or the platform runs `devzone test-gitlab --statut` before it is ready; the `gitlab-integration` status is then visible on its commit. This test is the end-to-end test of the GitLab module and platform, impossible in GitHub CI (8 GB of RAM): the lead runs it on the container. Details of the steps, options and variables in [Reference, GitLab](reference.md#gitlab).

**Removed tests**: the `repowarden` check refuses a change that removes tests. When the removal is intended (tests ported to Go, for example), write a `Tests removed: <reason>` line (or its French form) in a **commit message**. The PR description is read by the run of the PR only: the run started by the push to `develop` still fails, and the delivery PR stays blocked.

**Windows (CI): what is checked / what is not (container, VS Code).** The `windows` job checks on `windows-latest` (checkout with `core.autocrlf=true`, like a Windows workstation): no CRLF in the scripts (every tracked file starting with `#!`, plus the `Makefile`); npm packaging (`npm pack`) and installation of the archive, in an isolated npm prefix under `$TMP` (the machine's global is never touched); `devzone --version`, `devzone --help`, unknown option (with error exit); `devzone <folder>` with `DEVZONE_NO_START=1` (creation of the expected files, non-empty folder refused without overwriting); `devzone uninstall` outside a devzone folder refused. The same path then goes through `cmd`, that is the npm `.cmd` shortcut, this time with a real global installation (the case of a Windows user). What is **not** checked on Windows CI: the Linux container (impossible on GitHub's Windows runners), as well as VS Code and Docker Desktop (checked by hand).

In CI, the `fonctionnel` workflow runs pod-workspace scenarios on a kind cluster for jobs `fonctionnel`, `cli` and `ia-arm64` (Linux runners with kind/kubectl/helm). The `windows` job keeps line-ending and npm shim checks; Windows GitHub runners cannot run the Linux kind pod scenario, so pod coverage is provided by the Linux jobs and the limit is reported in the workflow/log. The summary check **`tests-conteneur`** remains required.

**Developing devzone in the pod.** The pod is the only supported devzone mode. Use `devzone workspace start|shell|vscode` to work in the workspace pod, keep worktrees under `workspace/wt/`, and run Go checks in that environment (`export GOTOOLCHAIN=local`, `gofmt -l`, `go vet ./...`, `go test ./... -count=1 -timeout 90s`). Do not run host container-engine commands; disposable cluster tests use kind/kubectl/helm in CI or a disposable namespace/pod when explicitly appropriate.

**Go tests that run Git.** The pre-push hook runs `go test` with the `GIT_*` variables of the repository: a test that runs `git` without clearing them writes to the real repository, even with `git -C`. Use the shared helpers of `internal/framework/testhygiene`; a guard test fails otherwise.



## Versions and delivery

Flow `develop` → `main`, managed by repowarden, **with no action after a ticket is merged**:
1. The work enters `develop` (default branch), through a PR linked to a ticket. **Its merge is the human validation.** A work PR opened toward `main` is retargeted to `develop` by CI.
2. The release bot immediately publishes a **preview** `vX.Y.Z-next.N` and keeps the **delivery PR** `develop` → `main` up to date.
3. The GitHub App **merges the delivery PR** as soon as its checks are green (`repowarden`, `tests-conteneur`: container tests on the delivered commit, and `livraison`: preview published). This merge publishes the tag `vX.Y.Z` and the [GitHub release](https://github.com/SimBienvenueHoulBoumi/devzone/releases). A red check blocks the delivery, visible on the PR.

`main` thus stays up to date with `develop`. The version follows the Conventional Commits: `fix` → patch, `feat` → minor; a delivery without `fix` nor `feat` (documentation, CI…) updates `main` without a new version.

**Tickets**: at a version, the `tickets` job of `release.yml` moves the tickets `statut: préprod` to `statut: done` and closes them, with the version. repowarden does this only at a stable tag: for a delivery without a new version, the `tickets-sans-version` job runs the same follow-up from repowarden, and the tickets are closed with the comment “Published in **main, without a new version (<commit>)**”.

**Settings, at the maintainer's choice**:

| Setting | Where | Effect |
|---|---|---|
| Automatic delivery (devzone default) | `release.yml`, `release` job: `delivery-auto: true` and `delivery-on-push: true`; `.repowarden.conf`: `deliveryApproval = auto` | the delivery PR is armed for automatic merge by the GitHub App and leaves as soon as its checks are green (official repowarden setting ≥ 4.9) |
| Manual delivery | `release.yml`: `delivery-auto: false` (or removed); `.repowarden.conf`: `deliveryApproval = review` | the delivery PR waits for your merge |
| Preview at each merge (devzone) or in the evening | `release.yml`, `release` job: `preversion-on-push: true` or nothing | without a preview at each merge, the delivery waits for the evening one |
| Preview required before a stable version (default, devzone's) | `release.yml`, `release` job: nothing, or `preversion-obligatoire: false` to disable it | disabled, the `livraison` check passes automatically (“preview not required”): the delivery PR no longer waits for a preview, but the stable version has not been tested as a preview |

Prerequisite of the automatic delivery: the repository's GitHub App (`repowarden app init`, run on your machine; see [Troubleshooting](reference.md#troubleshooting)). Without it, a merge made by the Actions token would not trigger the release.



## Package contents

The npm package (what `npm pack` produces and `devzone <folder>` copies) is checked by `manage/test/package-contents.bats`. The test reads `npm pack --dry-run --json --ignore-scripts`: nothing is published, no lifecycle script runs, and there is no network access. It is skipped when npm is absent.

- **Shipped**: `manage/devzone` (the command), `manage/scripts/`, `manage/workspace.sh`, `.devcontainer/`, `charts/`, `Makefile`, `.gitattributes`, `README.md`, `LICENSE`, `package.json`, and `bin/` when it has been built (see below).
- **Excluded**: `manage/test/`, `manage/docs/`, `cmd/`, `internal/`, `.github/`, `.claude/`, `.opencode/`, `go.mod`, `go.sum`, `.repowarden.conf`, `CLAUDE.md`, `AGENTS.md`, `CONTRIBUTING.md`. The exclusion comes from the `files` list of `package.json`: a path added there is shipped.
- **Ceilings** (without `bin/`): 175 files and 872000 bytes unpacked, measured at #772 (159 files, 792412 bytes) plus 10 %. The test fails when a ceiling is passed; raise one only with the reason in the commit.

### The Go binaries (#773)

- **Content**: `bin/devzone-<os>-<arch>` for linux, darwin and windows (`.exe`) on amd64 and arm64, and `bin/SHA256SUMS` (one `<sum>  <name>` line per binary). `bin/` is ignored by git and never committed; `package-contents.bats` accepts exactly these seven files, and only when `bin/` exists.
- **Build**: the `prepack` script of `package.json` runs `manage/scripts/ci/build-binaries.sh`, so `npm publish` and `npm pack` build them; `npm pack --ignore-scripts` (the test) and a developer without Go do not. The script reads `ARG GO_VERSION` of `.devcontainer/Dockerfile` and sets `GOTOOLCHAIN` to it (Go 1.21 or newer downloads the exact toolchain, 3 attempts, 5 s apart; without Go or with an older one it fails with the reason). A missing binary makes it fail: a half-built package is never produced. The version printed by `--version` is not injected: the binary reads the `package.json` of the package, like the bash command.
- **Launcher**: `manage/devzone` picks `bin/devzone-<os>-<arch>` from `uname -s` and `uname -m`, checks its sum in `bin/SHA256SUMS`, copies it once to `${XDG_CACHE_HOME:-~/.cache}/devzone/bin/<version>/devzone[.exe]` (mode 755: npm does not keep the executable bit outside `bin`; the copy is atomic) and runs it with `DEVZONE_BASH_ENTRY` set to the launcher, so the binary finds `manage/devzone` and `package.json` from the cache. A wrong or missing sum, a copy that fails or a platform without binary keeps the bash command (a message tells why for the first cases).
- **`DEVZONE_NO_GO=1`**: forces the bash command. **`DEVZONE_FROM_GO`**: set to 1 by the bridge `internal/bashbridge` in the environment of the bash it starts for the commands not ported to Go; the launcher then does not launch the binary again (no loop). Do not set it by hand.
- **Ceilings** (with `bin/`): 185 files, 26139000 bytes unpacked and 11058000 bytes packed, measured after the merge of #883 (127 files, 23762428 bytes unpacked, 10052425 packed) plus 10 %, rounded up to the next thousand; they were 22843000 and 9631000 at #781 lot A1.2b-2 (169 files, 20766171 bytes unpacked, 8754981 packed). **Why they grew**: the port watcher now runs in Go on Windows too, with its process primitives, relays and GitLab forwarding. Measured with `build-binaries.sh` and `npm pack --dry-run` on the two revisions: 22289243 → 23266139 bytes unpacked and 9379707 → 9777216 bytes packed when the Windows watcher was added; the rest of the lot brings the package to the measurements above. An earlier raise came from the watcher being reachable from the command, so the linker kept the whole `net` package that the unused port tests had let it drop. A ceiling is raised only for a measured reason of that kind, written in the commit. The `package` job of `.github/workflows/go.yml` builds the binaries, runs `npm pack --dry-run`, checks the seven files and the packed size, and compares `bin/devzone-linux-amd64 --version` with `package.json`.
- **Tests**: `manage/test/launcher-go.bats` (fake binary per platform, fake `uname`, cache, wrong sum, `DEVZONE_NO_GO`, no loop with a fake and with the real binary).

## Organization

```text
devzone/
├── .devcontainer/
│   ├── Dockerfile              # base image + pinned tools (versions and sha256)
│   ├── devcontainer.json       # recipe of the pod image: features, volumes, VS Code extensions
│   ├── devcontainer-lock.json  # pinned versions of the features
│   ├── devzone                 # devzone command: modules (ai, kubernetes), AI assistant versions
│   └── versions.env            # pinned tool versions (repowarden, metrics-server, buildkit)
├── .github/workflows/
│   ├── fonctionnel.yml         # container tests (functional, CLI, Windows, ia-arm64), bats job on each PR/push to develop/main, tests-conteneur summary required to merge
│   ├── repowarden.yml          # repowarden checks of each PR (PR targeted wrongly is retargeted to develop)
│   ├── tickets.yml             # ticket follow-up: branch, draft PR, statuses up to production
│   ├── release.yml             # previews on develop, delivery develop → main
│   └── nettoyage.yml           # merged branches deleted (main and develop kept)
├── .repowarden.conf            # repowarden settings: develop → main flow
├── Makefile                    # control without VS Code
├── package.json, LICENSE       # devzone npm package (GPL-3.0-only license); package.json stays at the root (required by npm)
├── manage/                       # the devzone tool (at the root: only what must be there)
│   ├── devzone                 # npm command: npx devzone <folder>, devzone uninstall
│   └── test/
│       ├── devzone.bats        # tests of the devzone command (bats manage/test/)
│       ├── cli.bats            # npm command and package contents
│       ├── functional.sh      # functional tests (make test-fonctionnel)
│       ├── cli-terminal.sh     # CLI tests in a real terminal (make test-cli)
│       ├── ci-container.sh     # CI: container tests to run (by path) and tests-conteneur summary
│       └── terminal.py         # runs a command under a pseudo-terminal, with a maximum delay
└── workspace/                  # your projects (ignored by git, each with its own repository)
```

## Architecture Go

### Layout

- `cmd/`: the two binaries, `main` only (`cmd/devzone`, `cmd/devzone-pod`).
- `internal/framework`: shared building blocks (`cli`, `output`, `exec`, `state`, `testkit`).
- `internal/platform`: kube, helm, git, github (to come).
- `internal/domain`: one directory per domain (to come).

### Dependency rule

`domain → platform → framework`, never the reverse; a domain never imports another domain.

### Adding a command

Register it in the registry built in `internal/command` (workstation) or `internal/podcmd` (pod). Commands not registered are delegated to the shell through the bash bridge.

### Scope

Go checks run on `./cmd/... ./internal/...` only, never `./...` (which would descend into `workspace/`).
