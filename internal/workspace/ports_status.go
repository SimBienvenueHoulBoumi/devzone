package workspace

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// PortsStatus writes the status of the workstation port watcher, as ports_status
// does: the watcher line, then the automatic start of the watcher, the relays, the
// ports reported taken, the relayed applications and those without a ready pod.
// It repairs an automatic start that is present but not loaded, or missing while
// still wanted, and says so in place of the enabled line. It reads the state
// folder of portsDir() and returns 0 even when that folder is missing or
// unreadable. Outside a devzone folder it refuses with status 1.
func PortsStatus(out io.Writer) int {
	if portsDevzoneGuard(out) {
		return 1
	}
	dir := portsDir()
	pid := readPid(filepath.Join(dir, "pid"))
	if alive(pid) {
		fmt.Fprintf(out, "Port watcher: running (pid %d)\n", pid)
	} else {
		fmt.Fprintln(out, "Port watcher: stopped")
	}
	if line := portsRepairAutoStart(out); line != "" {
		fmt.Fprintln(out, line)
	} else if portsAutoStartActive() {
		fmt.Fprintln(out, "Port watcher automatic start: enabled")
	} else {
		fmt.Fprintln(out, "Port watcher automatic start: disabled")
	}
	for _, name := range stateNames(filepath.Join(dir, "relays")) {
		if alive(readPid(filepath.Join(dir, "relays", name))) {
			fmt.Fprintf(out, "  127.0.0.1:%s relayed\n", name)
		}
	}
	for _, name := range stateNames(filepath.Join(dir, "taken")) {
		fmt.Fprintf(out, "  ⚠ port %s already in use on the workstation, not relayed\n", name)
	}
	for _, key := range stateNames(filepath.Join(dir, "apps")) {
		local := readState(filepath.Join(dir, "apps", key))
		if !alive(readPid(filepath.Join(dir, "relays", local))) {
			continue
		}
		fmt.Fprintf(out, "  http://127.0.0.1:%s  %s/%s:%s\n", local,
			beforeDot(key), beforeDot(afterDot(key)), afterDot(afterDot(key)))
	}
	for _, key := range stateNames(filepath.Join(dir, "no-ready-pod")) {
		local := readState(filepath.Join(dir, "apps", key))
		if local == "" {
			continue
		}
		fmt.Fprintf(out, "  http://127.0.0.1:%s  %s/%s:%s  no ready pod\n", local,
			beforeDot(key), beforeDot(afterDot(key)), afterDot(afterDot(key)))
	}
	return 0
}

// PortsAutoStartExists reports whether this devzone folder has an automatic
// start definition to retire. It lets a caller announce a disabled start only
// when there really was one.
func PortsAutoStartExists() bool {
	return portsAgentExists()
}

// PortsStop stops the port watcher and all its relays, as ports_stop does, by
// calling stopPorts. Nothing is printed and the status is 0.
func PortsStop() int {
	stopPorts()
	return 0
}

// portsAutoStartActive reports whether the automatic start of the port watcher
// is enabled, through the automatic start file of the devzone instance (the
// launch agent or the user unit); as a var it is injectable in tests.
var portsAutoStartActive = func() bool { return portsAgentExists() }

// stateNames returns the names of the entries of a state folder, sorted as the
// shell glob sorts them, without the hidden ones it ignores. A missing folder
// has no entry.
func stateNames(dir string) []string {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	names := make([]string, 0, len(entries))
	for _, entry := range entries {
		name := entry.Name()
		if strings.HasPrefix(name, ".") {
			continue
		}
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

// readState returns the content of a state file without its trailing newlines,
// as the command substitution of the shell does. A missing file is empty.
func readState(file string) string {
	data, err := os.ReadFile(file)
	if err != nil {
		return ""
	}
	return strings.TrimRight(string(data), "\n")
}

// beforeDot returns what precedes the first dot of s, afterDot what follows it,
// as ${s%%.*} and ${s#*.} do: without a dot both return s.
func beforeDot(s string) string {
	if i := strings.Index(s, "."); i >= 0 {
		return s[:i]
	}
	return s
}

func afterDot(s string) string {
	if i := strings.Index(s, "."); i >= 0 {
		return s[i+1:]
	}
	return s
}
