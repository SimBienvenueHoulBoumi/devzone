# internal/bashbridge

- Role: runs the bash entry point (`manage/devzone`) as a child process, keeping inputs, outputs, environment and exit code (#358).
- May import: the standard library only.
- Must not import: any package of the repository (neither `internal/command`, nor `cmd/...`), to remain reusable and cycle-free.
- Location: `DEVZONE_BASH_ENTRY` if set, otherwise `manage/devzone` next to the binary, in its parent folder, then in the current folder.
- Loop guard: the child bash gets `DEVZONE_FROM_GO=1`; `manage/devzone` does not launch the package binary when it is set (#773).
- Tests: `go test ./internal/bashbridge/`; temporary scripts are created in `t.TempDir()`.
