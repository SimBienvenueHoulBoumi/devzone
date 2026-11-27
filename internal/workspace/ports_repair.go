package workspace

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
)

// portsAutoStartWantedName is the state marker of a watcher whose automatic
// start the user wants. Why: a definition can disappear while the choice stays,
// so start and status can recreate it instead of leaving the watcher unmanaged.
const portsAutoStartWantedName = "autostart"

// The two repair lines are short enough to be read once by a user who only
// asked for a start or a status.
const (
	portsReloadedLine  = "Port watcher automatic start: present but not loaded, reloaded"
	portsRecreatedLine = "Port watcher automatic start: definition missing, recreated"
	portsRepairErrLine = "⚠ port watcher automatic start could not be repaired"
)

// portsAutoStartWantedFile returns the marker of the wanted automatic start in
// the state folder of this devzone folder, so every repair uses the same path.
func portsAutoStartWantedFile() string {
	return filepath.Join(portsDir(), portsAutoStartWantedName)
}

// rememberPortsAutoStartWanted records that the watcher has an automatic start,
// so a later start or status can recreate its definition if it disappears.
func rememberPortsAutoStartWanted() {
	dir := portsDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return
	}
	_ = os.WriteFile(portsAutoStartWantedFile(), []byte("enabled\n"), 0o644)
}

// forgetPortsAutoStartWanted records that the watcher no longer has an
// automatic start. A missing marker is not an error, so disable stays idempotent.
func forgetPortsAutoStartWanted() {
	_ = os.Remove(portsAutoStartWantedFile())
}

// portsAutoStartWanted reports whether this folder has an automatic start to
// repair, either through its definition or through the state marker, so a
// vanished definition can still be recreated.
func portsAutoStartWanted() bool {
	if info, err := os.Stat(portsAutoStartWantedFile()); err == nil && !info.IsDir() {
		return true
	}
	return portsAgentExists()
}

// portsDaemonLoaded reports whether the service manager currently knows the
// watcher service. The query is quiet so a missing service prints no usage text.
func portsDaemonLoaded() bool {
	tool := portsDaemonTool()
	return portsDaemon(tool, true, portsDaemonLoadedArgs()...) == 0
}

// portsRepairAutoStart reloads a definition that is present but not loaded, or
// recreates a missing one when the state marker says it is wanted. Why: an
// unloaded launch agent leaves no relay after a reboot, and the user must not
// have to discover that by running ports enable by hand. It returns the single
// line to show, or an empty string when nothing needed repair.
func portsRepairAutoStart(errOut io.Writer) string {
	if PortsRefused() || PortsAutoStartFailed() || !portsAutoStartWanted() {
		return ""
	}
	if !portsAgentExists() {
		if code := PortsEnable(io.Discard, io.Discard); code != 0 {
			fmt.Fprintf(errOut, "%s (enable failed with status %d)\n", portsRepairErrLine, code)
			return ""
		}
		return portsRecreatedLine
	}
	if portsDaemonLoaded() {
		return ""
	}
	if !portsReloadDefinition(portsDaemonTool()) {
		fmt.Fprintf(errOut, "%s (reload failed)\n", portsRepairErrLine)
		return ""
	}
	return portsReloadedLine
}

// portsReloadDefinition registers the existing definition again with the
// service manager, unloading an old launch agent first. Why: launchctl refuses
// bootstrap of a label it still knows, while schtasks /F and systemctl enable
// --now replace what they already have.
func portsReloadDefinition(tool string) bool {
	definition := filepath.Join(portsAgentDir(), portsAgentName()+"."+portsAgentExt())
	if portsPlatform == "darwin" {
		// bootout of a service that is not loaded fails and is ignored: the
		// following bootstrap is the repair in both cases.
		_ = portsDaemon(tool, true, "bootout", portsDaemonServiceTarget())
	}
	if portsDaemon(tool, true, portsDaemonEnableArgs(definition)...) != 0 {
		return false
	}
	if portsPlatform == "windows" {
		return portsDaemon(tool, true, portsDaemonStartArgs()...) == 0
	}
	return true
}
