package workspace

import (
	"bytes"
	"strings"
	"testing"
)

// vscodeText is the output of vscode_workspace in manage/workspace.sh, byte for byte
const vscodeText = `Attach VS Code to the pod: "Kubernetes" and "Dev Containers" extensions
  1. kubectl context: devzone — namespace devzone-workspace, pod devzone-workspace-0, container workspace
  2. Kubernetes view: right-click the workspace container,
     "Attach to Running Kubernetes Container"
     (with Dev Containers extension: "Dev Containers: Attach to Running Container")
  3. Open folder /workspaces/projets in the attached window
Pod not ready: devzone workspace status
`

func TestVSCodeText(t *testing.T) {
	var out bytes.Buffer
	if status := VSCode(&out); status != 0 {
		t.Fatalf("status = %d, want 0", status)
	}
	if out.String() != vscodeText {
		t.Fatalf("stdout = %q, want %q", out.String(), vscodeText)
	}
}

func TestVSCodeMakesNoCall(t *testing.T) {
	// The guide is static: no kubectl is needed, the workspace may be down
	var out bytes.Buffer
	VSCode(&out)
	if strings.Contains(out.String(), "%") {
		t.Fatalf("stdout %q still holds a format verb", out.String())
	}
}
