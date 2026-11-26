package catalog

import (
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

var (
	watcherNow        = time.Now
	watcherSleep      = time.Sleep
	watcherAlive      = processAlive
	watcherKill       = processKill
	watcherExecutable = os.Executable
	watcherLaunch     = launchWatcher
)

// WatcherRun dispatches a "devzone catalog-watcher" subcommand.
func WatcherRun(ctx context.Context, opts Options, args []string) int {
	e := newEnv(ctx, opts)
	if len(args) != 1 {
		e.warn("devzone : catalog-watcher : loop | start | stop | tick")
		return 2
	}
	switch args[0] {
	case "loop":
		if code := guardWatcher(e); code != 0 {
			return code
		}
		return e.watcherLoop(nil)
	case "start":
		if code := guardWatcher(e); code != 0 {
			return code
		}
		return e.startWatcher()
	case "stop":
		return e.stopWatcher()
	case "tick":
		if err := e.tick(); err != nil {
			e.warn("%v", err)
			return 1
		}
		return 0
	default:
		e.warn("devzone : catalog-watcher : loop | start | stop | tick")
		return 2
	}
}

// guardWatcher refuses to run the watcher outside a real devzone: under bats,
// a test must never leave a background process behind.
func guardWatcher(e *env) int {
	if setting("DEVZONE_CATALOG_REAL", "") != "yes" {
		e.warn("devzone : catalog-watcher : refused here (DEVZONE_CATALOG_REAL=yes)")
		return 2
	}
	if os.Getenv("BATS_TEST_TMPDIR") != "" {
		e.warn("devzone : catalog-watcher : refused under bats (tests)")
		return 2
	}
	return 0
}

// tick applies the catalog once when the state file changed since the last
// tick, unless the state is being recovered or confirmed.
func (e *env) tick() error {
	if _, err := os.Stat(e.statePath); err != nil {
		return nil
	}
	for _, check := range []string{"recovery-wait", "recovery-pending"} {
		res, err := e.exec("bash", []string{e.script, "state", check}, "DEVZONE_STATE="+e.statePath)
		if err == nil && res.Code == 0 {
			return nil
		}
	}
	if err := os.MkdirAll(e.watcher, 0o755); err != nil {
		return err
	}
	info, err := os.Stat(e.statePath)
	if err != nil {
		return nil
	}
	now := strconv.FormatInt(info.ModTime().Unix(), 10)
	previous, _ := os.ReadFile(e.lastFile())
	if now == strings.TrimSpace(string(previous)) {
		return nil
	}
	if err := os.WriteFile(e.lastFile(), []byte(now), 0o644); err != nil {
		return err
	}
	e.warn("devzone : catalog-watcher : .devzone.modules changed, applying")
	res, err := e.exec("bash", []string{e.script, "catalog", "apply"}, "DEVZONE_STATE="+e.statePath)
	if err != nil {
		return err
	}
	if e.opts.Out != nil && len(res.Stdout) > 0 {
		_, _ = io.WriteString(e.opts.Out, string(res.Stdout))
	}
	if e.opts.Err != nil && len(res.Stderr) > 0 {
		_, _ = io.WriteString(e.opts.Err, string(res.Stderr))
	}
	if res.Code != 0 {
		return errors.New("devzone catalog apply failed")
	}
	return nil
}

// startWatcher starts one detached loop and checks that its lock stays alive.
func (e *env) startWatcher() int {
	_ = os.MkdirAll(e.watcher, 0o755)
	if pid := readWatcherPid(e.lockDir()); pid > 0 && watcherAlive(pid) {
		e.out("already running")
		return 0
	}
	if err := watcherLaunch(e); err != nil {
		e.warn("devzone : catalog-watcher : cannot start, see %s", filepath.Join(e.watcher, "veilleur.log"))
		return 1
	}
	stable := 0
	for i := 0; i < 20; i++ {
		if pid := readWatcherPid(e.lockDir()); pid > 0 && watcherAlive(pid) {
			stable++
			if stable >= 5 {
				e.out("started")
				return 0
			}
		} else {
			stable = 0
		}
		watcherSleep(100 * time.Millisecond)
	}
	e.warn("devzone : catalog-watcher : cannot start, see %s", filepath.Join(e.watcher, "veilleur.log"))
	return 1
}

// launchWatcher starts this binary's watcher loop detached, with its output in
// veilleur.log, as nohup and setsid did for the shell watcher.
func launchWatcher(e *env) error {
	exe, err := watcherExecutable()
	if err != nil {
		return err
	}
	log, err := os.OpenFile(filepath.Join(e.watcher, "veilleur.log"),
		os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer log.Close()
	cmd := exec.Command(exe, "catalog-watcher", "loop")
	cmd.Env = append(os.Environ(), "DEVZONE_CATALOG_REAL=yes")
	cmd.Stdout, cmd.Stderr = log, log
	_, err = startDetachedWatcher(cmd)
	return err
}

// stopWatcher kills the live watcher and removes its lock, as the shell trap did.
func (e *env) stopWatcher() int {
	if pid := readWatcherPid(e.lockDir()); pid > 0 {
		_ = watcherKill(pid)
	}
	e.lockRelease()
	e.out("stopped")
	return 0
}
