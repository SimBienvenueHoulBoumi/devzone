package agent

import (
	"context"
	"path/filepath"
	"strings"
	"time"
)

// AgentStateJSON renders `devzone agent state --json` (schema 2): sessions,
// exclusions, rights_alerts. Reuses same data as AgentState. `psArgs` for
// running detection. Shell agent_state_json; git not needed.
func AgentStateJSON(ctx context.Context, r Runner, racine, stateDir, psArgs string, now time.Time) string {
	_ = ctx
	_ = r
	sessions := JArr()
	journals := globDir(filepath.Join(racine, "workspace", ".agents"), "*.log")
	for _, f := range journals {
		journal := filepath.Base(f)
		model, start := SessionModelStart(f)
		if model == "" {
			model = "unknown"
		}
		last := UTCTime(MTime(f))
		req := SessionRequest(f)
		project := strings.TrimSuffix(journal, ".log")
		running := SessionRunning(project, psArgs)
		sessions.arr = append(sessions.arr, JObject(
			JMember{Key: "journal", Value: JStr(journal)},
			JMember{Key: "model", Value: JStr(model)},
			JMember{Key: "start", Value: nullOrStr(start)},
			JMember{Key: "last_written", Value: nullOrStr(last)},
			JMember{Key: "requested", Value: nullOrStr(req)},
			JMember{Key: "running", Value: JBool(running)},
		))
	}
	exclusions := JArr()
	nowUnix := now.Unix()
	for _, f := range globDir(stateDir, "ecart-*") {
		model := strings.TrimPrefix(base(f), "ecart-")
		e, cause, d := readExclusion(f)
		if e == 0 && strings.TrimSpace(readFileString(f)) == "" {
			continue
		}
		dur := d
		if dur == 0 {
			dur = 3600
		}
		if cause == "" {
			cause = CauseOther
		}
		if nowUnix >= e+dur {
			continue
		}
		exclusions.arr = append(exclusions.arr, JObject(
			JMember{Key: "model", Value: JStr(model)},
			JMember{Key: "cause", Value: JStr(cause)},
			JMember{Key: "end", Value: JStr(ISO(e + dur))},
		))
	}
	for _, f := range globDir(stateDir, "muet-*") {
		model := strings.TrimPrefix(base(f), "muet-")
		eStr := strings.TrimSpace(readFileString(f))
		if eStr == "" {
			continue
		}
		e := parseInt64(eStr)
		if nowUnix >= e+3600 {
			continue
		}
		exclusions.arr = append(exclusions.arr, JObject(
			JMember{Key: "model", Value: JStr(model)},
			JMember{Key: "cause", Value: JStr(CauseMuet)},
			JMember{Key: "end", Value: JStr(ISO(e + 3600))},
		))
	}
	alerts := JArr()
	for _, f := range globDir(stateDir, "droits-*.alerte") {
		name := strings.TrimSuffix(strings.TrimPrefix(base(f), "droits-"), ".alerte")
		alerts.arr = append(alerts.arr, JStr(name))
	}
	out := JObject(
		JMember{Key: "schema", Value: JInt(2)},
		JMember{Key: "sessions", Value: sessions},
		JMember{Key: "exclusions", Value: exclusions},
		JMember{Key: "rights_alerts", Value: alerts},
	)
	return out.Compact()
}

func nullOrStr(s string) JVal {
	if s == "" {
		return JNull()
	}
	return JStr(s)
}
