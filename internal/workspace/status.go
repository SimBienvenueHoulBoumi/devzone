package workspace

import (
	"bytes"
	"fmt"
	"io"
	"strings"
)

// Names of the workspace in the cluster, as manage/workspace.sh has them.
const (
	namespace   = "devzone-workspace"
	pod         = "devzone-workspace-0"
	container   = "workspace"
	projectsDir = "/workspaces/projets"
	// kubeContext is the kubeconfig context of the cluster, used when declared
	kubeContext = "devzone"
	// notStarted is the status of a shell when the command cannot be found
	notStarted = 127
)

// Status writes the status of the workspace pod, as "kubectl get pods" prints
// it, then the legacy copies and a warning for a large core dump in a work
// folder. It returns the status of the "kubectl get pods" call: the extra checks
// cannot fail the command. A kubectl that cannot start gives 127, as a shell.
func Status(r Runner, out, errOut io.Writer) int {
	return StatusWith(r, out, errOut, projectsDir, coreDumpSize)
}

// StatusWith is Status with the pod work folder and the core file size function
// injected, so the warning can be tested with a fake folder and no large file.
func StatusWith(r Runner, out, errOut io.Writer, root string, size func(string) int64) int {
	args := append(contextFlag(r), "get", "pods", "--namespace", namespace)
	status, err := r.Kubectl(args, nil, out, errOut)
	if err != nil {
		fmt.Fprintf(errOut, "devzone: cannot start kubectl: %v\n", err)
		return notStarted
	}
	if status != 0 {
		return status
	}
	reportLegacyCopies(r, out)
	reportLargeCoreDumps(out, root, size)
	return 0
}

// contextFlag returns the arguments that select the devzone context when the
// kubeconfig declares it, and none otherwise: the current context is then used,
// as kubectl_flag does in manage/workspace.sh.
func contextFlag(r Runner) []string {
	if !declaresDevzone(r) {
		return nil
	}
	return []string{"--context", kubeContext}
}

// declaresDevzone reports whether the kubeconfig declares the devzone context
// (kubectl config get-contexts), as the *_flag functions of manage/workspace.sh test it.
func declaresDevzone(r Runner) bool {
	var names bytes.Buffer
	status, err := r.Kubectl([]string{"config", "get-contexts", "-o", "name"}, nil, &names, io.Discard)
	if err != nil || status != 0 {
		return false
	}
	for _, name := range strings.Split(names.String(), "\n") {
		if name == kubeContext {
			return true
		}
	}
	return false
}
