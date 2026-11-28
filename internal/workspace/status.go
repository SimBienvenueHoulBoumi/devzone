package workspace

import (
	"fmt"
	"io"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/config"
)

// Names of the workspace in the cluster, as manage/workspace.sh has them.
const (
	namespace   = config.NamespaceWorkspace
	pod         = "devzone-workspace-0"
	container   = "workspace"
	projectsDir = "/workspaces/projets"
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
