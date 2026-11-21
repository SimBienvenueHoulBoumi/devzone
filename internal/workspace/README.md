# internal/workspace

- Role: sub-commands of `devzone workspace` ported to Go (#712). Two so far:
  - `status`: prints the workspace pod (`kubectl get pods`), then the legacy copies still present in the pod, like `status_workspace` in `manage/scripts/workspace-copies.sh`.
  - `stop` (`Stop`, `stop.go`): like `stop_workspace` in `manage/workspace.sh`. The port watcher of the workstation is stopped first (`stop_ports.go`, the port of `ports_stop` in `manage/scripts/ports-workspace.sh`: SIGTERM to the watcher and to each relay, then removal of the lock, the pid and the relay files of `.devzone.workspace-ports/`, or of `DEVZONE_PORTS_WORKSPACE_DIR`). Then `helm uninstall devzone-workspace --namespace devzone-workspace`.
- Argo CD fallback: when the namespace `devzone-argocd` exists and holds the Application `devzone-workspace`, `Stop` calls the `fallback` it receives and returns its status. Argo CD removal goes through the GitOps repository (GitHub or GitLab, git, gh), which stays in bash. The check is read-only and runs before any change, so the bash run starts from the same state.
- Calling `kubectl` and `helm`: through the `Runner` interface (`Kubectl` and `Helm`, each with `args, stdin, stdout, stderr`). `ExecRunner` runs the programs found in the PATH; the tests replace `Runner` with a fake, without a cluster.
- Context: `--context devzone` for kubectl and `--kube-context devzone` for helm, when the kubeconfig declares the `devzone` context, otherwise the current context (like `kubectl_flag` and `helm_flag`).
- Exit codes: `status` returns the one of `kubectl get pods` (a missing or failing pod is not an error: the pod status is printed); `stop` returns the one of `helm uninstall`, or of the bash fallback. Both give 127 when the program cannot start. The legacy copies check never fails `status`: when the pod does not answer, nothing is printed.
- Parity: `manage/test/go-parity.bats` compares the output and the status with the bash script, with a fake `kubectl` and a fake `helm` in the PATH.
- May import: the standard library only.
- Must not import: `internal/command`, `internal/bashbridge` or `cmd/...`.
- Tests: `go test ./internal/workspace/`. The remaining sub-commands (`start`, `shell`, ...) stay in `manage/workspace.sh` and are delegated to bash by `internal/command`.
