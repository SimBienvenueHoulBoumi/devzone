package createmode

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// Start prints the start command when only the files are wanted, or runs the
// package workspace script from the new folder. A failed start is reported with
// the command to redo; the folder is kept either way.
func (s *Session) Start(folder, script string) error {
	if os.Getenv("DEVZONE_NO_START") != "" {
		fmt.Fprintf(s.Out, "To start the workspace: cd %s && devzone workspace start\n", folder)
		return nil
	}
	fmt.Fprintln(s.Out, "▶ Starting the workspace in the cluster (a few minutes the first time)…")
	name := os.Getenv("DEVZONE_WORKSPACE_SH")
	if name == "" {
		name = script
	}
	res, err := s.runner().Run(s.ctx(), "bash", []string{name, "start"}, fexec.Opts{Dir: folder})
	_, _ = io.Copy(s.Out, bytes.NewReader(res.Stdout))
	_, _ = io.Copy(s.Err, bytes.NewReader(res.Stderr))
	if err != nil || res.Code != 0 {
		fmt.Fprintf(s.Err, "✖ Workspace not started. The folder is ready: only the start remains (cd %s && devzone workspace start)\n", folder)
		return errors.New("workspace start failed")
	}
	fmt.Fprintf(s.Out, "Next: cd %s && devzone workspace shell (the pod)\n", folder)
	return nil
}
