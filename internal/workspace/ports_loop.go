package workspace

import (
	"io"
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
	return portsLoop(os.Stdout, os.Stderr, step)
}

// portsLoopRunner is the loop run by the automatic start. It is a variable so
// that a test can check that no second watcher starts, without waiting in a
// real loop.
var portsLoopRunner = portsLoop

// portsLoopRound and portsLoopTrim are the two actions of each round. They are
// variables so a test can drive the loop with fakes: no real kubectl is called
// and no real journal has to grow past its limit.
var (
	portsLoopRound = PortsRound
	portsLoopTrim  = trimJournal
)

// portsLoop runs the watcher until it is asked to stop, writing its rounds to
// the two streams given by the caller, so the agent can use the journal.
func portsLoop(out, errOut io.Writer, step time.Duration) int {
	signal.Ignore(syscall.SIGHUP)
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, os.Interrupt)
	return portsLoopUntil(out, errOut, step, stop)
}

// portsLoopUntil runs watcher rounds until stop is signalled, trimming the
// journal before each round so it stays bounded for the whole life of the loop.
// The caller owns the stop channel, which makes the loop testable without
// sending a signal to the test process.
func portsLoopUntil(out, errOut io.Writer, step time.Duration, stop <-chan os.Signal) int {
	dir := portsDir()
	for {
		select {
		case <-stop:
			return stopWatcher(dir)
		default:
		}
		portsLoopTrim(dir)
		portsLoopRound(out, errOut)
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
