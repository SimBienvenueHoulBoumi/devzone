package podcmd

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
)

// cgroupRoot is the cgroup v2 directory of the container: the container sees
// its own cgroup at the root of its cgroup namespace (#967).
const cgroupRoot = "/sys/fs/cgroup"

// pidsWarnPercent is the share of pids.max from which status warns: a pod that
// leaks processes (zombies) reaches its limit and stops starting commands.
const pidsWarnPercent = 70

// memoryMaxJump is the rise of the memory.events "max" counter, since the last
// status, from which status warns: the memory limit was hit that many times.
const memoryMaxJump = 50

// printPressureLine prints one warning line when the container is close to its
// process limit or hit its memory limit often; it prints nothing otherwise, and
// nothing at all where the cgroup files do not exist (workstation, Windows).
func printPressureLine(ctx *cli.Context) {
	if msg := pressureWarning(cgroupRoot, pressureBaseline()); msg != "" {
		fmt.Fprintf(ctx.Out, "  ⚠ pressure       %s\n", msg)
	}
}

// pressureBaseline is the file that keeps the last memory.events "max" count
// seen by status; it lives in the temporary folder, so a restart of the
// container (which resets the counter) starts from nothing.
func pressureBaseline() string {
	return filepath.Join(os.TempDir(), "devzone-memory-max.count")
}

// pressureWarning returns the text of the warning for the cgroup files under
// root, or "" when nothing is worth saying. It updates the baseline file with
// the current memory.events count, so the next call measures the rise from
// this one. root and baseline are parameters so that tests use fake files.
func pressureWarning(root, baseline string) string {
	var parts []string
	if cur, limit, ok := pressurePids(root); ok && cur*100 > limit*pidsWarnPercent {
		parts = append(parts, fmt.Sprintf("%d of %d processes (%d%%): look for leaked processes (ps -eo pid,ppid,stat,comm)", cur, limit, cur*100/limit))
	}
	if cur, ok := pressureMemoryMax(root); ok {
		prev, hadPrev := pressureReadCount(baseline)
		_ = os.WriteFile(baseline, []byte(strconv.Itoa(cur)+"\n"), 0o644)
		if hadPrev && cur >= prev && cur-prev >= memoryMaxJump {
			parts = append(parts, fmt.Sprintf("memory limit hit %d times since the last status: raise resources.limits.memory", cur-prev))
		}
	}
	return strings.Join(parts, "; ")
}

// pressurePids reads pids.current and pids.max under root; ok is false when
// either file is missing or the limit is "max" (no limit to compare with).
func pressurePids(root string) (cur, limit int, ok bool) {
	cur, okCur := pressureReadCount(filepath.Join(root, "pids.current"))
	limit, okMax := pressureReadCount(filepath.Join(root, "pids.max"))
	return cur, limit, okCur && okMax && limit > 0
}

// pressureMemoryMax reads the "max" line of memory.events under root, the
// number of times the memory limit was reached; ok is false when it is absent.
func pressureMemoryMax(root string) (int, bool) {
	data, err := os.ReadFile(filepath.Join(root, "memory.events"))
	if err != nil {
		return 0, false
	}
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 2 && fields[0] == "max" {
			n, err := strconv.Atoi(fields[1])
			return n, err == nil
		}
	}
	return 0, false
}

// pressureReadCount reads one integer from a cgroup or baseline file; ok is
// false when the file is missing or holds something else (such as "max").
func pressureReadCount(path string) (int, bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return 0, false
	}
	n, err := strconv.Atoi(strings.TrimSpace(string(data)))
	return n, err == nil
}
