# Repository rule: Kubernetes only

devzone is described with the cluster, the pod and the nodes; never as "Docker".
Only pods are containers. For a disposable test: `kubectl run` or
`kubectl create ns`, then deletion. The guard stops agents that run
`docker`; `DEVZONE_ALLOW_DOCKER=1` is reserved for an action on the
host itself. Details: `.devcontainer/skills/devzone/SKILL.md`.

# Rules for agents that write code here

Short on purpose: read them every time, apply them without discussion.

1. Do exactly the task of the brief, in the order given. Nobody answers questions: never ask one, never summarize the project.
2. Work only in the worktree named in the brief. Never commit, never push, never touch git configuration.
3. Change only the files the brief lists.
4. New code is Go. Never write new shell.
5. A new test is a Go test. Never write a new bats test.
6. A change that ports a command to Go removes its shell and its bats in the same change.
7. A Go test that must compare with a shell function calls the real function: `bash -c '. "$1"; body' _ script`, and passes data as positional arguments, never by escaping inside the string.
8. Every Go file stays under 250 lines: split by responsibility.
9. Everything written is in English: identifiers, comments, messages.
10. Never write the name of the former container engine in a line you add. Check: `git diff | grep '^+' | grep -ci <that name>` must print 0.
11. When an existing bats file has to be edited: every `[[ ... ]]` condition ends with `|| false` (bash 3.2 does not fail the test otherwise).
12. Before stopping, `gofmt -l`, `go vet ./...` and `go test ./... -count=1` must pass, and so must the checks the brief lists. If one fails for a reason outside your files, say so in the report; do not fix other files.
13. Never print or copy a secret, a password file or a token.
14. No new external dependency: `go.mod` and `go.sum` do not change unless the brief says so. Tests use the standard library (`testing`), never an assertion library.
15. Every function you add has a comment above it, in English, that says what it does and why.
16. Stop as soon as the brief is done: create the marker file the brief names, then exit.
