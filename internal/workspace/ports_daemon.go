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
	tool  string
	quiet bool
	args  []string
}

// portsDaemon runs the service manager of the platform. It is a variable so
// that a test can replace it with a fake that records calls and answers status
// codes, instead of loading a real launch agent or user unit.
var portsDaemon = runDaemon

// portsLookPath resolves the service manager, and portsRunner executes it. Both
// are variables so a test can inject a fake launchctl, systemctl or schtasks
// without putting a program in the PATH or starting a real service manager.
var (
	portsLookPath = exec.LookPath
	portsRunner   = runDaemonCommand
)

// runDaemonCommand returns the exit status of a command, or 1 when it cannot
// start, as a shell does. Keeping the status in the runner lets a test simulate
// a loaded or absent service without spawning a process.
func runDaemonCommand(cmd *exec.Cmd) int {
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

// runDaemon runs tool with args and returns its exit status. A quiet call
// discards the output of the service manager: a call whose failure is expected,
// such as the unload of a job that is not loaded, must not print the usage text
// of launchctl.
func runDaemon(tool string, quiet bool, args ...string) int {
	path, err := portsLookPath(tool)
	if err != nil {
		return 1
	}
	cmd := exec.Command(path, args...)
	if !quiet {
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
	}
	return portsRunner(cmd)
}

// portsDaemonLoadedArgs returns the arguments that ask the service manager
// whether the watcher is loaded: launchctl print, systemctl is-active or
// schtasks /Query. A quiet call turns the answer into a status code only.
func portsDaemonLoadedArgs() []string {
	switch portsPlatform {
	case "darwin":
		return []string{"print", portsDaemonServiceTarget()}
	case "windows":
		return []string{"/Query", "/TN", portsAgentName()}
	}
	return []string{"--user", "is-active", portsAgentName() + "." + portsAgentExt()}
}

// portsDaemonEnableArgs returns the arguments that load and enable the
// definition of the watcher: launchctl bootstrap of the launch agent on macOS,
// systemctl --user enable --now of the user unit on Linux, schtasks /Create of
// the task on Windows, which replaces an earlier task of the same name.
func portsDaemonEnableArgs(definition string) []string {
	switch portsPlatform {
	case "darwin":
		return []string{"bootstrap", portsDaemonDomain(), definition}
	case "windows":
		return []string{"/Create", "/TN", portsAgentName(), "/XML", definition, "/F"}
	}
	return []string{"--user", "enable", "--now", definition}
}

// portsDaemonStartArgs returns the arguments that start the installed watcher
// without changing whether it is enabled: systemctl --user start on Linux,
// launchctl bootstrap on macOS when the job is not loaded, schtasks /Run on
// Windows. A logon trigger does not fire for a task created in the session, so
// Windows needs this explicit run.
func portsDaemonStartArgs() []string {
	switch portsPlatform {
	case "darwin":
		definition := filepath.Join(portsAgentDir(), portsAgentName()+"."+portsAgentExt())
		return []string{"bootstrap", portsDaemonDomain(), definition}
	case "windows":
		return []string{"/Run", "/TN", portsAgentName()}
	}
	return []string{"--user", "start", portsAgentName() + "." + portsAgentExt()}
}

// portsDaemonAfterEnable returns the call that follows a successful enable, or
// nil when none is needed. Windows starts the task at once, since the logon
// trigger would wait for the next session. Linux restarts a replaced copy
// explicitly, because enable --now leaves an active unit on the old binary.
// macOS needs nothing: its bootout before the bootstrap already reloads the agent.
func portsDaemonAfterEnable(replaced bool) []string {
	if portsPlatform == "windows" {
		return portsDaemonStartArgs()
	}
	if replaced && portsPlatform == "linux" {
		return portsDaemonRestartArgs()
	}
	return nil
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
// disable --now on Linux, schtasks /Delete on Windows. Deleting the task first
// matters there: a watcher stopped while its task remains would be relaunched
// by the restart on failure of the task.
func portsDaemonDisableArgs() []string {
	switch portsPlatform {
	case "darwin":
		return []string{"bootout", portsDaemonServiceTarget()}
	case "windows":
		return []string{"/Delete", "/TN", portsAgentName(), "/F"}
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

// portsDaemonTool returns the service manager of the platform: launchctl,
// schtasks (the Task Scheduler command line) or systemctl.
func portsDaemonTool() string {
	switch portsPlatform {
	case "darwin":
		return "launchctl"
	case "windows":
		return "schtasks"
	}
	return "systemctl"
}
