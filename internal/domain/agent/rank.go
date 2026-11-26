package agent

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// RankTake takes the shared rank and returns the start of the rotation (#421).
// Advances only when no requested model is available (#420); writes
// "=== rank <start+1>/<total>" to the journal; the shell rank_take.
func RankTake(ctx context.Context, r Runner, stateDir, journal string, clock Clock, pid int, total int, requested []string, excluded func(model string) bool) (int, bool) {
	l := LockTake(ctx, r, stateDir, journal, clock, pid)
	if l == nil {
		return 0, false
	}
	start := 0
	if data, err := os.ReadFile(filepath.Join(stateDir, "rang")); err == nil {
		if n, err := strconv.Atoi(strings.TrimSpace(string(data))); err == nil {
			if total > 0 {
				start = n % total
			}
		}
	}
	// Pause between read and write of the rank (tests only, shell PAUSE_RANK).
	if os.Getenv("DEVZONE_AGENT_PAUSE_RANK") != "" && os.Getenv("BATS_TEST_TMPDIR") != "" {
		if pause := envFloat("DEVZONE_AGENT_PAUSE_RANK", 0); pause > 0 {
			clock.Sleep(durationSec(pause))
		}
	}
	if rankAdvance(requested, excluded) {
		os.WriteFile(filepath.Join(stateDir, "rang"), []byte(strconv.Itoa(start+1)+"\n"), 0o644)
	}
	l.LockRelease()
	appendLine(journal, fmt.Sprintf("=== rank %d/%d", start+1, total))
	return start, true
}

// rankAdvance is true when no requested model is available (#420).
func rankAdvance(requested []string, excluded func(string) bool) bool {
	for _, m := range requested {
		if !excluded(m) {
			return false
		}
	}
	return true
}

// nowUnix returns current epoch seconds.
func nowUnix(clock Clock) int64 {
	if clock == nil {
		return time.Now().Unix()
	}
	return clock.Now().Unix()
}
