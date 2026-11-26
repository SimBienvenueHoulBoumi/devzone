// Package relays lists and closes the workstation port relays kept in the
// state file. It replaces .devcontainer/ports.sh and ports-json.sh (#881):
// kubectl runs through an injected exec.Runner and the application probe is
// injected, so no command needs a cluster or the network.
package relays

import (
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/state"
)

// ValidPort reports whether n is a usable workstation port.
func ValidPort(n int) bool { return n >= 1 && n <= 65535 }

// RelayName returns the name of the relay of port n for an instance.
func RelayName(instance string, n int) string {
	return "devzone-" + instance + "-port-" + strconv.Itoa(n)
}

// PortList returns the ports of the state, numerically sorted without
// duplicates, as the sort_ports shell function did.
func PortList(stateFile string) []int {
	value := state.At(stateFile).Get("ports")
	if value == "" {
		return nil
	}
	seen := map[int]bool{}
	var ports []int
	for _, field := range strings.Split(value, ",") {
		field = strings.TrimSpace(field)
		if field == "" || strings.Trim(field, "0123456789") != "" {
			continue
		}
		n, err := strconv.Atoi(field)
		if err != nil || seen[n] {
			continue
		}
		seen[n] = true
		ports = append(ports, n)
	}
	sort.Ints(ports)
	return ports
}

// WritePorts replaces the ports= line of the state atomically, keeping the
// other lines in order. An empty list writes an empty value, as the shell did.
func WritePorts(stateFile string, ports []int) error {
	values := make([]string, 0, len(ports))
	for _, n := range ports {
		values = append(values, strconv.Itoa(n))
	}
	return state.At(stateFile).Set("ports", strings.Join(values, ","))
}

// AddPort adds a port to the state, without duplicates.
func AddPort(stateFile string, n int) error {
	ports := PortList(stateFile)
	for _, port := range ports {
		if port == n {
			return nil
		}
	}
	ports = append(ports, n)
	sort.Ints(ports)
	return WritePorts(stateFile, ports)
}

// RemovePort removes a port from the state, keeping the other ports in order.
func RemovePort(stateFile string, n int) error {
	rest := make([]int, 0, len(PortList(stateFile)))
	for _, port := range PortList(stateFile) {
		if port != n {
			rest = append(rest, port)
		}
	}
	return WritePorts(stateFile, rest)
}

// StatePath returns the state file named by DEVZONE_STATE, or the default file
// of the devzone root, never the current folder.
func StatePath(root string) string {
	if named := os.Getenv("DEVZONE_STATE"); named != "" {
		return named
	}
	return filepath.Join(root, ".devzone.modules")
}

// Instance returns the devzone instance name used in relay labels.
func Instance() string {
	if name := os.Getenv("DEVZONE_INSTANCE"); name != "" {
		return name
	}
	return "devzone"
}
