package workspace

import (
	"fmt"
	"io"
)

// AgentsGuard runs the idempotent guard of the agents in the pod, as the former
// shell helper did: when the ai module is on there, repowarden installs its
// guard globally, so an agent started in the pod cannot edit develop. It never
// fails the start: a guard that cannot run is silent.
func AgentsGuard(r Runner, out io.Writer) {
	args := append(contextFlag(r), "exec", pod, "--namespace", namespace, "-c", container, "--",
		"bash", "-lc", "devzone is-enabled ai && repowarden agents init --global")
	status, err := r.Kubectl(args, nil, io.Discard, io.Discard)
	if err == nil && status == 0 {
		fmt.Fprintln(out, "✔ repowarden guard active for the agents of the pod")
	}
}
