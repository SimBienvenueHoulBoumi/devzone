package command

import (
	"fmt"
	"io"
	"os"
	osexec "os/exec"
	"path/filepath"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/workspace"
)

// commandEnsureAutoStart is the single function that assures the automatic
// start of the port watcher. It is a variable so a routing test can count the
// triggers without installing anything.
var commandEnsureAutoStart = EnsurePortsAutoStart

// commandPortsWatcherUpToDate is injectable so a test can exercise the silent
// path of an installation that is already current.
var commandPortsWatcherUpToDate = workspace.PortsWatcherUpToDate

// commandPortsAutoStartFailed tells whether the service manager refused the
// automatic start with this program: no automatic attempt is made then.
var commandPortsAutoStartFailed = workspace.PortsAutoStartFailed

// commandPortsRefusalIsSet, commandMemorizePortsRefusal and
// commandForgetPortsRefusal are injectable so uninstall and the ports commands
// can be tested without touching a folder.
var (
	commandPortsRefusalIsSet    = workspace.PortsRefused
	commandMemorizePortsRefusal = workspace.MemorizePortsRefusal
	commandForgetPortsRefusal   = workspace.ForgetPortsRefusal
)

// containerEnvironmentVars identify a workspace pod or a development
// container: none of them holds the personal session of the workstation.
var containerEnvironmentVars = []string{
	"DEVZONE_WORKSPACE", "KUBERNETES_SERVICE_HOST", "REMOTE_CONTAINERS", "CODESPACES", "DEVCONTAINER",
}

// portsServiceManagerAvailable tells whether this host can run the automatic
// start of the port watcher: Windows has none (#883), and a Unix host without
// systemctl or launchctl cannot manage it. It is a variable so a test can
// exercise both cases without touching a real service manager.
var portsServiceManagerAvailable = func() bool {
	if workspace.PortsPlatform() == "windows" {
		return false
	}
	tool := "systemctl"
	if workspace.PortsPlatform() == "darwin" {
		tool = "launchctl"
	}
	_, err := osexec.LookPath(tool)
	return err == nil
}

// portsIsWorkstation reports whether the command runs on the user's workstation
// and not in the pod or in a development container. It is injectable so every
// case can be tested on the same machine.
var portsIsWorkstation = func() bool {
	if workspace.PortsPlatform() == "windows" {
		return false
	}
	for _, key := range containerEnvironmentVars {
		if os.Getenv(key) != "" {
			return false
		}
	}
	return true
}

// portsIsCI reports whether the command runs in continuous integration, where
// no service manager may be loaded. It is injectable for the tests.
var portsIsCI = func() bool {
	for _, key := range []string{"CI", "GITHUB_ACTIONS", "GITLAB_CI"} {
		value := os.Getenv(key)
		if value != "" && value != "0" && value != "false" {
			return true
		}
	}
	return false
}

// portsIsTest reports whether the program is a Go test binary or runs under
// bats: neither may install a real service. It is injectable for the tests.
var portsIsTest = func() bool {
	if os.Getenv("BATS_TEST_TMPDIR") != "" {
		return true
	}
	name := strings.ToLower(filepath.Base(os.Args[0]))
	return strings.HasSuffix(name, ".test") || strings.HasSuffix(name, ".test.exe")
}

// EnsurePortsAutoStart installs or repairs the automatic start of the watcher
// of this devzone folder, silently once everything is current. It does nothing
// in the pod, in a development container, in CI, under tests, on Windows,
// without a service manager, after a refusal the user memorised, or after a
// failure of the service manager with this program. It never changes the
// status of the command that triggered it: an installation problem is reported
// on errOut but stays a warning. Only the first installation says
// one line, with the command that removes the automatic start.
func EnsurePortsAutoStart(out, errOut io.Writer) {
	if !portsIsWorkstation() || portsIsCI() || portsIsTest() ||
		!portsServiceManagerAvailable() || commandPortsRefusalIsSet() || commandPortsAutoStartFailed() {
		return
	}
	installed := commandPortsAutoStartExists()
	if installed && commandPortsWatcherUpToDate() {
		return
	}
	if status := commandPortsEnable(io.Discard, errOut); status != 0 {
		return
	}
	if !installed {
		fmt.Fprintln(out, "Port watcher installed; remove with: devzone workspace ports disable")
	}
}

// maybeEnsurePortsAutoStart triggers the automatic start after a successful
// user command issued on the workstation, including a folder creation and an
// update. Help, version, uninstall, the ports refusal and the watcher's own
// commands are excluded so a stop or an internal loop never reinstalls it.
func maybeEnsurePortsAutoStart(args []string, out, errOut io.Writer) {
	if autoStartExcluded(args) {
		return
	}
	folder := autoStartFolder(args)
	if folder == "" {
		return
	}
	previous, hadPrevious := os.LookupEnv("DEVZONE_ROOT")
	_ = os.Setenv("DEVZONE_ROOT", folder)
	defer func() {
		if hadPrevious {
			_ = os.Setenv("DEVZONE_ROOT", previous)
		} else {
			_ = os.Unsetenv("DEVZONE_ROOT")
		}
	}()
	commandEnsureAutoStart(out, errOut)
}

// autoStartExcluded tells whether a command must never trigger an installation:
// help and version are read-only, uninstall and ports disable are a refusal,
// and stop and the watcher's internal commands keep their effect.
func autoStartExcluded(args []string) bool {
	if len(args) == 0 {
		return true
	}
	switch args[0] {
	case "help", "-h", "--help", "-v", "--version", "uninstall":
		return true
	}
	if args[0] == "workspace" && len(args) >= 2 {
		switch args[1] {
		case "stop":
			return true
		case "ports":
			if len(args) >= 3 {
				switch args[2] {
				case "disable", "stop", "loop", "agent":
					return true
				}
			}
		}
	}
	return false
}

// autoStartFolder returns the devzone folder of a command: the folder it just
// created when one exists, else DEVZONE_ROOT or the current folder. An empty
// string means the command was not issued from a devzone folder.
func autoStartFolder(args []string) string {
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		if target, err := filepath.Abs(args[0]); err == nil && isDevzoneFolder(target) {
			return target
		}
	}
	folder := os.Getenv("DEVZONE_ROOT")
	if folder == "" {
		var err error
		folder, err = os.Getwd()
		if err != nil {
			return ""
		}
	}
	if !isDevzoneFolder(folder) {
		return ""
	}
	return folder
}

// isDevzoneFolder reports whether folder holds the marker of a devzone, as the
// uninstall command does, so an ordinary folder never gets an installation.
func isDevzoneFolder(folder string) bool {
	info, err := os.Stat(filepath.Join(folder, ".devcontainer"))
	return err == nil && info.IsDir()
}
