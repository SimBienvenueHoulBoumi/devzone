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

// portsEnableForUser clears a memorised refusal before installing the automatic
// start, so an explicit ports enable is always obeyed.
func portsEnableForUser(out, errOut io.Writer) int {
	commandForgetPortsRefusal()
	return commandPortsEnable(out, errOut)
}

// portsDisableForUser removes the automatic start and memorises the refusal in
// the devzone folder, so no later command reinstalls it without a new request.
func portsDisableForUser(out, errOut io.Writer) int {
	status := commandPortsDisable(out, errOut)
	if status == 0 {
		commandMemorizePortsRefusal()
	}
	return status
}

// retirePortsAutoStart removes the automatic start only when one was installed
// for this devzone folder, and returns the status of the removal.
func retirePortsAutoStart(out, errOut io.Writer) int {
	if !commandPortsAutoStartExists() {
		return 0
	}
	return commandPortsDisable(out, errOut)
}

// retirePortsAutoStartAfterUninstall retires the automatic start and memorises
// the refusal: removing a devzone is a choice never to reinstall its watcher.
func retirePortsAutoStartAfterUninstall(out, errOut io.Writer) int {
	status := retirePortsAutoStart(out, errOut)
	commandMemorizePortsRefusal()
	return status
}
