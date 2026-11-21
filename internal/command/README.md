# internal/command

- Role: receives the devzone command line; runs in Go the commands of the `ported` table, delegates the others to the bash bridge (#358).
- May import: the standard library and `internal/bashbridge`.
- Must not import: `cmd/...` (the binary depends on this package, never the reverse) nor a business package that would depend on bash.
- The `ported` table lists the ported commands (today `--version`, `-v`, `help`, `-h`, `--help`, only alone, with no other argument): a command enters it when it is ported, and leaves the delegation in the same change.
- Tests: `go test ./internal/command/`; the delegation tests use a fake bash entry point.
