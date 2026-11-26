package command

import (
	"bytes"
	"fmt"
	"io"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// TestUninstallWithoutAutostartSaysNothing checks that an uninstall of a
// devzone folder that never installed the automatic start does not announce a
// retirement that never happened.
func TestUninstallWithoutAutostartSaysNothing(t *testing.T) {
	root := devzoneDir(t, "cluster=kind-devzone-ci")
	runner := fake.New()
	registerLists(t, runner, "kind-devzone-ci", "", "", "")
	chdir(t, root)
	previousExists := commandPortsAutoStartExists
	commandPortsAutoStartExists = func() bool { return false }
	t.Cleanup(func() { commandPortsAutoStartExists = previousExists })
	calls := 0
	commandPortsDisable = func(out io.Writer, _ io.Writer) int {
		calls++
		fmt.Fprintln(out, "✔ port watcher: automatic start disabled")
		return 0
	}
	var out, errOut bytes.Buffer
	code := uninstallCommand(&cli.Context{Args: []string{"--yes"}, Out: &out, Err: &errOut, Stdin: strings.NewReader(""), Runner: runner})
	if code != 0 || calls != 0 || strings.Contains(out.String(), "automatic start disabled") {
		t.Fatalf("code = %d, calls = %d, out = %q, err = %q", code, calls, out.String(), errOut.String())
	}
}
