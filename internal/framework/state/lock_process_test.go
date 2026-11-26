package state

import (
	"fmt"
	"os"
	osexec "os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
)

// TestBinaryLockExcludesProcesses checks that two separate devzone-pod
// processes cannot interleave writes: every key survives and no lock remains.
func TestBinaryLockExcludesProcesses(t *testing.T) {
	_, here, _, _ := runtime.Caller(0)
	repo := filepath.Clean(filepath.Join(filepath.Dir(here), "..", "..", ".."))
	dir := t.TempDir()
	binary := filepath.Join(dir, "devzone-pod")
	build := osexec.Command("go", "build", "-o", binary, "./cmd/devzone-pod")
	build.Dir = repo
	build.Env = append(os.Environ(), "GOTOOLCHAIN=local")
	if out, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build: %v\n%s", err, out)
	}
	stateFile := filepath.Join(dir, ".devzone.modules")
	if err := os.WriteFile(stateFile, []byte("ai=off\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	env := append(os.Environ(), "DEVZONE_STATE="+stateFile)
	var wg sync.WaitGroup
	errs := make(chan error, 2)
	for _, prefix := range []string{"a", "b"} {
		prefix := prefix
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 1; i <= 25; i++ {
				cmd := osexec.Command(binary, "state", "write", prefix+fmtInt(int64(i)), "on")
				cmd.Env = env
				if out, err := cmd.CombinedOutput(); err != nil {
					errs <- fmt.Errorf("%s%d: %v: %s", prefix, i, err, out)
					return
				}
			}
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Error(err)
	}
	data, err := os.ReadFile(stateFile)
	if err != nil {
		t.Fatal(err)
	}
	for _, prefix := range []string{"a", "b"} {
		for i := 1; i <= 25; i++ {
			line := prefix + strings.TrimSpace(fmtInt(int64(i))) + "=on"
			if !strings.Contains(string(data), line+"\n") {
				t.Fatalf("lost %s: state=%q", line, data)
			}
		}
	}
	if _, err := os.Stat(stateFile + ".lockdir"); !os.IsNotExist(err) {
		t.Fatalf("lockdir left behind: %v", err)
	}
}
