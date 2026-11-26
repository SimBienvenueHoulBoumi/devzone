package workspace

import (
	"fmt"
	"os"
	osexec "os/exec"
	"path/filepath"
)

// portsKubectlPath resolves kubectl on the PATH of the user running enable. It
// is a variable so a test can inject a fake path and never touch a real kubectl.
var portsKubectlPath = osexec.LookPath

// portsAgentValues is the environment written in the definition of the watcher:
// the PATH that finds kubectl and the KUBECONFIG of the user when it is set.
type portsAgentValues struct {
	path       string
	kubeConfig string
}

// portsAgentEnvironment returns the PATH and KUBECONFIG to write in a
// definition. The folder of the kubectl found now comes after the fixed paths,
// so the watcher can reach the cluster without a terminal PATH. A missing
// kubectl is an error with a clear reason for the user.
func portsAgentEnvironment() (portsAgentValues, error) {
	kubectl, err := portsKubectlPath("kubectl")
	if err != nil {
		return portsAgentValues{}, fmt.Errorf("kubectl not found in PATH: %w", err)
	}
	return portsAgentValues{
		path:       portsAgentPath + string(os.PathListSeparator) + filepath.Dir(kubectl),
		kubeConfig: os.Getenv("KUBECONFIG"),
	}, nil
}
