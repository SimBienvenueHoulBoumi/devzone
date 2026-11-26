package agent

import (
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// SessionRunning reports a live session (#308): the launcher starts
// `devzone-pod-linux-<arch> agent [--model M] [--local] <folder> <brief>`, not a
// command line containing "devzone agent". The old shell and the launcher are
// still recognized so their journals stay readable. Only the supplied ps text
// is read: other agents on the machine are neither seen nor stopped.
func SessionRunning(project, psArgs string) bool {
	if project == "" {
		return false
	}
	for _, line := range strings.Split(psArgs, "\n") {
		if filepath.Base(sessionFolder(line)) == project {
			return true
		}
	}
	return false
}

// sessionFolder returns the folder argument of one agent ps line, or "" when
// the line is not an agent session (a subcommand, another command, etc.).
func sessionFolder(line string) string {
	fields := strings.Fields(line)
	if len(fields) == 0 {
		return ""
	}
	i := 0
	if shellCommand(filepath.Base(fields[0])) && len(fields) > 1 {
		i = 1
	}
	name := filepath.Base(fields[i])
	switch {
	case name == "agent.sh":
		return sessionArgsFolder(fields[i+1:])
	case name == "devzone" || name == "devzone-pod" || strings.HasPrefix(name, "devzone-pod-linux-"):
		if i+1 < len(fields) && fields[i+1] == "agent" {
			return sessionArgsFolder(fields[i+2:])
		}
	}
	return ""
}

// shellCommand reports whether a ps command token is a shell interpreter, in
// which case the agent command is the next token.
func shellCommand(name string) bool {
	switch name {
	case "bash", "sh", "dash", "zsh":
		return true
	default:
		return false
	}
}

// sessionArgsFolder skips the options accepted before the folder and returns
// that folder; a subcommand or an unknown option is not a session.
func sessionArgsFolder(args []string) string {
	for i := 0; i < len(args); i++ {
		switch {
		case args[i] == "--local" || args[i] == "--pod":
			continue
		case args[i] == "--model":
			i++
		case strings.HasPrefix(args[i], "--model="):
			continue
		case strings.HasPrefix(args[i], "-"):
			return ""
		default:
			if isAgentSubcommand(args[i]) {
				return ""
			}
			return args[i]
		}
	}
	return ""
}

// isAgentSubcommand lists the commands of `devzone agent` that do not launch a
// session, so a folder with the same name is never mistaken for a live one.
func isAgentSubcommand(arg string) bool {
	switch arg {
	case "state", "release", "status", "help":
		return true
	default:
		return false
	}
}

// AgentState renders `devzone agent state` text: sessions, exclusions, alerts.
func AgentState(racine, stateDir string, now time.Time, psArgs string, rightsAlerts string) string {
	var b strings.Builder
	b.WriteString("devzone agent: state\n")
	journals := globDir(filepath.Join(racine, "workspace", ".agents"), "*.log")
	sort.Strings(journals)
	seen := false
	for _, f := range journals {
		seen = true
		model, start := SessionModelStart(f)
		m := ""
		if model != "" {
			m = "opencode/" + model
		}
		last := UTCTime(MTime(f))
		req := SessionRequest(f)
		line := "  session " + filepath.Base(f) + ": model "
		if m == "" {
			line += "unknown"
		} else {
			line += m
		}
		if req != "" {
			line += " (requested: " + req + ")"
		}
		if start == "" {
			start = "unknown"
		}
		line += ", since " + start + ", last written " + last
		b.WriteString(line + "\n")
	}
	if !seen {
		b.WriteString("  no session\n")
	}
	excl := orderedExclusions(stateDir, now)
	if excl != "" {
		b.WriteString(excl + "\n")
	}
	if rightsAlerts != "" {
		b.WriteString(rightsAlerts)
	}
	return b.String()
}
