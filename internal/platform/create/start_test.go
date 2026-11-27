package create

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// workspaceProgram returns the Go program the start session runs, which is the
// test binary itself, with the "workspace start" arguments.
func workspaceProgram(t *testing.T) string {
	t.Helper()
	program, err := os.Executable()
	if err != nil {
		t.Fatalf("os.Executable: %v", err)
	}
	return program
}

// TestCreateStartFailsKeepsFolder checks a failed workspace start exits 1, the
// folder stays, the start to redo is named.
func TestCreateStartFailsKeepsFolder(t *testing.T) {
	runner := readyRunner()
	opts, target, _, errOut := createOptions(t, runner)
	program := workspaceProgram(t)
	runner.On(program, []string{"workspace", "start"}, fexec.Result{Code: 1})
	if err := Create(opts); err != ErrSilent {
		t.Fatalf("err=%v", err)
	}
	if !fileExists(filepath.Join(target, "Makefile")) {
		t.Fatal("folder not kept after failed start")
	}
	s := errOut.String()
	if !strings.Contains(s, "Workspace not started") || !strings.Contains(s, "devzone workspace start") {
		t.Fatalf("stderr:\n%s", s)
	}
}

// TestCreateStartRunsWorkspace checks the Go workspace start runs in the new
// folder unless DEVZONE_NO_START is set.
func TestCreateStartRunsWorkspace(t *testing.T) {
	runner := readyRunner()
	opts, target, out, _ := createOptions(t, runner)
	program := workspaceProgram(t)
	runner.On(program, []string{"workspace", "start"}, fexec.Result{})
	if err := Create(opts); err != nil {
		t.Fatalf("Create: %v", err)
	}
	var dirs []string
	for _, c := range runner.Calls() {
		if c.Name == program {
			dirs = append(dirs, c.Opts.Dir)
		}
	}
	if len(dirs) != 1 || dirs[0] != target {
		t.Fatalf("start calls dirs=%v target=%s", dirs, target)
	}
	if !strings.Contains(out.String(), "Next: cd ") || !strings.Contains(out.String(), "devzone workspace shell (the pod)") {
		t.Fatalf("stdout:\n%s", out.String())
	}
}

// TestCreateWorkspaceAlreadyInCluster checks an existing release or
// Application adds a notice and creation goes on.
func TestCreateWorkspaceAlreadyInCluster(t *testing.T) {
	t.Setenv("DEVZONE_NO_START", "1")
	runner := readyRunner()
	opts, target, out, errOut := createOptions(t, runner)
	runner.On("helm", []string{"status", "devzone-workspace", "--namespace", "devzone-workspace", "--kube-context", "devzone"}, fexec.Result{})
	if err := Create(opts); err != nil {
		t.Fatalf("Create: %v", err)
	}
	if !strings.Contains(out.String(), "a devzone workspace already runs in this cluster") {
		t.Fatalf("stdout:\n%s\nstderr:\n%s", out.String(), errOut.String())
	}
	modules, _ := os.ReadFile(filepath.Join(target, ".devzone.modules"))
	if string(modules) != "workspace=kubernetes\n" {
		t.Fatalf(".devzone.modules=%q", modules)
	}
}

// TestCreateGitignoreCompleted checks .gitignore always holds GitignoreLines.
func TestCreateGitignoreCompleted(t *testing.T) {
	t.Setenv("DEVZONE_NO_START", "1")
	opts, target, _, _ := createOptions(t, readyRunner())
	if err := Create(opts); err != nil {
		t.Fatalf("Create: %v", err)
	}
	data, _ := os.ReadFile(filepath.Join(target, ".gitignore"))
	s := string(data)
	for _, line := range GitignoreLines {
		if !strings.Contains(s, line+"\n") {
			t.Fatalf(".gitignore misses %q:\n%s", line, s)
		}
	}
}
