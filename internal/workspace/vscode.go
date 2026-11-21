package workspace

import (
	"fmt"
	"io"
)

// vscodeGuide is the text of "devzone workspace vscode", as vscode_workspace in
// manage/workspace.sh prints it. The %s verbs take the namespace, the pod and
// the projects folder, in that order.
const vscodeGuide = `Attach VS Code to the pod: "Kubernetes" and "Dev Containers" extensions
  1. kubectl context: devzone — namespace %s, pod %s, container workspace
  2. Kubernetes view: right-click the workspace container,
     "Attach to Running Kubernetes Container"
     (with Dev Containers extension: "Dev Containers: Attach to Running Container")
  3. Open folder %s in the attached window
Pod not ready: devzone workspace status
`

// VSCode writes the guide that attaches VS Code to the workspace pod, as
// "devzone workspace vscode" does in manage/workspace.sh. It makes no call to
// kubectl and always returns 0.
func VSCode(out io.Writer) int {
	fmt.Fprintf(out, vscodeGuide, namespace, pod, projectsDir)
	return 0
}
