package agent

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// AgentExclusions lists current exclusions for `agent state` (muet- too,
// without cause), one line each. Shell agent_exclusions.
func AgentExclusions(stateDir string, now time.Time) string {
	return orderedExclusions(stateDir, now)
}

func orderedExclusions(stateDir string, now time.Time) string {
	var out []string
	for _, f := range globDir(stateDir, "ecart-*") {
		model := strings.TrimPrefix(base(f), "ecart-")
		e, cause, d := readExclusion(f)
		dur := d
		if dur == 0 {
			dur = 3600
		}
		if now.Unix() >= e+dur {
			continue
		}
		out = append(out, fmt.Sprintf("  model %s excluded (%s) until %s", model, CauseLabel(cause), UTCTime(e+dur)))
	}
	for _, f := range globDir(stateDir, "muet-*") {
		model := strings.TrimPrefix(base(f), "muet-")
		eStr := strings.TrimSpace(readFileString(f))
		if eStr == "" {
			continue
		}
		e := parseInt64(eStr)
		if now.Unix() >= e+3600 {
			continue
		}
		out = append(out, fmt.Sprintf("  model %s excluded (silent) until %s", model, UTCTime(e+3600)))
	}
	return strings.Join(out, "\n")
}

// ExclusionClear lifts exclusion of model, or all with --all. Shell exclusion_clear.
func ExclusionClear(stateDir, arg string) error {
	if arg == "--all" {
		for _, pat := range []string{"ecart-*", "muet-*"} {
			for _, f := range globDir(stateDir, pat) {
				os.Remove(f)
			}
		}
		return nil
	}
	os.Remove(filepath.Join(stateDir, "ecart-"+arg))
	os.Remove(filepath.Join(stateDir, "muet-"+arg))
	return nil
}

func globDir(dir, pattern string) []string {
	matches, _ := filepath.Glob(filepath.Join(dir, pattern))
	sort.Strings(matches)
	return matches
}

func base(p string) string { return filepath.Base(p) }

func parseInt64(s string) int64 {
	var n int64
	for _, c := range s {
		if c < '0' || c > '9' {
			if c == '-' && n == 0 {
				continue
			}
			break
		}
		n = n*10 + int64(c-'0')
	}
	return n
}

// NetworkReachable: opencode.ai resolves and answers HTTPS, one try no wait.
// Shell network_reachable: getent hosts opencode.ai && curl -sI --max-time 5.
func NetworkReachable(ctx context.Context, r Runner) bool {
	if r == nil {
		return false
	}
	res, err := r.Run(ctx, "getent", []string{"hosts", "opencode.ai"}, Opts{})
	if err != nil || res.Code != 0 {
		return false
	}
	res, err = r.Run(ctx, "curl", []string{"-sI", "--max-time", "5", "https://opencode.ai"}, Opts{})
	return err == nil && res.Code == 0
}

// NetworkWait waits for the network to come back: a try every
// DEVZONE_AGENT_NETWORK_STEP s for DEVZONE_AGENT_NETWORK_MAX s. Returns true
// when it is back. Shell network_wait; journal lines appended to journal.
func NetworkWait(ctx context.Context, r Runner, clock Clock, journal string) bool {
	maxSec := envInt("DEVZONE_AGENT_NETWORK_MAX", 1800)
	stepSec := envFloat("DEVZONE_AGENT_NETWORK_STEP", 30)
	end := clock.Now().Add(time.Duration(maxSec) * time.Second)
	appendLine(journal, "=== network down, waiting")
	for clock.Now().Before(end) {
		if NetworkReachable(ctx, r) {
			appendLine(journal, "=== network back")
			return true
		}
		clock.Sleep(durationSec(stepSec))
	}
	return false
}
