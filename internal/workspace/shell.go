package workspace

import (
	"fmt"
	"io"
)

// Shell opens an interactive bash in the workspace container, as shell_workspace
// does in manage/workspace.sh: "kubectl exec -it" with the terminal of the user.
// stdin must be that terminal: it is passed on to kubectl unchanged, as are the
// standard output and error. It returns the status of kubectl, so an interrupted
// or failing session keeps its status; a kubectl that cannot start gives 127, as
// a shell does.
func Shell(r Runner, stdin io.Reader, out, errOut io.Writer) int {
	args := append(contextFlag(r), "exec", "-it", pod, "--namespace", namespace, "-c", container, "--", "bash")
	status, err := r.Kubectl(args, stdin, out, errOut)
	if err != nil {
		fmt.Fprintf(errOut, "devzone: cannot start kubectl: %v\n", err)
		return notStarted
	}
	return status
}
