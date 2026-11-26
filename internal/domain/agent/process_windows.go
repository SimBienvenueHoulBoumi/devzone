//go:build windows

package agent

import (
	"os"
	"os/exec"
)

// childEnv merges base environ + added, removing unset names (env -u).
func childEnv(added, unset []string) []string {
	base := os.Environ()
	remove := map[string]bool{}
	for _, u := range unset {
		remove[u] = true
	}
	setNames := map[string]bool{}
	for _, a := range added {
		if i := indexByte(a, '='); i >= 0 {
			setNames[a[:i]] = true
		}
	}
	out := make([]string, 0, len(base)+len(added))
	for _, e := range base {
		name := e
		if i := indexByte(e, '='); i >= 0 {
			name = e[:i]
		}
		if remove[name] || setNames[name] {
			continue
		}
		out = append(out, e)
	}
	return append(out, added...)
}

func indexByte(s string, b byte) int {
	for i := 0; i < len(s); i++ {
		if s[i] == b {
			return i
		}
	}
	return -1
}

// setProcGroup is a no-op on windows.
func setProcGroup(c *exec.Cmd) {}

// processAlive reports whether the process is still running.
func processAlive(p *os.Process) bool { return p != nil }

// killGroup kills the process.
func killGroup(p *os.Process) {
	if p == nil {
		return
	}
	p.Kill()
}
