package workspace

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
)

// portsDaemonCall records one call to a service manager, for the tests: no
// test reaches the real launchctl or systemctl.
type portsDaemonCall struct {
	tool string
	args []string
}

// portsDaemon runs the service manager of the platform. It is a variable so
// that a test can replace it with a fake that records calls and answers status
// codes, instead of loading a real launch agent or user unit.
var portsDaemon = runDaemon

// runDaemon runs tool with args and returns its exit status, or 1 when the
// program cannot start, as a shell does.
func runDaemon(tool string, args ...string) int {
	cmd := exec.Command(tool, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	err := cmd.Run()
	if err == nil {
		return 0
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		return exitErr.ExitCode()
	}
	return 1
}

// portsDaemonEnableArgs returns the arguments that load and enable the
// definition of the watcher: launchctl bootstrap of the launch agent on macOS,
// systemctl --user enable --now of the user unit on Linux.
func portsDaemonEnableArgs(definition string) []string {
	if portsPlatform == "darwin" {
		return []string{"bootstrap", portsDaemonDomain(), definition}
	}
	return []string{"--user", "enable", "--now", definition}
}

// portsDaemonStartArgs returns the arguments that start the installed watcher
// without changing whether it is enabled: systemctl --user start on Linux,
// launchctl bootstrap on macOS when the job is not loaded.
func portsDaemonStartArgs() []string {
	if portsPlatform == "darwin" {
		definition := filepath.Join(portsAgentDir(), portsAgentName()+"."+portsAgentExt())
		return []string{"bootstrap", portsDaemonDomain(), definition}
	}
	return []string{"--user", "start", portsAgentName() + "." + portsAgentExt()}
}

// portsDaemonRestartArgs returns the arguments that restart the installed
// watcher on Linux: enable --now does not restart a unit that is already
// active, so a replaced binary needs an explicit restart. On macOS the bootout
// before the bootstrap of enable already reloads the agent.
func portsDaemonRestartArgs() []string {
	return []string{"--user", "restart", portsAgentName() + "." + portsAgentExt()}
}

// portsDaemonDisableArgs returns the arguments that unload and disable the
// definition of the watcher: launchctl bootout on macOS, systemctl --user
// disable --now on Linux.
func portsDaemonDisableArgs() []string {
	if portsPlatform == "darwin" {
		return []string{"bootout", portsDaemonServiceTarget()}
	}
	return []string{"--user", "disable", "--now", portsAgentName() + "." + portsAgentExt()}
}

// portsDaemonDomain returns the launchctl domain of the current user, gui/<uid>.
func portsDaemonDomain() string {
	return "gui/" + strconv.Itoa(os.Getuid())
}

// portsDaemonServiceTarget returns the launchctl service target of the watcher,
// gui/<uid>/<label>, where the label is the Label of the launch agent.
func portsDaemonServiceTarget() string {
	return portsDaemonDomain() + "/" + portsAgentName()
}

// portsDaemonTool returns the service manager of the platform.
func portsDaemonTool() string {
	if portsPlatform == "darwin" {
		return "launchctl"
	}
	return "systemctl"
}
