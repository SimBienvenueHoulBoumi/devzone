//go:build !windows

package workspace

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/testkit"
)

// The binary of the end-to-end tests is built once for the whole package run,
// in a folder that TestMain removes at the end.
var (
	buildOnce sync.Once
	buildDir  string
	buildErr  error
)

// TestMain runs the suite with a clean Git environment and then removes the
// folder of the binary built once for the end-to-end tests.
func TestMain(m *testing.M) {
	code := testkit.Main(m)
	if buildDir != "" {
		_ = os.RemoveAll(buildDir)
	}
	os.Exit(code)
}

// devzoneBinary builds cmd/devzone once and returns its path; a test that
// needs it is skipped when the build is impossible (no go, no sources).
func devzoneBinary(t *testing.T) string {
	t.Helper()
	buildOnce.Do(func() {
		if _, err := exec.LookPath("go"); err != nil {
			buildErr = err
			return
		}
		dir, err := os.MkdirTemp("", "devzone-bin-")
		if err != nil {
			buildErr = err
			return
		}
		buildDir = dir
		cmd := exec.Command("go", "build", "-buildvcs=false", "-o", filepath.Join(dir, "devzone"), "./cmd/devzone")
		cmd.Dir = "../.."
		if out, err := cmd.CombinedOutput(); err != nil {
			buildErr = fmt.Errorf("%v: %s", err, out)
		}
	})
	if buildErr != nil {
		t.Skip("cannot build the devzone binary: ", buildErr)
	}
	return filepath.Join(buildDir, "devzone")
}

// proc is one line of the process table.
type proc struct {
	pid, ppid int
	args      string
}

// procTable reads the process table with ps (macOS and Linux).
func procTable() []proc {
	out, err := exec.Command("ps", "-axo", "pid=,ppid=,args=").Output()
	if err != nil {
		return nil
	}
	var table []proc
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		if len(f) < 3 {
			continue
		}
		pid, e1 := strconv.Atoi(f[0])
		ppid, e2 := strconv.Atoi(f[1])
		if e1 != nil || e2 != nil {
			continue
		}
		args := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(line), f[0]))
		args = strings.TrimSpace(strings.TrimPrefix(args, f[1]))
		table = append(table, proc{pid, ppid, args})
	}
	return table
}

// tree returns root and all its descendants in table.
func tree(table []proc, root int) []int {
	pids := []int{root}
	for i := 0; i < len(pids); i++ {
		for _, p := range table {
			if p.ppid == pids[i] && p.pid != pids[i] {
				pids = append(pids, p.pid)
			}
		}
	}
	return pids
}

// liveEnv is a workstation without cluster: a fake kubectl in the PATH that
// says one port listens in the pod, the real devzone binary, and state folders
// whose processes (watchers and relays) are all stopped when the test ends,
// whatever the result.
type liveEnv struct {
	t      *testing.T
	h      *roundHarness
	bin    string
	port   int
	states []string
	roots  []int
}

// newLiveEnv prepares the environment variables of a watcher: the state
// folder of the first state, a 1 s step, the guard of bats opened, and the
// answers of the fake kubectl.
func newLiveEnv(t *testing.T) *liveEnv {
	t.Helper()
	h := newRoundHarness(t)
	le := &liveEnv{t: t, h: h, bin: devzoneBinary(t), port: freePorts(t, 1)[0]}
	t.Setenv("BATS_TEST_TMPDIR", "")
	t.Setenv("DEVZONE_PORTS_WORKSPACE_REAL", "yes")
	t.Setenv("DEVZONE_PORTS_WORKSPACE_STEP", "1")
	t.Setenv("FAKE_LOG", "")
	t.Setenv("FAKE_SS", listenLine(le.port))
	t.Setenv("FAKE_CONTEXTS", "")
	t.Cleanup(le.reap)
	return le
}

// state names a state folder (not created) and sets it as the one of the
// watcher; its processes are stopped at the end of the test.
func (le *liveEnv) state(name string) string {
	dir := filepath.Join(le.h.dir, name)
	le.states = append(le.states, dir)
	le.t.Setenv("DEVZONE_PORTS_WORKSPACE_DIR", dir)
	return dir
}

// run runs the binary with the arguments and returns what it printed.
func (le *liveEnv) run(args ...string) string {
	le.t.Helper()
	cmd := exec.Command(le.bin, args...)
	cmd.Dir = le.h.dir
	out, err := cmd.Output()
	if err != nil {
		le.t.Fatalf("devzone %v: %v", args, err)
	}
	return string(out)
}

// useBinary makes PortsStart launch the built binary instead of the test one.
func (le *liveEnv) useBinary() {
	old := watcherExecutable
	watcherExecutable = func() (string, error) { return le.bin, nil }
	le.t.Cleanup(func() { watcherExecutable = old })
}

// relayPid waits for the relay of the port in dir and returns its live pid.
func (le *liveEnv) relayPid(dir string) int {
	le.t.Helper()
	file := filepath.Join(dir, "relays", strconv.Itoa(le.port))
	waitFor(le.t, "a live relay", func() bool { return liveProc(readPid(file)) })
	return readPid(file)
}

// reap stops every process the test may have left: the watchers named by the
// pid files or by the built binary, the tracked roots, their children and the
// relays. The watchers get SIGTERM first so that they clean up, the rest is
// killed, and a process still alive at the end fails the test.
func (le *liveEnv) reap() {
	table := procTable()
	roots := append([]int{}, le.roots...)
	for _, p := range table {
		if strings.Contains(p.args, le.bin+" workspace ports loop") {
			roots = append(roots, p.pid)
		}
	}
	var all []int
	for _, dir := range le.states {
		if pid := readPid(filepath.Join(dir, "pid")); pid > 0 {
			roots = append(roots, pid)
		}
		for _, name := range stateNames(filepath.Join(dir, "relays")) {
			all = append(all, readPid(filepath.Join(dir, "relays", name)))
		}
	}
	for _, r := range roots {
		if r > 1 {
			all = append(all, tree(table, r)...)
			terminate(r)
		}
	}
	time.Sleep(300 * time.Millisecond)
	for _, pid := range all {
		if pid > 1 && liveProc(pid) {
			_ = syscall.Kill(pid, syscall.SIGKILL)
		}
	}
	waitUntil(3*time.Second, func() bool {
		for _, pid := range all {
			if pid > 1 && liveProc(pid) {
				return false
			}
		}
		return true
	})
	for _, pid := range all {
		if pid > 1 && liveProc(pid) {
			le.t.Errorf("process %d is still alive after the test", pid)
		}
	}
}

// waitUntil polls cond until it holds or the delay is over.
func waitUntil(d time.Duration, cond func() bool) bool {
	for end := time.Now().Add(d); time.Now().Before(end); time.Sleep(10 * time.Millisecond) {
		if cond() {
			return true
		}
	}
	return cond()
}
