package workspace

import (
	"os"
	"path/filepath"
)

// portsRefusalName is the marker of a user who refused the automatic start in
// this devzone folder. It lives in the folder so two devzone folders keep their
// own choice and an update never carries the choice from one to the other.
const portsRefusalName = ".devzone.ports-disabled"

// portsRefusalFile returns the marker of the refusal of the current devzone
// folder, as portsDevzoneFolder resolves it for the automatic start.
func portsRefusalFile() string {
	return filepath.Join(portsDevzoneFolder(), portsRefusalName)
}

// PortsRefused reports whether the user refused the automatic start in this
// devzone folder. A marker that is a folder, or unreadable, is not a refusal.
func PortsRefused() bool {
	info, err := os.Stat(portsRefusalFile())
	return err == nil && !info.IsDir()
}

// MemorizePortsRefusal writes the refusal marker in the devzone folder so no
// later command reinstalls the automatic start after ports disable or
// uninstall. The marker is only written inside a real devzone folder, and it
// is not a package file, so update leaves it alone.
func MemorizePortsRefusal() {
	folder := portsDevzoneFolder()
	if _, err := os.Stat(filepath.Join(folder, ".devcontainer")); err != nil {
		return
	}
	_ = os.WriteFile(filepath.Join(folder, portsRefusalName), []byte("ports disabled\n"), 0o644)
}

// ForgetPortsRefusal removes the refusal marker so ports enable can install the
// automatic start again. Removing an absent marker is not an error.
func ForgetPortsRefusal() {
	_ = os.Remove(portsRefusalFile())
}
