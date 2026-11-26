package catalog

import (
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// watcherStep is the pause between two ticks, 5 s as in the shell watcher.
func (e *env) watcherStep() time.Duration {
	if e.opts.Step > 0 {
		return e.opts.Step
	}
	secs, err := strconv.ParseFloat(setting("DEVZONE_CATALOG_WATCHER_STEP", ""), 64)
	if err != nil || !(secs > 0) || secs > 86400 {
		return 5 * time.Second
	}
	return time.Duration(secs * float64(time.Second))
}

// lockDir and lastFile are the single-instance lock and the last seen mtime.
func (e *env) lockDir() string  { return filepath.Join(e.watcher, "lock") }
func (e *env) lastFile() string { return filepath.Join(e.watcher, "dernier") }

// lockTake takes the mkdir lock atomically, stealing one whose process is gone
// or older than thirty seconds. It gives up after five seconds.
func (e *env) lockTake() bool {
	start := watcherNow()
	for {
		if err := os.Mkdir(e.lockDir(), 0o755); err == nil {
			_ = os.WriteFile(filepath.Join(e.lockDir(), "pid"), []byte(strconv.Itoa(os.Getpid())), 0o644)
			return true
		}
		now := watcherNow()
		stale := false
		if info, err := os.Stat(e.lockDir()); err == nil && now.Sub(info.ModTime()) > 30*time.Second {
			stale = true
		}
		pid := readWatcherPid(e.lockDir())
		if stale || (pid > 0 && !watcherAlive(pid)) {
			_ = os.RemoveAll(e.lockDir())
			continue
		}
		if now.Sub(start) >= 5*time.Second {
			return false
		}
		watcherSleep(time.Second)
	}
}

// lockRefresh keeps the lock date and pid current so that no other watcher
// steals it while this one is alive.
func (e *env) lockRefresh() {
	now := watcherNow()
	_ = os.Chtimes(e.lockDir(), now, now)
	_ = os.WriteFile(filepath.Join(e.lockDir(), "pid"), []byte(strconv.Itoa(os.Getpid())), 0o644)
}

// lockRelease removes the lock on a clean exit.
func (e *env) lockRelease() { _ = os.RemoveAll(e.lockDir()) }

// readWatcherPid returns the pid recorded in a lock, or zero.
func readWatcherPid(dir string) int {
	data, err := os.ReadFile(filepath.Join(dir, "pid"))
	if err != nil {
		return 0
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil || pid <= 0 {
		return 0
	}
	return pid
}

// watcherLoop runs ticks until a stop signal arrives, holding the single lock.
// The caller can pass its own stop channel, so a test never waits in a real loop.
func (e *env) watcherLoop(stop <-chan os.Signal) int {
	_ = os.MkdirAll(e.watcher, 0o755)
	if !e.lockTake() {
		return 0
	}
	defer e.lockRelease()
	if stop == nil {
		stop = watcherSignals()
	}
	for {
		select {
		case <-stop:
			return 0
		default:
		}
		e.lockRefresh()
		_ = e.tick()
		select {
		case <-stop:
			return 0
		case <-time.After(e.watcherStep()):
		}
	}
}

// watcherSignals ignores SIGHUP and turns SIGTERM and SIGINT into a stop.
func watcherSignals() <-chan os.Signal {
	signal.Ignore(syscall.SIGHUP)
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, os.Interrupt)
	return stop
}
