package workspace

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// fakeProc builds a proc folder in a temporary directory: one folder per process,
// with its stat and comm files, and its cmdline when given. No real process is read.
func fakeProc(t *testing.T) string {
	t.Helper()
	return t.TempDir()
}

// addProc writes the stat and comm files of a process of the fake proc folder.
func addProc(t *testing.T, root string, pid int, comm, state string, ppid int) {
	t.Helper()
	dir := filepath.Join(root, strconv.Itoa(pid))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	stat := fmt.Sprintf("%d (%s) %s %d 0 0 0\n", pid, comm, state, ppid)
	writeFile(t, filepath.Join(dir, "stat"), stat)
	writeFile(t, filepath.Join(dir, "comm"), comm+"\n")
}

// setCmdline writes the cmdline of a process of the fake proc folder, with NUL
// separators as the kernel writes it.
func setCmdline(t *testing.T, root string, pid int, argv ...string) {
	t.Helper()
	text := strings.Join(argv, "\x00") + "\x00"
	writeFile(t, filepath.Join(root, strconv.Itoa(pid), "cmdline"), text)
}

// TestReadZombiesSkipsOtherEntries checks that only zombie processes are listed:
// sleeping processes, folders that are not pids, and processes whose stat has
// gone are ignored.
func TestReadZombiesSkipsOtherEntries(t *testing.T) {
	root := fakeProc(t)
	addProc(t, root, 1, "sleep", "S", 0)
	addProc(t, root, 100, "git", "Z", 1)
	addProc(t, root, 101, "bash", "S", 1)
	if err := os.MkdirAll(filepath.Join(root, "self"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "102"), 0o755); err != nil {
		t.Fatal(err)
	}
	zombies, err := ReadZombies(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(zombies) != 1 || zombies[0] != (Zombie{PID: 100, PPID: 1, Name: "git"}) {
		t.Fatalf("zombies = %+v, want only pid 100", zombies)
	}
}

// TestReadZombiesMissingRoot checks that an unreadable proc folder is an error,
// not an empty report.
func TestReadZombiesMissingRoot(t *testing.T) {
	if _, err := ReadZombies(filepath.Join(t.TempDir(), "absent")); err == nil {
		t.Fatal("ReadZombies of a missing folder returned no error")
	}
}

// runReport runs Zombies on root and returns its status and both outputs.
func runReport(root string) (int, string, string) {
	var out, errOut bytes.Buffer
	code := Zombies(root, &out, &errOut)
	return code, out.String(), errOut.String()
}

// TestZombiesReportBlindPid1 checks the report of the old pod: zombies under PID 1
// running "sleep infinity" are grouped by parent, PID 1 is marked as not reaping,
// and the only remedy is printed.
func TestZombiesReportBlindPid1(t *testing.T) {
	root := fakeProc(t)
	addProc(t, root, 1, "sleep", "S", 0)
	setCmdline(t, root, 1, "sleep", "infinity")
	addProc(t, root, 50, "bash", "S", 1)
	addProc(t, root, 60, "git", "Z", 1)
	addProc(t, root, 61, "git", "Z", 1)
	addProc(t, root, 62, "sleep", "Z", 1)
	addProc(t, root, 70, "sh", "Z", 50)
	code, out, errOut := runReport(root)
	if code != 0 || errOut != "" {
		t.Fatalf("status %d, stderr %q, want 0 and nothing on stderr", code, errOut)
	}
	wants := []string{
		"zombie processes: 4\n",
		"  parent 1 (sleep): 3  <- PID 1 does not reap\n",
		"  parent 50 (bash): 1\n",
		ZombiesRemedy,
	}
	for _, want := range wants {
		if !strings.Contains(out, want) {
			t.Errorf("report misses %q:\n%s", want, out)
		}
	}
	if strings.Index(out, "parent 1 ") > strings.Index(out, "parent 50 ") {
		t.Errorf("largest group is not first:\n%s", out)
	}
}

// TestZombiesReportReapingPid1 checks that a PID 1 that calls wait gets no
// blame and no remedy: the zombies are still counted and grouped.
func TestZombiesReportReapingPid1(t *testing.T) {
	root := fakeProc(t)
	addProc(t, root, 1, "bash", "S", 0)
	setCmdline(t, root, 1, "bash", "-c", "while true; do wait -n; sleep 1; done")
	addProc(t, root, 40, "git", "Z", 1)
	code, out, _ := runReport(root)
	if code != 0 {
		t.Fatalf("status = %d, want 0", code)
	}
	if !strings.Contains(out, "zombie processes: 1\n") || !strings.Contains(out, "  parent 1 (bash): 1\n") {
		t.Errorf("report = %q", out)
	}
	if strings.Contains(out, "does not reap") || strings.Contains(out, "recreating the pod") {
		t.Errorf("a reaping PID 1 must get no remedy: %q", out)
	}
}

// TestZombiesReportNone checks the report when nothing is a zombie: a count of
// zero, status 0, and no remedy even with the blind PID 1.
func TestZombiesReportNone(t *testing.T) {
	root := fakeProc(t)
	addProc(t, root, 1, "sleep", "S", 0)
	setCmdline(t, root, 1, "sleep", "infinity")
	code, out, _ := runReport(root)
	if code != 0 || out != "zombie processes: 0\n" {
		t.Fatalf("status %d, report %q; want 0 and only the count", code, out)
	}
}

// TestZombiesReportUnreadable checks that a proc folder that cannot be read gives
// status 1 and a message on the error output, and nothing on the report.
func TestZombiesReportUnreadable(t *testing.T) {
	code, out, errOut := runReport(filepath.Join(t.TempDir(), "absent"))
	if code != 1 || out != "" || !strings.Contains(errOut, "cannot read") {
		t.Fatalf("status %d, out %q, err %q; want 1, nothing, and a cannot-read message", code, out, errOut)
	}
}
