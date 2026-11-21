# internal/workspace

- Role: sub-commands of `devzone workspace` ported to Go (#712). So far only `status`: it prints the workspace pod (`kubectl get pods`), then the legacy copies still present in the pod, like `status_workspace` in `manage/scripts/workspace-copies.sh`.
- Calling `kubectl`: through the `Runner` interface (`Kubectl(args, stdin, stdout, stderr)`). `ExecRunner` runs the `kubectl` found in the PATH; the tests replace `Runner` with a fake, without a cluster.
- Context: `--context devzone` when the kubeconfig declares the `devzone` context, otherwise the current context (like `kubectl_flag`).
- Exit codes: the one of `kubectl get pods` (a missing or failing pod is not an error of the command: the pod status is printed); 127 when `kubectl` cannot start. The legacy copies check never fails the command: when the pod does not answer, nothing is printed.
- Parity: `manage/test/go-parity.bats` compares the output and the status with the bash script, with a fake `kubectl` in the PATH.
- May import: the standard library only.
- Must not import: `internal/command`, `internal/bashbridge` or `cmd/...`.
- Tests: `go test ./internal/workspace/`. The remaining sub-commands (`start`, `stop`, `shell`, ...) stay in `manage/workspace.sh` and are delegated to bash by `internal/command`.
