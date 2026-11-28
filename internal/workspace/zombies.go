package workspace

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/config"
)

// ZombiesRemedy is the only remedy for zombies left by a PID 1 that never calls
// wait. A zombie cannot be killed from outside, so the pod must be recreated.
// The command never does it: it is printed for the person who decides.
const ZombiesRemedy = "Only recreating the pod removes them. From a workstation, delete devzone-workspace-0 in the " + config.NamespaceWorkspace + " namespace (its volumes are kept), then start the workspace again. This command does not do it."

// ReadZombies lists the zombie processes of the proc folder root (normally /proc).
// The folder is a parameter so that tests use a fake one. A process that exits
// while it is read is skipped, as ps does.
func ReadZombies(root string) ([]Zombie, error) {
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil, err
	}
	var zombies []Zombie
	for _, entry := range entries {
		pid, err := strconv.Atoi(entry.Name())
		if err != nil {
			continue
		}
		stat, err := os.ReadFile(filepath.Join(root, entry.Name(), "stat"))
		if err != nil {
			continue
		}
		if z, ok := parseStat(pid, string(stat)); ok {
			zombies = append(zombies, z)
		}
	}
	return zombies, nil
}

// procName returns the command name of pid in the proc folder root, or "?" when
// the process has gone. The name is for the report only.
func procName(root string, pid int) string {
	comm, err := os.ReadFile(filepath.Join(root, strconv.Itoa(pid), "comm"))
	if err != nil {
		return "?"
	}
	return strings.TrimSpace(string(comm))
}

// initBlind reads the command line of PID 1 in the proc folder root and tells
// whether it is the blind one (pid1Blind). A missing or empty command line is not blind.
func initBlind(root string) bool {
	raw, err := os.ReadFile(filepath.Join(root, "1", "cmdline"))
	if err != nil {
		return false
	}
	return pid1Blind(strings.ReplaceAll(string(raw), "\x00", " "))
}

// Zombies writes the zombie report of the proc folder root to out and returns the
// status: 0 once the folder has been read, 1 when it cannot be read (the message
// goes to errOut). The count is the total; the parents follow, largest first.
// When PID 1 is the blind one and has zombies to show, the report says it and
// gives the only remedy, which is printed and never run. Why this is a report
// and not a fix: the zombies cannot be removed without the pod being recreated.
func Zombies(root string, out, errOut io.Writer) int {
	zombies, err := ReadZombies(root)
	if err != nil {
		fmt.Fprintf(errOut, "✖ cannot read %s: %v\n", root, err)
		return 1
	}
	fmt.Fprintf(out, "zombie processes: %d\n", len(zombies))
	groups := groupZombies(zombies, func(pid int) string { return procName(root, pid) })
	blind := initBlind(root)
	for _, g := range groups {
		line := fmt.Sprintf("  parent %d (%s): %d", g.PPID, g.Name, g.Count)
		if g.PPID == 1 && blind {
			line += "  <- PID 1 does not reap"
		}
		fmt.Fprintln(out, line)
	}
	if blind && hasParent(groups, 1) {
		fmt.Fprintln(out, "PID 1 is \"sleep infinity\" without wait: the orphans it adopts stay zombies.")
		fmt.Fprintln(out, ZombiesRemedy)
	}
	return 0
}

// hasParent reports whether one of the groups has the given parent pid.
func hasParent(groups []ParentGroup, ppid int) bool {
	for _, g := range groups {
		if g.PPID == ppid {
			return true
		}
	}
	return false
}
