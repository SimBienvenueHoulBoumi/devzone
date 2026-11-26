package workspace

import (
	"bytes"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// unreachableHint asks the shared shell helper for the user message of an
// unreachable cluster. The helper owns the wording and the probe of the host's
// graphical interface, so the Go command keeps the exact behaviour of the
// shell command. An empty result means the helper is absent, for example when
// the binary runs without the package: the caller then uses its own message.
func unreachableHint(context, server string) string {
	entry := os.Getenv("DEVZONE_BASH_ENTRY")
	if entry == "" {
		return ""
	}
	script := filepath.Join(filepath.Dir(filepath.Dir(entry)), "manage", "scripts", "kube-ready.sh")
	if _, err := os.Stat(script); err != nil {
		return ""
	}
	var out bytes.Buffer
	cmd := exec.Command("bash", "-c", `. "$1"; kube_unreachable_hint "$2" "$3"`, "bash", script, context, server)
	cmd.Stdout = &out
	cmd.Stderr = io.Discard
	if err := cmd.Run(); err != nil {
		return ""
	}
	return strings.TrimRight(out.String(), "\n")
}
