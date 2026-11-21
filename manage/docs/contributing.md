# Contributing

## Tests

| Tests | Command | Where | Duration |
|---|---|---|---|
| `devzone` command of the container and npm command (unit) | `bats manage/test/` | in the container; in CI, the `bats` job (ubuntu, and macOS under bash 3.2 for cli.bats, versions.bats, ci-container.bats) on each PR and each push to develop and main. bats test rules under bash 3.2: each `[[ … ]]` or `! command` must end with `|| false`; no apostrophe in a comment inside a `$( … )` (bash 3.2 no longer loads the file), checked by `ci-container.bats`. Check under bash 3.2: `devzone test-bash32`. | a few seconds |
| Functional: a devzone built and used as a user would (tools, modules, Kubernetes with kind, repowarden hooks, restart, rebuild) | `make test-fonctionnel` | on your machine (Docker, Node) | 5 to 10 min |
| CLI in a real terminal: each command typed as a human would (pseudo-terminal), with a maximum delay; a command waiting for input fails. `make` targets (`help`, `up`, `shell`, `status`, `stop`, `down`, `rebuild`, `desinstaller`), npm command (`devzone <folder>`, `desinstaller`, `--version`, `--help`), `devzone` command of the container, startup scripts | `make test-cli` | on your machine (Docker, Node, Python 3) | 10 to 15 min |
| Windows (local and CI) | `bash manage/test/windows.sh` | macOS/Linux (local) or Windows Git Bash (CI) | a few seconds |

**GitLab rule**: a PR that touches `.devcontainer/gitlab/` or the platform runs `devzone test-gitlab --statut` before it is ready; the `gitlab-integration` status is then visible on its commit. This test is the end-to-end test of the GitLab module and platform, impossible in GitHub CI (8 GB of RAM): the lead runs it on the container. Details of the steps, options and variables in [Reference, GitLab](reference.md#gitlab).

**Windows (CI): what is checked / what is not (container, VS Code).** The `windows` job checks on `windows-latest` (checkout with `core.autocrlf=true`, like a Windows workstation): no CRLF in the scripts (every tracked file starting with `#!`, plus the `Makefile`); npm packaging (`npm pack`) and installation of the archive, in an isolated npm prefix under `$TMP` (the machine's global is never touched); `devzone --version`, `devzone --help`, unknown option (with error exit); `devzone <folder>` with `DEVZONE_NO_START=1` (creation of the expected files, non-empty folder refused without overwriting); `devzone uninstall` outside a devzone folder refused. The same path then goes through `cmd`, that is the npm `.cmd` shortcut, this time with a real global installation (the case of a Windows user). What is **not** checked on Windows CI: `make up` and the Linux container (impossible on GitHub's Windows runners), as well as VS Code and Docker Desktop (checked by hand).

The functional and CLI tests work on a copy of the repository, with their own volumes (`devzone-test-…`), then delete everything (container, volumes, image), even on failure: your devzone, your logins and the cluster of your machine are never touched (only a test kind cluster is used). In CI, the `fonctionnel` workflow runs them (jobs `fonctionnel`, `cli` and `windows`, plus `ia-arm64`: `devzone enable ai` on an arm64 runner `ubuntu-24.04-arm`, like an Apple Silicon Mac, then `claude --version` and `opencode --version` at the pinned versions) on each PR that changes `.devcontainer/`, `manage/` (npm command, scripts, tests), the `Makefile`, `.gitattributes` or `package.json`, and by hand (*Actions → fonctionnel → Run workflow*).

**Required to merge.** The workflow runs on each PR; the `bats` job runs on ubuntu-latest and macos-latest (system bash 3.2 at the head of the PATH) without a per-path decision, on the whole `manage/test/` under ubuntu, and on `manage/test/cli.bats`, `manage/test/versions.bats`, `manage/test/ci-container.bats` under macOS (the other `.bats` do not run there, including `devzone.bats`). Its `changements` job decides by path whether the four container jobs must run (`fonctionnel`, `cli`, `windows`, `ia-arm64`, `manage/test/ci-container.sh`); the summary check **`tests-conteneur`** is required to merge into `develop` as well as `main` (`requiredChecks` of `.repowarden.conf`) and depends on the `bats` job in addition to the four others: it succeeds if `bats` succeeded and if `fonctionnel`, `cli`, `windows` and `ia-arm64` succeeded, or if they had no reason to run (docs-only PR: a few seconds); a failure or a cancellation makes it fail. A PR that touches the container therefore cannot be merged while its tests run. On `push` to `develop` and `main`, only the `bats` job runs (`changements` answers `false`). After a change of `requiredChecks`: `repowarden proteger --checks "repowarden,tests-conteneur"` (administration rights), verified by `repowarden proteger --verifier --checks "repowarden,tests-conteneur"`.



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

- **Shipped**: `manage/devzone` (the command), `manage/scripts/`, `manage/workspace.sh`, `.devcontainer/` (including `isolation.sh` and `ticket.sh`, which are used at run time, not only by the tests), `charts/`, `Makefile`, `.gitattributes`, `README.md`, `LICENSE`, `package.json`, and `bin/` when it has been built (see below).
- **Excluded**: `manage/test/`, `manage/docs/`, `cmd/`, `internal/`, `.github/`, `.claude/`, `.opencode/`, `go.mod`, `go.sum`, `.english`, `.repowarden.conf`, `CLAUDE.md`, `AGENTS.md`, `CONTRIBUTING.md`. The exclusion comes from the `files` list of `package.json`: a path added there is shipped.
- **Ceilings** (without `bin/`): 175 files and 872000 bytes unpacked, measured at #772 (159 files, 792412 bytes) plus 10 %. The test fails when a ceiling is passed; raise one only with the reason in the commit.

### The Go binaries (#773)

- **Content**: `bin/devzone-<os>-<arch>` for linux, darwin and windows (`.exe`) on amd64 and arm64, and `bin/SHA256SUMS` (one `<sum>  <name>` line per binary). `bin/` is ignored by git and never committed; `package-contents.bats` accepts exactly these seven files, and only when `bin/` exists.
- **Build**: the `prepack` script of `package.json` runs `manage/scripts/ci/build-binaries.sh`, so `npm publish` and `npm pack` build them; `npm pack --ignore-scripts` (the test) and a developer without Go do not. The script reads `ARG GO_VERSION` of `.devcontainer/Dockerfile` and sets `GOTOOLCHAIN` to it (Go 1.21 or newer downloads the exact toolchain, 3 attempts, 5 s apart; without Go or with an older one it fails with the reason). A missing binary makes it fail: a half-built package is never produced. The version printed by `--version` is not injected: the binary reads the `package.json` of the package, like the bash command.
- **Launcher**: `manage/devzone` picks `bin/devzone-<os>-<arch>` from `uname -s` and `uname -m`, checks its sum in `bin/SHA256SUMS`, copies it once to `${XDG_CACHE_HOME:-~/.cache}/devzone/bin/<version>/devzone[.exe]` (mode 755: npm does not keep the executable bit outside `bin`; the copy is atomic) and runs it with `DEVZONE_BASH_ENTRY` set to the launcher, so the binary finds `manage/devzone` and `package.json` from the cache. A wrong or missing sum, a copy that fails or a platform without binary keeps the bash command (a message tells why for the first cases).
- **`DEVZONE_NO_GO=1`**: forces the bash command. **`DEVZONE_FROM_GO`**: set to 1 by the bridge `internal/bashbridge` in the environment of the bash it starts for the commands not ported to Go; the launcher then does not launch the binary again (no loop). Do not set it by hand.
- **Ceilings** (with `bin/`): 185 files, 20146000 bytes unpacked and 8572000 bytes packed, measured at #773 (168 files, 18314524 bytes unpacked, 7792088 packed) plus 10 %. The `package` job of `.github/workflows/go.yml` builds the binaries, runs `npm pack --dry-run`, checks the seven files and the packed size, and compares `bin/devzone-linux-amd64 --version` with `package.json`.
- **Tests**: `manage/test/launcher-go.bats` (fake binary per platform, fake `uname`, cache, wrong sum, `DEVZONE_NO_GO`, no loop with a fake and with the real binary).

## Organization

```text
devzone/
├── .devcontainer/
│   ├── Dockerfile              # base image + pinned tools (versions and sha256)
│   ├── devcontainer.json       # features (languages, Docker, Kubernetes, gh), volumes, VS Code extensions
│   ├── devcontainer-lock.json  # pinned versions of the features
│   ├── devzone                 # devzone command: modules (ai, kubernetes), AI assistant versions
│   ├── post-create.sh          # first startup: volume rights, git, repowarden, active modules (without questions)
│   ├── startup.sh            # each startup: git identity, clusters, then summary (devzone)
│   ├── kube-config.sh          # kind contexts; kubernetes module: host cluster, metrics-server
│   ├── metrics-server.sh       # metrics-server on local clusters (CPU and RAM in k9s)
│   └── git-identity.sh         # git identity deduced from the gh account if missing
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
│   ├── scripts/
│   │   ├── launch.sh           # make up / rebuild: displayed steps, container question flagged
│   │   └── uninstall.sh     # make desinstaller: removes everything devzone created
│   └── test/
│       ├── devzone.bats        # tests of the devzone command (bats manage/test/)
│       ├── cli.bats            # npm command, package contents, manage/scripts/launch.sh, tree paths
│       ├── functional.sh      # functional tests (make test-fonctionnel)
│       ├── cli-terminal.sh     # CLI tests in a real terminal (make test-cli)
│       ├── ci-container.sh     # CI: container tests to run (by path) and tests-conteneur summary
│       └── terminal.py         # runs a command under a pseudo-terminal, with a maximum delay
└── workspace/                  # your projects (ignored by git, each with its own repository)
```
