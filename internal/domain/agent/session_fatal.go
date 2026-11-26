package agent

import (
	"context"
	"os"
	"time"
)

// SessionFatalError stops current session when journal holds quota, country or
// filter since start: kill process+children, verify rights, exclude model,
// journal line; returns true. Shell session_fatal_error.
func SessionFatalError(ctx context.Context, r Runner, proc SessionProcess, journal string, offset int64, model, folder, stateDir string, requested []string, rightsJournal string, clock Clock) bool {
	output := tailFrom(journal, offset)
	cause := ErrorCause(ErrorLines(output))
	switch cause {
	case CauseQuota, CauseCountry, CauseFilter:
	default:
		return false
	}
	if proc != nil {
		proc.Kill()
	}
	RightsVerify(ctx, r, stateDir, folder, rightsJournal)
	ModelExclude(stateDir, model, cause, clockNow(clock))
	ModelRequestedExcluded(model, cause, journal, requested)
	appendLine(journal, "=== opencode/"+model+" excluded ("+CauseLabel(cause)+"): next model")
	return true
}

// tailFrom returns journal bytes from offset+1 (tail -c +offset+1).
func tailFrom(journal string, offset int64) string {
	data, err := os.ReadFile(journal)
	if err != nil {
		return ""
	}
	if offset < 0 {
		offset = 0
	}
	if offset >= int64(len(data)) {
		return ""
	}
	return string(data[offset:])
}

func clockNow(c Clock) time.Time {
	if c == nil {
		return time.Now()
	}
	return c.Now()
}
