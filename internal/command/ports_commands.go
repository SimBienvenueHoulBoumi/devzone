package command

import (
	"io"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/workspace"
)

// The three entry points that touch the automatic start of the port watcher go
// through variables, so a test can check the routing or the uninstall without
// writing a launch agent, a user unit or calling a real service manager.
var (
	commandPortsEnable  = workspace.PortsEnable
	commandPortsDisable = workspace.PortsDisable
	commandPortsStart   = workspace.PortsStart
	commandPortsAgent   = workspace.PortsAgentRun

	// commandPortsAutoStartExists tells uninstall whether there is a definition
	// to retire, so it never announces a disabled start that did not exist.
	commandPortsAutoStartExists = workspace.PortsAutoStartExists
)

// retirePortsAutoStart removes the automatic start only when one was installed
// for this devzone folder, and returns the status of the removal.
func retirePortsAutoStart(out, errOut io.Writer) int {
	if !commandPortsAutoStartExists() {
		return 0
	}
	return commandPortsDisable(out, errOut)
}
