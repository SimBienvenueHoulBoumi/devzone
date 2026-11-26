package agent

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// JournalOf returns journal path of a folder in workspace/.agents/ (#328):
// $RACINE/workspace/.agents/<basename>.log, outside the repo.
func JournalOf(racine, folder string) string {
	return filepath.Join(racine, "workspace", ".agents", filepath.Base(folder)+".log")
}

// MTime returns last write time (epoch seconds).
func MTime(p string) int64 {
	info, err := os.Stat(p)
	if err != nil {
		return 0
	}
	return info.ModTime().Unix()
}

// UTCTime renders an epoch as UTC "YYYY-MM-DD HH:MM:SS" (agent state).
func UTCTime(epoch int64) string {
	return time.Unix(epoch, 0).UTC().Format("2006-01-02 15:04:05")
}

// ISO renders an epoch as UTC ISO-8601 "YYYY-MM-DDTHH:MM:SSZ".
func ISO(epoch int64) string {
	return time.Unix(epoch, 0).UTC().Format("2006-01-02T15:04:05Z")
}

// lock is the shared-rank lock (#377, #421): mkdir atomic + pid + flock.
type lock struct {
	stateDir string
	clock    Clock
	journal  string
	pid      int
	flock    *os.File
	held     bool
}

// lockTrace writes a journal line when a journal is set.
func (l *lock) lockTrace(kind, mention string) {
	if l.journal == "" {
		return
	}
	d := fmt.Sprintf("%d.%09d", l.clock.Now().Unix(), l.clock.Now().Nanosecond())
	line := fmt.Sprintf("=== lock %s %s pid %d", kind, d, l.pid)
	if mention != "" {
		line += " " + mention
	}
	appendLine(l.journal, line)
}

// LockTake takes the shared rank lock; orphan purge after 30 s, waits up to
// DEVZONE_AGENT_LOCK_MAX (10 s), then flock rang.lock when flock exists.
func LockTake(ctx context.Context, r Runner, stateDir, journal string, clock Clock, pid int) *lock {
	l := &lock{stateDir: stateDir, clock: clock, journal: journal, pid: pid}
	maxSec := envInt("DEVZONE_AGENT_LOCK_MAX", 10)
	end := clock.Now().Add(time.Duration(maxSec) * time.Second)
	lockDir := filepath.Join(stateDir, "lock")
	for {
		if err := os.Mkdir(lockDir, 0o755); err == nil {
			break
		}
		age := int64(-1)
		if info, err := os.Stat(lockDir); err == nil {
			age = clock.Now().Unix() - info.ModTime().Unix()
			if age < 0 {
				age = 0
			}
		}
		lockPid := strings.TrimSpace(readFileString(filepath.Join(lockDir, "pid")))
		if lockPid == "" {
			lockPid = "none"
		}
		ageStr := "unknown"
		if age >= 0 {
			ageStr = strconv.FormatInt(age, 10)
		}
		l.lockTrace("mkdir failed", "age="+ageStr+" lock-pid="+lockPid)
		if age >= 0 && age > 30 {
			os.Remove(filepath.Join(lockDir, "pid"))
			if err := os.Remove(lockDir); err == nil {
				l.lockTrace("purged", "age="+ageStr)
				continue
			}
		}
		if !clock.Now().Before(end) {
			return nil
		}
		clock.Sleep(time.Second)
	}
	os.WriteFile(filepath.Join(lockDir, "pid"), []byte(strconv.Itoa(pid)+"\n"), 0o644)
	if flockAvailable() {
		f, err := os.OpenFile(filepath.Join(stateDir, "rang.lock"), os.O_CREATE|os.O_RDWR, 0o644)
		if err == nil && flockWait(f, maxSec) {
			l.flock = f
			l.held = true
		} else {
			if f != nil {
				f.Close()
			}
			l.LockRelease()
			return nil
		}
	}
	l.lockTrace("taken", "path="+lockDir)
	return l
}

// flockAvailable reports whether a flock binary exists (shell `command -v flock`).
func flockAvailable() bool {
	_, err := exec.LookPath("flock")
	return err == nil
}

// LockRelease releases the lock; only when this lock belongs to us (pid match).
func (l *lock) LockRelease() {
	if l == nil {
		return
	}
	pidFile := filepath.Join(l.stateDir, "lock", "pid")
	got := strings.TrimSpace(readFileString(pidFile))
	if got == strconv.Itoa(l.pid) {
		os.Remove(pidFile)
		if err := os.Remove(filepath.Join(l.stateDir, "lock")); err == nil {
			l.lockTrace("released", "")
		}
	}
	if l.flock != nil {
		flockUnlock(l.flock)
		l.flock.Close()
		l.flock = nil
		l.held = false
	}
}

// SessionModelStart reads model and start from the last supervisor
// "=== model opencode/<m> start <ts>" line; text written by the model is not read.
func SessionModelStart(journal string) (model, start string) {
	var line string
	for _, l := range strings.Split(readFileString(journal), "\n") {
		if strings.HasPrefix(l, "=== model opencode/") {
			line = l
		}
	}
	rest := strings.TrimPrefix(line, "=== model opencode/")
	if i := strings.Index(rest, " start "); i >= 0 {
		model = rest[:i]
		start = rest[i+len(" start "):]
		if j := strings.Index(start, " "); j >= 0 {
			start = start[:j]
		}
	}
	return model, start
}

// SessionRequest reads requested models from the last "=== --model : " header;
// empty when nothing was asked ("none"). Shell session_request.
func SessionRequest(journal string) string {
	var line string
	for _, l := range strings.Split(readFileString(journal), "\n") {
		if strings.HasPrefix(l, "=== --model : ") {
			line = l
		}
	}
	req := strings.TrimPrefix(line, "=== --model : ")
	if req == "none" {
		return ""
	}
	return req
}
