package createmode

import (
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// TestStartOnlyPrinted checks that test runs print the command instead of
// starting a workspace, and touch no program.
func TestStartOnlyPrinted(t *testing.T) {
	t.Setenv("DEVZONE_NO_START", "1")
	t.Setenv("DEVZONE_WORKSPACE_SH", "")
	folder := filepath.Join(t.TempDir(), "new")
	s, r, out, _ := modeSession(t, nil, nil)
	if err := s.Start(folder, filepath.Join(t.TempDir(), "workspace.sh")); err != nil {
		t.Fatalf("Start: %v", err)
	}
	if !strings.Contains(out.String(), "To start the workspace: cd "+folder+" && devzone workspace start") {
		t.Fatalf("out = %q", out.String())
	}
	if len(r.Calls()) != 0 {
		t.Fatalf("calls = %+v; want none", r.Calls())
	}
}

// TestStartRunsFromFolder checks that the package script is run from the new
// folder and that its output is forwarded.
func TestStartRunsFromFolder(t *testing.T) {
	t.Setenv("DEVZONE_NO_START", "")
	script := filepath.Join(t.TempDir(), "ws.sh")
	t.Setenv("DEVZONE_WORKSPACE_SH", script)
	setup := func(r *fake.Runner) {
		r.On("bash", []string{script, "start"}, exec.Result{Stdout: []byte("workspace start in folder\n")})
	}
	s, r, out, errOut := modeSession(t, nil, setup)
	folder := t.TempDir()
	if err := s.Start(folder, filepath.Join(t.TempDir(), "workspace.sh")); err != nil {
		t.Fatalf("Start: %v", err)
	}
	calls := r.Calls()
	if len(calls) != 1 || calls[0].Name != "bash" || calls[0].Opts.Dir != folder {
		t.Fatalf("calls = %+v; want one bash call in %s", calls, folder)
	}
	if !strings.Contains(out.String(), "workspace start in folder") || !strings.Contains(out.String(), "Next: cd "+folder+" && devzone workspace shell (the pod)") {
		t.Fatalf("out = %q", out.String())
	}
	if errOut.Len() != 0 {
		t.Fatalf("err = %q", errOut.String())
	}
}

// TestStartFailure checks that a failed start names the command to redo and
// keeps the folder by returning an error.
func TestStartFailure(t *testing.T) {
	t.Setenv("DEVZONE_NO_START", "")
	script := filepath.Join(t.TempDir(), "ws.sh")
	t.Setenv("DEVZONE_WORKSPACE_SH", script)
	setup := func(r *fake.Runner) {
		r.On("bash", []string{script, "start"}, exec.Result{Code: 1})
	}
	folder := filepath.Join(t.TempDir(), "new")
	s, _, _, errOut := modeSession(t, nil, setup)
	if err := s.Start(folder, filepath.Join(t.TempDir(), "workspace.sh")); err == nil {
		t.Fatal("Start must fail")
	}
	want := "✖ Workspace not started. The folder is ready: only the start remains (cd " + folder + " && devzone workspace start)"
	if !strings.Contains(errOut.String(), want) {
		t.Fatalf("err = %q; want %q", errOut.String(), want)
	}
}
