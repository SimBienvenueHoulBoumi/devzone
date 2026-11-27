package agent

// reaperWord is the internal subcommand of the devzone binary that runs a command
// under a child subreaper (internal/podcmd, #973).
const reaperWord = "subreaper"

// reaperArgs returns the program and arguments that start a session. Without a
// reaper path the session itself is started. With one, the binary is started
// with `subreaper -- <session> <args...>`, so that the session's orphans are
// reaped by that wrapper and never reach PID 1, which may not call wait (#973).
func reaperArgs(reaper, name string, args []string) (string, []string) {
	if reaper == "" {
		return name, args
	}
	wrapped := append([]string{reaperWord, "--", name}, args...)
	return reaper, wrapped
}
