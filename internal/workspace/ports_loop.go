package workspace

import (
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"syscall"
	"time"
)

// defaultStep is the pause between two rounds of the watcher (3 s in the shell).
const defaultStep = 3 * time.Second

// PortsStep reads the pause between two rounds from DEVZONE_PORTS_WORKSPACE_STEP,
// in seconds (a fraction is accepted, as sleep does). A missing, invalid or
// not positive value gives 3 s: the shell would spin or fail, a watcher that
// asks the cluster in a tight loop is never wanted.
func PortsStep() time.Duration {
	secs, err := strconv.ParseFloat(os.Getenv("DEVZONE_PORTS_WORKSPACE_STEP"), 64)
	if err != nil || !(secs > 0) || secs > 86400 {
		return defaultStep
	}
	return time.Duration(secs * float64(time.Second))
}

// PortsLoop is the watcher itself (pw_loop): one round, then a pause of step,
// until it is asked to stop. It exists so that relays follow the ports of the
// cluster while the user works. SIGHUP is ignored (the nohup of the shell), so
// that closing the terminal does not kill it. SIGTERM or SIGINT, also while it
// waits, removes its relays, its lock and its pid and returns 0 at once: the
// user who stops it must not wait for the end of a pause, and a stale lock
// would forbid the next start. The output of the rounds goes to the standard
// streams, which the start redirected to journal.log.
func PortsLoop(step time.Duration) int {
	signal.Ignore(syscall.SIGHUP)
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, os.Interrupt)
	dir := portsDir()
	for {
		select {
		case <-stop:
			return stopWatcher(dir)
		default:
		}
		PortsRound(os.Stdout, os.Stderr)
		select {
		case <-stop:
			return stopWatcher(dir)
		case <-time.After(step):
		}
	}
}

// stopWatcher is the trap of the shell loop: relays, then lock and pid.
func stopWatcher(dir string) int {
	removeRelays(dir)
	_ = os.RemoveAll(filepath.Join(dir, "lock"))
	_ = os.RemoveAll(filepath.Join(dir, "pid"))
	return 0
}
