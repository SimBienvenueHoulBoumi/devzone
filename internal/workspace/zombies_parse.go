package workspace

import (
	"sort"
	"strconv"
	"strings"
)

// Zombie is a process that has exited and waits for its parent to read its exit
// status. Only the parent can remove it: nothing outside can kill or clean it (#973).
type Zombie struct {
	PID  int
	PPID int
	Name string
}

// ParentGroup counts the zombies that share one parent, so that a report says
// which process leaves them behind.
type ParentGroup struct {
	PPID  int
	Name  string
	Count int
}

// parseStat reads the content of /proc/<pid>/stat, "pid (comm) state ppid ...", and
// tells whether the process is a zombie. The command name may hold spaces and
// parentheses, so it ends at the last ')'. ok is false for any other state.
func parseStat(pid int, stat string) (z Zombie, ok bool) {
	open := strings.IndexByte(stat, '(')
	end := strings.LastIndexByte(stat, ')')
	if open < 0 || end < open {
		return z, false
	}
	fields := strings.Fields(stat[end+1:])
	if len(fields) < 2 || fields[0] != "Z" {
		return z, false
	}
	ppid, err := strconv.Atoi(fields[1])
	if err != nil {
		return z, false
	}
	return Zombie{PID: pid, PPID: ppid, Name: stat[open+1 : end]}, true
}

// pid1Blind reports whether a command line is the PID 1 that never calls wait:
// the old workspace pod ran "sleep infinity", the new one runs a loop that
// calls wait (#967). The test is on the text, as the chart writes it.
// Why: this is the only thing this command can know about PID 1 from /proc.
// Known limit: a wrapper around "sleep infinity" that does reap is reported as
// blind too, so the remedy is then offered for a pod that could be fixed otherwise.
func pid1Blind(cmdline string) bool {
	return strings.Contains(cmdline, "sleep infinity") && !strings.Contains(cmdline, "wait")
}

// groupZombies counts the zombies per parent, the largest group first, then by
// parent pid. name gives the command of a parent pid, for the report.
func groupZombies(zombies []Zombie, name func(pid int) string) []ParentGroup {
	byParent := map[int]*ParentGroup{}
	for _, z := range zombies {
		g, ok := byParent[z.PPID]
		if !ok {
			g = &ParentGroup{PPID: z.PPID, Name: name(z.PPID)}
			byParent[z.PPID] = g
		}
		g.Count++
	}
	groups := make([]ParentGroup, 0, len(byParent))
	for _, g := range byParent {
		groups = append(groups, *g)
	}
	sort.Slice(groups, func(i, j int) bool {
		if groups[i].Count != groups[j].Count {
			return groups[i].Count > groups[j].Count
		}
		return groups[i].PPID < groups[j].PPID
	})
	return groups
}
