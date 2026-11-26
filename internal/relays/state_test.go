package relays

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// writeState creates a disposable state file with the given content.
func writeState(t *testing.T, dir, content string) string {
	t.Helper()
	path := filepath.Join(dir, ".devzone.modules")
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

// TestPortListSortsAndDeduplicates fixes the state parsing: the last ports=
// line wins, ports are numeric and sorted, duplicates are removed.
func TestPortListSortsAndDeduplicates(t *testing.T) {
	path := writeState(t, t.TempDir(), "module=on\nports=3000,8080,8080\nports=90,9,bad\n")
	if got, want := PortList(path), []int{9, 90}; !reflect.DeepEqual(got, want) {
		t.Fatalf("PortList = %v, want %v", got, want)
	}
}

// TestPortListEmptyAndInvalid checks that an absent or empty value gives no
// relay and that an out-of-range state entry is still listed by the reader.
func TestPortListEmptyAndInvalid(t *testing.T) {
	path := writeState(t, t.TempDir(), "ports=\n")
	if got := PortList(path); len(got) != 0 {
		t.Fatalf("PortList = %v", got)
	}
	path = writeState(t, t.TempDir(), "ports=70000,0\n")
	if got, want := PortList(path), []int{0, 70000}; !reflect.DeepEqual(got, want) {
		t.Fatalf("PortList = %v, want %v", got, want)
	}
}

// TestWritePortsKeepsOtherLines checks the atomic state write and that the
// unknown lines and the order of the file survive a change of ports.
func TestWritePortsKeepsOtherLines(t *testing.T) {
	path := writeState(t, t.TempDir(), "module=on\nports=8080\nplatform=github\n")
	if err := WritePorts(path, []int{3000, 8080}); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	want := "module=on\nplatform=github\nports=3000,8080\n"
	if string(data) != want {
		t.Fatalf("state = %q, want %q", data, want)
	}
}

// TestAddAndRemovePort check the state transitions of a relay.
func TestAddAndRemovePort(t *testing.T) {
	path := writeState(t, t.TempDir(), "ports=3000\n")
	if err := AddPort(path, 8080); err != nil {
		t.Fatal(err)
	}
	if err := AddPort(path, 8080); err != nil {
		t.Fatal(err)
	}
	if got, want := PortList(path), []int{3000, 8080}; !reflect.DeepEqual(got, want) {
		t.Fatalf("after add: %v", got)
	}
	if err := RemovePort(path, 8080); err != nil {
		t.Fatal(err)
	}
	if got, want := PortList(path), []int{3000}; !reflect.DeepEqual(got, want) {
		t.Fatalf("after remove: %v", got)
	}
	if err := RemovePort(path, 3000); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil || string(data) != "ports=\n" {
		t.Fatalf("empty state = %q, %v", data, err)
	}
}

// TestValidPortAndRelayName fix the port range and the relay name contract.
func TestValidPortAndRelayName(t *testing.T) {
	for _, tc := range []struct {
		n    int
		want bool
	}{{0, false}, {1, true}, {8080, true}, {65535, true}, {65536, false}, {-1, false}} {
		if got := ValidPort(tc.n); got != tc.want {
			t.Fatalf("ValidPort(%d) = %v", tc.n, got)
		}
	}
	if got, want := RelayName("devzone", 8080), "devzone-devzone-port-8080"; got != want {
		t.Fatalf("RelayName = %q, want %q", got, want)
	}
}

// TestStatePathAndInstance fix the environment overrides used by the command.
func TestStatePathAndInstance(t *testing.T) {
	t.Setenv("DEVZONE_STATE", "/tmp/relay-test-state")
	t.Setenv("DEVZONE_INSTANCE", "atlas")
	if got := StatePath("/elsewhere"); got != "/tmp/relay-test-state" {
		t.Fatalf("StatePath = %q", got)
	}
	if got := Instance(); got != "atlas" {
		t.Fatalf("Instance = %q", got)
	}
	t.Setenv("DEVZONE_STATE", "")
	t.Setenv("DEVZONE_INSTANCE", "")
	if got, want := StatePath("/devzone"), filepath.Join("/devzone", ".devzone.modules"); got != want {
		t.Fatalf("StatePath = %q, want %q", got, want)
	}
	if got := Instance(); got != "devzone" {
		t.Fatalf("Instance = %q", got)
	}
}
