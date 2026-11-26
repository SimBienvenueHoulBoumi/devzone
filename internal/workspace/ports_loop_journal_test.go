//go:build !windows

package workspace

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestTrimJournalKeepsOpenDescriptor checks that trimming rewrites the journal
// in place: the watcher's open descriptor must still append to the live file.
func TestTrimJournalKeepsOpenDescriptor(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "journal.log")
	writeFile(t, path, strings.Repeat("x", maxJournalBytes+100))
	journal, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	defer journal.Close()
	trimJournal(dir)
	if _, err := journal.WriteString("after\n"); err != nil {
		t.Fatalf("write after trim: %v", err)
	}
	if err := journal.Close(); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(string(data), "after\n") || len(data) > maxJournalBytes/2+len("after\n") {
		t.Fatalf("journal size = %d, suffix = %q", len(data), string(data[len(data)-8:]))
	}
}

// TestPortsLoopTrimsJournalWhileRunning checks that a long loop keeps the
// journal bounded between rounds, not only before the first one. The rounds and
// the stop signal are injected: no cluster or watcher process is touched.
func TestPortsLoopTrimsJournalWhileRunning(t *testing.T) {
	h := newPortsEnableHarness(t)
	oldRound, oldTrim := portsLoopRound, portsLoopTrim
	t.Cleanup(func() { portsLoopRound, portsLoopTrim = oldRound, oldTrim })
	stop := make(chan os.Signal, 1)
	rounds, trims := 0, 0
	portsLoopRound = func(io.Writer, io.Writer) int {
		rounds++
		if rounds == 3 {
			stop <- os.Interrupt
		}
		return 0
	}
	portsLoopTrim = func(string) { trims++ }
	if code := portsLoopUntil(io.Discard, io.Discard, time.Millisecond, stop); code != 0 {
		t.Fatalf("loop status = %d", code)
	}
	if rounds != 3 || trims != 3 {
		t.Fatalf("rounds = %d, trims = %d, want 3 and 3", rounds, trims)
	}
	if exists(filepath.Join(h.stateDir, "pid")) || exists(filepath.Join(h.stateDir, "lock")) {
		t.Fatal("loop left a pid or a lock")
	}
}
