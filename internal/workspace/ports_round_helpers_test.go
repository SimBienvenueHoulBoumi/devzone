package workspace

import (
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// roundKubectl is the fake kubectl of the round tests: it logs its arguments in
// FAKE_LOG, replays the outputs set in FAKE_* and, for port-forward, becomes a
// sleep (exec: the pid of the relay is then the pid of the sleep, which a test
// can kill without leaving a child behind).
const roundKubectl = `#!/usr/bin/env bash
[ -z "$FAKE_LOG" ] || echo "$*" >>"$FAKE_LOG"
case "$*" in
*"config get-contexts"*) printf '%s' "$FAKE_CONTEXTS" ;;
*"get endpointslices"*) [ -z "$FAKE_READY_FAIL" ] || exit 1; printf '%s' "$FAKE_READY" ;;
*"get svc -A"*) printf '%s' "$FAKE_SVC" ;;
*"svc pgadmin"*) printf '%s' "$FAKE_PGADMIN" ;;
*"svc argocd-server"*) printf '%s' "$FAKE_ARGO" ;;
*"ss -ltnH"*) [ -z "$FAKE_SS_FAIL" ] || exit 1; printf '%s' "$FAKE_SS" ;;
*port-forward*) exec sleep 600 ;;
*) exit 1 ;;
esac
`

// roundHarness holds a folder with the fake kubectl first in the PATH and the
// modules file of the scenario under test.
type roundHarness struct {
	t       *testing.T
	dir     string
	modules string
}

// newRoundHarness skips on Windows and without bash, then installs the fake
// kubectl in the PATH of the test and its children.
func newRoundHarness(t *testing.T) *roundHarness {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("the fake kubectl of the round is a shell script")
	}
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("bash not found")
	}
	dir := t.TempDir()
	if err := os.Mkdir(filepath.Join(dir, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "bin", "kubectl"), []byte(roundKubectl), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", filepath.Join(dir, "bin")+string(os.PathListSeparator)+os.Getenv("PATH"))
	return &roundHarness{t: t, dir: dir, modules: filepath.Join(dir, ".devzone.modules")}
}

// use sets the answers of the fake kubectl and the modules file to the scenario.
func (h *roundHarness) use(s scenario, log string) {
	h.t.Helper()
	for _, kv := range append(s.env(), "FAKE_LOG="+log) {
		k, v, _ := strings.Cut(kv, "=")
		h.t.Setenv(k, v)
	}
	_ = os.Remove(h.modules)
	if !s.noModules {
		if err := os.WriteFile(h.modules, []byte(s.modules), 0o644); err != nil {
			h.t.Fatal(err)
		}
	}
}

// stateDir makes a state folder and, whatever happens in the test, kills every
// process named in its relays folder when the test ends.
func (h *roundHarness) stateDir(name string) string {
	dir := filepath.Join(h.dir, name)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		h.t.Fatal(err)
	}
	h.t.Cleanup(func() { killRelays(dir) })
	return dir
}

// killRelays stops the process of every file of dir/relays.
func killRelays(dir string) {
	for _, name := range stateNames(filepath.Join(dir, "relays")) {
		if pid := readPid(filepath.Join(dir, "relays", name)); pid > 0 {
			terminate(pid)
		}
	}
}

// liveProc tells whether pid is a running process: a zombie answers kill -0,
// so on Linux its state in /proc is read too.
func liveProc(pid int) bool {
	if !alive(pid) {
		return false
	}
	data, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/stat")
	if err != nil {
		return true
	}
	i := strings.LastIndex(string(data), ") ")
	return i < 0 || len(data) <= i+2 || data[i+2] != 'Z'
}

// liveRelays counts the files of dir/relays that name a running process.
func liveRelays(dir string) int {
	n := 0
	for _, name := range stateNames(filepath.Join(dir, "relays")) {
		if liveProc(readPid(filepath.Join(dir, "relays", name))) {
			n++
		}
	}
	return n
}

// seedRelay starts a sleep as the relay of a port and records it, like an
// earlier round would have; it is killed when the test ends.
func (h *roundHarness) seedRelay(dir string, port int) int {
	h.t.Helper()
	_ = os.MkdirAll(filepath.Join(dir, "relays"), 0o755)
	pid, err := startDetached(exec.Command("sleep", "600"))
	if err != nil {
		h.t.Fatal(err)
	}
	h.t.Cleanup(func() { terminate(pid) })
	file := filepath.Join(dir, "relays", strconv.Itoa(port))
	if err := os.WriteFile(file, []byte(strconv.Itoa(pid)+"\n"), 0o644); err != nil {
		h.t.Fatal(err)
	}
	return pid
}

// freePorts returns n distinct local ports that are free now.
func freePorts(t *testing.T, n int) []int {
	t.Helper()
	var listeners []net.Listener
	var ports []int
	for i := 0; i < n; i++ {
		l, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Skip("cannot listen on 127.0.0.1")
		}
		listeners = append(listeners, l)
		ports = append(ports, l.Addr().(*net.TCPAddr).Port)
	}
	for _, l := range listeners {
		_ = l.Close()
	}
	sort.Ints(ports)
	return ports
}

// holdPort listens on port until the returned function is called (or the test
// ends): the port is taken on the workstation for both the Go and the bash test.
func holdPort(t *testing.T, port int) (release func()) {
	t.Helper()
	l, err := net.Listen("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = l.Close() })
	return func() { _ = l.Close() }
}

// listenLine is one line of "ss -ltnH" for a port listening on all addresses.
func listenLine(port int) string {
	return "LISTEN 0 4096 0.0.0.0:" + strconv.Itoa(port) + " 0.0.0.0:*\n"
}

// svcLine is one line of the Service listing: a ClusterIP Service with one TCP port.
func svcLine(ns, name string, port int) string {
	return ns + "|" + name + "|10.0.0.1|ClusterIP||" + strconv.Itoa(port) + "/TCP,\n"
}

// readyLine is one line of the endpoint listing: a Service with a ready endpoint.
func readyLine(ns, name string) string {
	return ns + "|" + name + "|true,\n"
}

// readAll returns the content of a file, empty when it is missing.
func readAll(file string) string {
	data, _ := os.ReadFile(file)
	return string(data)
}
