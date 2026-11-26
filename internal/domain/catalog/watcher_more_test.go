package catalog

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// TestWatcherLockSingleInstance checks that a live lock cannot be taken by a
// second watcher, without waiting in the test: the clock is injected.
func TestWatcherLockSingleInstance(t *testing.T) {
	f := newFixture(t)
	lock := filepath.Join(f.root, "watcher", "lock")
	if err := os.MkdirAll(lock, 0o755); err != nil {
		t.Fatal(err)
	}
	writeTestFile(t, filepath.Join(lock, "pid"), itoa(os.Getpid()))
	base := time.Now()
	ticks := 0
	setWatcherClock(t, func() time.Time { return base.Add(time.Duration(ticks) * time.Second) },
		func(time.Duration) { ticks++ })
	e := newEnv(context.Background(), f.opts)
	if e.lockTake() {
		t.Fatal("lock taken while another watcher is alive")
	}
	if ticks < 5 {
		t.Fatalf("clock ticks = %d, want at least five before giving up", ticks)
	}
}

// TestWatcherLockStealsStale checks that an old lock with a live pid is stolen.
func TestWatcherLockStealsStale(t *testing.T) {
	f := newFixture(t)
	lock := filepath.Join(f.root, "watcher", "lock")
	if err := os.MkdirAll(lock, 0o755); err != nil {
		t.Fatal(err)
	}
	writeTestFile(t, filepath.Join(lock, "pid"), itoa(os.Getpid()))
	old := time.Now().Add(-40 * time.Second)
	if err := os.Chtimes(lock, old, old); err != nil {
		t.Fatal(err)
	}
	setWatcherClock(t, time.Now, func(time.Duration) {})
	e := newEnv(context.Background(), f.opts)
	if !e.lockTake() {
		t.Fatal("stale lock not stolen")
	}
	if pid := readWatcherPid(lock); pid != os.Getpid() {
		t.Fatalf("lock pid = %d, want %d", pid, os.Getpid())
	}
	e.lockRelease()
}

// TestWatcherLockStealsDead checks that a lock whose process is gone is stolen.
func TestWatcherLockStealsDead(t *testing.T) {
	f := newFixture(t)
	lock := filepath.Join(f.root, "watcher", "lock")
	if err := os.MkdirAll(lock, 0o755); err != nil {
		t.Fatal(err)
	}
	writeTestFile(t, filepath.Join(lock, "pid"), "999999\n")
	setWatcherClock(t, time.Now, func(time.Duration) {})
	e := newEnv(context.Background(), f.opts)
	if !e.lockTake() {
		t.Fatal("lock of a dead watcher not stolen")
	}
	e.lockRelease()
}

// TestWatcherRootsFromCodeFolder checks the root, state and watcher folders
// deduced from the shell entry point, two levels above the catalog folder.
func TestWatcherRootsFromCodeFolder(t *testing.T) {
	devzoneRoot := t.TempDir()
	code := filepath.Join(devzoneRoot, ".devcontainer")
	if err := os.MkdirAll(filepath.Join(code, "catalog"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DEVZONE_ROOT", "")
	t.Setenv("DEVZONE_STATE", "")
	t.Setenv("DEVZONE_CATALOG", "")
	t.Setenv("DEVZONE_CATALOG_WATCHER_DIR", "")
	e := newEnv(context.Background(), Options{CodeRoot: code})
	if e.root != devzoneRoot {
		t.Fatalf("root = %q, want %q", e.root, devzoneRoot)
	}
	wantState := filepath.Join(devzoneRoot, ".devzone.modules")
	if e.statePath != wantState {
		t.Fatalf("state = %q, want %q", e.statePath, wantState)
	}
	wantBase := filepath.Join(devzoneRoot, ".devzone.catalog-watcher")
	if e.watcher != wantBase {
		t.Fatalf("watcher dir = %q, want %q", e.watcher, wantBase)
	}
	if e.catalog != filepath.Join(code, "catalog") {
		t.Fatalf("catalog dir = %q", e.catalog)
	}
}

// setWatcherClock replaces the clock and the wait of the lock for one test.
func setWatcherClock(t *testing.T, now func() time.Time, sleep func(time.Duration)) {
	t.Helper()
	previousNow, previousSleep := watcherNow, watcherSleep
	watcherNow, watcherSleep = now, sleep
	t.Cleanup(func() { watcherNow, watcherSleep = previousNow, previousSleep })
}
