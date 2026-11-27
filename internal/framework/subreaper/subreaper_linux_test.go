//go:build linux

package subreaper

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"testing"
	"time"
)

// helperEnv selects the helper process: the test binary runs Run on the script
// of helperScript and prints its result, instead of running the tests. Why a
// child process: a subreaper adopts orphans of its whole process, and the test
// binary must not become one.
const helperEnv = "DEVZONE_SUBREAPER_HELPER_SCRIPT"

// TestSubreaperHelper is not a test: it is the body of the helper process. It
// does nothing unless helperEnv is set, so the normal test run skips it.
func TestSubreaperHelper(t *testing.T) {
	script := os.Getenv(helperEnv)
	if script == "" {
		t.Skip("helper process only")
	}
	res := Run([]string{"bash", "-c", script})
	fmt.Printf("subreaper=%t\n", res.Subreaper)
	for _, pid := range res.Reaped {
		fmt.Printf("reaped=%d\n", pid)
	}
	os.Exit(res.Code)
}

// runHelper runs the helper process on script and returns its exit status and
// the result it printed: whether the subreaper flag was set, and the reaped pids.
func runHelper(t *testing.T, script string) (code int, subreaper bool, reaped []int) {
	t.Helper()
	if _, err := os.Stat("/proc/self/stat"); err != nil {
		t.Skip("no /proc: not a Linux process table")
	}
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("bash is needed for the orphan script")
	}
	cmd := exec.Command(os.Args[0], "-test.run=^TestSubreaperHelper$")
	cmd.Env = append(os.Environ(), helperEnv+"="+script)
	var out bytes.Buffer
	cmd.Stdout = &out
	err := cmd.Run()
	code = 0
	if ee, ok := err.(*exec.ExitError); ok {
		code = ee.ExitCode()
	} else if err != nil {
		t.Fatal(err)
	}
	for _, line := range strings.Split(out.String(), "\n") {
		switch {
		case line == "subreaper=true":
			subreaper = true
		case strings.HasPrefix(line, "reaped="):
			pid, err := strconv.Atoi(strings.TrimPrefix(line, "reaped="))
			if err != nil {
				t.Fatalf("bad reaped line %q", line)
			}
			reaped = append(reaped, pid)
		}
	}
	return code, subreaper, reaped
}

// TestSubreaperReapsOrphan runs a sleep whose parent (a subshell) exits at once:
// the sleep is an orphan while bash still waits in the foreground. The wrapper
// must collect it before its direct child ends, so that no zombie stays under
// PID 1. A plain "sleep 0.1 &" would not do: bash reaps its own background job.
func TestSubreaperReapsOrphan(t *testing.T) {
	code, subreaper, reaped := runHelper(t, "(sleep 0.1 &); sleep 0.4; exit 0")
	if !subreaper {
		t.Skip("prctl(PR_SET_CHILD_SUBREAPER) refused here")
	}
	if code != 0 {
		t.Fatalf("exit status = %d, want 0", code)
	}
	if len(reaped) == 0 {
		t.Fatal("no orphan was reaped: the background sleep became a zombie")
	}
	time.Sleep(10 * time.Millisecond)
	for _, pid := range reaped {
		if _, err := os.Stat(fmt.Sprintf("/proc/%d", pid)); err == nil {
			t.Errorf("pid %d still in the process table after its exit: zombie left", pid)
		}
	}
}

// TestSubreaperReturnsChildStatus checks that the wrapper returns the exit code of
// its child, and 128 plus the signal number when the child is killed.
func TestSubreaperReturnsChildStatus(t *testing.T) {
	if code, _, _ := runHelper(t, "exit 7"); code != 7 {
		t.Errorf("exit 7: status = %d, want 7", code)
	}
	if code, _, _ := runHelper(t, "kill -TERM $$"); code != 128+15 {
		t.Errorf("killed by TERM: status = %d, want %d", code, 128+15)
	}
}

// TestRunMissingCommand checks the status of a command that does not exist: 127,
// as a shell gives, with no child started and no flag set.
func TestRunMissingCommand(t *testing.T) {
	res := Run([]string{"devzone-no-such-command-973"})
	if res.Code != 127 || res.Subreaper || len(res.Reaped) != 0 {
		t.Fatalf("Run(missing) = %+v, want code 127 and nothing else", res)
	}
}
