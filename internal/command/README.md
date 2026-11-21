# internal/command

- Role: receives the devzone command line; runs in Go the commands of the `ported` table, delegates the others to the bash bridge (#358).
- May import: the standard library, `internal/bashbridge` and `internal/workspace`.
- Must not import: `cmd/...` (the binary depends on this package, never the reverse) nor a business package that would depend on bash.
- The `ported` table lists the ported commands: `--version`, `-v`, `help`, `-h`, `--help`, only alone, with no other argument; and `workspace`, for the `status` sub-command only (#712, `workspaceCommand` in `workspace.go`). A command enters it when it is ported, and leaves the delegation in the same change. `devzone workspace` followed by anything other than `status` (or `status` followed by a word) stays delegated to bash.
- Tests: `go test ./internal/command/`; the delegation tests use a fake bash entry point, those of `workspace status` a fake `kubectl` in the PATH.
