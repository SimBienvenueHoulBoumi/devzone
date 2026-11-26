package catalog

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// TestWatcherGuard checks that a start never runs outside a real devzone.
func TestWatcherGuard(t *testing.T) {
	f := newFixture(t)
	if code := f.runWatcher("start"); code != 2 {
		t.Fatalf("start: code %d, want 2", code)
	}
	if !strings.Contains(f.errOut.String(), "refused here") {
		t.Fatalf("stderr = %q", f.errOut.String())
	}
	t.Setenv("DEVZONE_CATALOG_REAL", "yes")
	t.Setenv("BATS_TEST_TMPDIR", t.TempDir())
	f.errOut.Reset()
	if code := f.runWatcher("start"); code != 2 {
		t.Fatalf("start under bats: code %d, want 2", code)
	}
	if !strings.Contains(f.errOut.String(), "refused under bats") {
		t.Fatalf("stderr = %q", f.errOut.String())
	}
}

// TestWatcherTickOnChange checks that one tick follows a change of mtime and
// does not apply twice for the same date. The dates are set by the test, so no
// sleep and no real clock are needed.
func TestWatcherTickOnChange(t *testing.T) {
	f := newFixture(t)
	f.saveState("cluster=kind-devzone", "mysql=on")
	f.r.On("bash", []string{f.script, "state", "recovery-wait"}, fexec.Result{Code: 1})
	f.r.On("bash", []string{f.script, "state", "recovery-pending"}, fexec.Result{Code: 1})
	f.r.On("bash", []string{f.script, "catalog", "apply"}, fexec.Result{})
	first := time.Unix(1_700_000_000, 0)
	if err := os.Chtimes(f.statePath, first, first); err != nil {
		t.Fatal(err)
	}
	if code := f.runWatcher("tick"); code != 0 {
		t.Fatalf("tick: code %d, err %q", code, f.errOut.String())
	}
	if code := f.runWatcher("tick"); code != 0 {
		t.Fatalf("second tick: code %d", code)
	}
	count := 0
	for _, call := range f.r.Calls() {
		if call.Name == "bash" && len(call.Args) == 3 && call.Args[1] == "catalog" {
			count++
		}
	}
	if count != 1 {
		t.Fatalf("catalog apply called %d times, want 1", count)
	}
	last, err := os.ReadFile(filepath.Join(f.root, "watcher", "dernier"))
	if err != nil {
		t.Fatal(err)
	}
	if string(last) != "1700000000" {
		t.Fatalf("dernier = %q", last)
	}
	second := first.Add(10 * time.Second)
	if err := os.Chtimes(f.statePath, second, second); err != nil {
		t.Fatal(err)
	}
	if code := f.runWatcher("tick"); code != 0 {
		t.Fatalf("tick after change: code %d", code)
	}
	count = 0
	for _, call := range f.r.Calls() {
		if call.Name == "bash" && len(call.Args) == 3 && call.Args[1] == "catalog" {
			count++
		}
	}
	if count != 2 {
		t.Fatalf("catalog apply called %d times after the change, want 2", count)
	}
}

// TestWatcherTickWaitsForRecovery checks that a state under recovery is not applied.
func TestWatcherTickWaitsForRecovery(t *testing.T) {
	f := newFixture(t)
	f.saveState("cluster=kind-devzone", "mysql=on")
	f.r.On("bash", []string{f.script, "state", "recovery-wait"}, fexec.Result{})
	if code := f.runWatcher("tick"); code != 0 {
		t.Fatalf("tick: code %d", code)
	}
	for _, call := range f.r.Calls() {
		if call.Name == "bash" && len(call.Args) == 3 && call.Args[1] == "catalog" {
			t.Fatalf("apply ran during recovery: %s", formatCall(call))
		}
	}
}

// TestWatcherStartAlreadyRunning checks that a live lock is not duplicated.
func TestWatcherStartAlreadyRunning(t *testing.T) {
	f := newFixture(t)
	t.Setenv("DEVZONE_CATALOG_REAL", "yes")
	lock := filepath.Join(f.root, "watcher", "lock")
	if err := os.MkdirAll(lock, 0o755); err != nil {
		t.Fatal(err)
	}
	writeTestFile(t, filepath.Join(lock, "pid"), itoa(os.Getpid()))
	called := false
	setWatcherLaunch(t, func(*env) error { called = true; return nil })
	if code := f.runWatcher("start"); code != 0 {
		t.Fatalf("start: code %d", code)
	}
	if called || !strings.Contains(f.out.String(), "already running") {
		t.Fatalf("called = %v, output = %q", called, f.out.String())
	}
}

// TestWatcherStartDeadLoop checks that a loop that dies at once is reported.
func TestWatcherStartDeadLoop(t *testing.T) {
	f := newFixture(t)
	t.Setenv("DEVZONE_CATALOG_REAL", "yes")
	setWatcherLaunch(t, func(*env) error { return nil })
	setWatcherSleep(t, func(time.Duration) {})
	if code := f.runWatcher("start"); code == 0 {
		t.Fatal("start: code 0, want a failure when the loop dies")
	}
	if !strings.Contains(f.errOut.String(), "cannot start") {
		t.Fatalf("stderr = %q", f.errOut.String())
	}
}

// TestWatcherStopRemovesLock checks that stop kills the recorded pid and frees
// the lock; the kill is faked so the test never signals its own process.
func TestWatcherStopRemovesLock(t *testing.T) {
	f := newFixture(t)
	lock := filepath.Join(f.root, "watcher", "lock")
	if err := os.MkdirAll(lock, 0o755); err != nil {
		t.Fatal(err)
	}
	writeTestFile(t, filepath.Join(lock, "pid"), "4242\n")
	killed := 0
	previous := watcherKill
	watcherKill = func(pid int) error { killed = pid; return nil }
	t.Cleanup(func() { watcherKill = previous })
	if code := f.runWatcher("stop"); code != 0 {
		t.Fatalf("stop: code %d", code)
	}
	if killed != 4242 {
		t.Fatalf("killed pid = %d, want 4242", killed)
	}
	if _, err := os.Stat(lock); !os.IsNotExist(err) {
		t.Fatalf("lock left after stop: %v", err)
	}
	if got := f.out.String(); got != "stopped\n" {
		t.Fatalf("stop output = %q", got)
	}
}

// TestWatcherLoopStop checks that a loop holds one lock, ticks once and frees
// the lock on stop, with an injected stop channel and no real waiting.
func TestWatcherLoopStop(t *testing.T) {
	f := newFixture(t)
	f.saveState("cluster=kind-devzone", "mysql=on")
	f.r.On("bash", []string{f.script, "state", "recovery-wait"}, fexec.Result{Code: 1})
	f.r.On("bash", []string{f.script, "state", "recovery-pending"}, fexec.Result{Code: 1})
	stop := make(chan os.Signal, 1)
	stopper := &stoppingRunner{Runner: f.r, stop: stop}
	f.opts.Runner = stopper
	e := newEnv(context.Background(), f.opts)
	if code := e.watcherLoop(stop); code != 0 {
		t.Fatalf("loop: code %d", code)
	}
	if stopper.applies != 1 {
		t.Fatalf("applies = %d, want 1", stopper.applies)
	}
	if _, err := os.Stat(e.lockDir()); !os.IsNotExist(err) {
		t.Fatalf("lock left after loop: %v", err)
	}
}

// stoppingRunner closes the stop channel when the loop applies the catalog.
type stoppingRunner struct {
	*fake.Runner
	stop    chan os.Signal
	applies int
}

// Run implements exec.Runner and stops the loop after its first apply.
func (s *stoppingRunner) Run(ctx context.Context, name string, args []string, opts fexec.Opts) (fexec.Result, error) {
	res, err := s.Runner.Run(ctx, name, args, opts)
	if name == "bash" && len(args) == 3 && args[1] == "catalog" {
		s.applies++
		s.stop <- syscall.SIGTERM
	}
	return res, err
}

// setWatcherLaunch replaces the detached launch for one test.
func setWatcherLaunch(t *testing.T, fn func(*env) error) {
	t.Helper()
	previous := watcherLaunch
	watcherLaunch = fn
	t.Cleanup(func() { watcherLaunch = previous })
}

// setWatcherSleep replaces the wait for one test, so no test blocks.
func setWatcherSleep(t *testing.T, fn func(time.Duration)) {
	t.Helper()
	previous := watcherSleep
	watcherSleep = fn
	t.Cleanup(func() { watcherSleep = previous })
}

// itoa renders a decimal pid with a trailing newline.
func itoa(pid int) string { return strconv.Itoa(pid) + "\n" }
