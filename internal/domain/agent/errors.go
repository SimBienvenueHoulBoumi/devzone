package agent

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Known opencode error texts (grep -E); causeOf takes the cause from them.
const Errors = "not available in your country|Free usage limit|content filter|Model is unavailable|Upstream request failed|ProviderHeaderTimeout|ENOTFOUND|ECONNREFUSED|ETIMEDOUT|EAI_AGAIN|ECONNRESET|fetch failed|network"

// ErrorLinePrefix matches an opencode error line; Erreur stays for French output.
const ErrorLinePrefix = `(^|[[:space:]])(Error|ERROR|Erreur):`

var (
	errorsRe    = regexp.MustCompile(Errors)
	errorLineRe = regexp.MustCompile(ErrorLinePrefix)
	ansiRe      = regexp.MustCompile("\x1b\\[[0-9;]*m")
)

// Cause of a failure; stored names stay as in the state files and JSON output.
const (
	CauseCountry = "pays"   // not available in your country, lasting
	CauseQuota   = "quota"  // Free usage limit
	CauseFilter  = "filtre" // content filter
	CauseNetwork = "reseau" // network, no exclusion
	CauseOther   = "autre"  // other
	CauseMute    = "mute"   // silent at start (stored; old files: muet)
	CauseMuet    = "muet"   // old silent format
)

// ErrorCause returns the cause of a failure text: pays, quota, filtre, reseau
// or autre. Same order as the shell `case`.
func ErrorCause(t string) string {
	switch {
	case strings.Contains(t, "not available in your country"):
		return CauseCountry
	case strings.Contains(t, "Free usage limit"):
		return CauseQuota
	case strings.Contains(t, "content filter"):
		return CauseFilter
	case strings.Contains(t, "ENOTFOUND") || strings.Contains(t, "ECONNREFUSED") ||
		strings.Contains(t, "ETIMEDOUT") || strings.Contains(t, "EAI_AGAIN") ||
		strings.Contains(t, "ECONNRESET") || strings.Contains(t, "fetch failed") ||
		strings.Contains(t, "network"):
		return CauseNetwork
	default:
		return CauseOther
	}
}

// CauseLabel returns the user-facing cause name (mute and muet are both silent).
func CauseLabel(cause string) string {
	switch cause {
	case CauseCountry:
		return "country"
	case CauseQuota:
		return "quota"
	case CauseFilter:
		return "filter"
	case CauseNetwork:
		return "network"
	case CauseMute, CauseMuet:
		return "silent"
	default:
		return "other"
	}
}

// ExclusionDuration returns exclusion seconds: country 7 days
// (DEVZONE_AGENT_COUNTRY_EXCLUSION), others 1 h.
func ExclusionDuration(cause string) int64 {
	if cause == CauseCountry {
		if v := os.Getenv("DEVZONE_AGENT_COUNTRY_EXCLUSION"); v != "" {
			if n, err := strconv.ParseInt(v, 10, 64); err == nil {
				return n
			}
		}
		return 604800
	}
	return 3600
}

// ExclusionLabel renders a readable exclusion duration: "7 d", "1 h", "30 s".
func ExclusionLabel(cause string) string {
	d := ExclusionDuration(cause)
	switch {
	case d >= 86400:
		return fmt.Sprintf("%d d", d/86400)
	case d >= 3600:
		return fmt.Sprintf("%d h", d/3600)
	default:
		return fmt.Sprintf("%d s", d)
	}
}

// ErrorLines keeps opencode "timestamp=... level=ERROR ..." lines of a failure,
// strips ANSI, drops agent=title errors (the title model says nothing).
func ErrorLines(text string) string {
	var out []string
	for _, line := range strings.Split(text, "\n") {
		line = ansiRe.ReplaceAllString(line, "")
		if !strings.HasPrefix(line, "timestamp=") || !strings.Contains(line, " level=ERROR ") {
			continue
		}
		if strings.Contains(line, " agent=title ") {
			continue
		}
		out = append(out, line)
	}
	return strings.Join(out, "\n")
}

// errorMatches returns matches of Errors in order.
func errorMatches(text string) []string { return errorsRe.FindAllString(text, -1) }

// hasErrorLine reports an opencode error line (Error|ERROR|Erreur:).
func hasErrorLine(text string) bool { return errorLineRe.MatchString(text) }

// LastTail returns the last n lines of text (tail -n n; a trailing newline is
// not an extra line).
func LastTail(text string, n int) string {
	lines := strings.Split(text, "\n")
	if len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n") + "\n"
}

// model_exclusions of a session; agent state directory.
type exclusion struct {
	model string
	start int64
	cause string
	d     int64
}

// ModelExcluded returns true when the model is excluded right now. Reads
// ecart-<model>, else old muet-<model> (timestamp only, 1 h).
func ModelExcluded(stateDir, model string, now time.Time) bool {
	f := filepath.Join(stateDir, "ecart-"+model)
	if !fileExists(f) {
		f = filepath.Join(stateDir, "muet-"+model)
	}
	if !fileExists(f) {
		return false
	}
	e, _, d := readExclusion(f)
	dur := d
	if dur == 0 {
		dur = 3600
	}
	return now.Unix() < e+dur
}

func readExclusion(f string) (e int64, cause string, d int64) {
	data, err := os.ReadFile(f)
	if err != nil {
		return 0, "", 0
	}
	fields := strings.Fields(string(data))
	if len(fields) > 0 {
		e, _ = strconv.ParseInt(fields[0], 10, 64)
	}
	if len(fields) > 1 {
		cause = fields[1]
	}
	if len(fields) > 2 {
		d, _ = strconv.ParseInt(fields[2], 10, 64)
	}
	return e, cause, d
}

// ModelExclusionCause returns the stored cause of model's exclusion
// (ecart-, else muet-, default muet).
func ModelExclusionCause(stateDir, model string) string {
	f := filepath.Join(stateDir, "ecart-"+model)
	if !fileExists(f) {
		f = filepath.Join(stateDir, "muet-"+model)
	}
	cause := ""
	if fileExists(f) {
		_, cause, _ = readExclusion(f)
	}
	if cause == "" {
		cause = CauseMuet
	}
	return cause
}

// ModelExclude writes "<start> <cause> <duration>" in ecart-<model>.
func ModelExclude(stateDir, model, cause string, now time.Time) error {
	if err := os.MkdirAll(stateDir, 0o755); err != nil {
		return err
	}
	line := fmt.Sprintf("%d %s %d\n", now.Unix(), cause, ExclusionDuration(cause))
	return os.WriteFile(filepath.Join(stateDir, "ecart-"+model), []byte(line), 0o644)
}

func fileExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}
