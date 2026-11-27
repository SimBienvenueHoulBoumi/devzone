package command

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// createModeRun runs the internal command with a fake runner and an injected
// lookup that finds only the named programs; no real cluster, script or program
// is used, and the PATH is left alone. Stdin is empty, so no menu can open.
func createModeRun(t *testing.T, args, programs []string, setup func(*fake.Runner)) (int, string, string) {
	t.Helper()
	t.Setenv("DEVZONE_TERMINAL", "")
	r := fake.New()
	if setup != nil {
		setup(r)
	}
	var out, errOut bytes.Buffer
	ctx := &cli.Context{Args: args, Out: &out, Err: &errOut, Stdin: strings.NewReader(""), Runner: r}
	return createModeCommandWith(ctx, programLookPath(programs...)), out.String(), errOut.String()
}

// createModeReady programs a reachable devzone context for the command tests.
func createModeReady(r *fake.Runner) {
	r.On("kubectl", []string{"config", "get-contexts", "-o", "name"}, exec.Result{Stdout: []byte("devzone\n")})
	r.On("kubectl", []string{"cluster-info", "--request-timeout=5s", "--context", "devzone"}, exec.Result{})
}

// TestCreateModeChooseReady checks that the shell caller captures only the mode
// on stdout while the notice goes to stderr.
func TestCreateModeChooseReady(t *testing.T) {
	code, out, errOut := createModeRun(t, []string{"choose", "kubernetes"}, []string{"kubectl", "helm"}, createModeReady)
	if code != 0 || out != "kubernetes\n" {
		t.Fatalf("code = %d, stdout = %q; want 0 and kubernetes", code, out)
	}
	if !strings.Contains(errOut, "✔ Kubernetes ready (devzone): workspace in the cluster") {
		t.Fatalf("stderr = %q; want the notice", errOut)
	}
}

// TestCreateModeChooseNoCluster checks that no mode is captured when the
// cluster does not answer.
func TestCreateModeChooseNoCluster(t *testing.T) {
	setup := func(r *fake.Runner) {
		createModeReady(r)
		r.On("kubectl", []string{"cluster-info", "--request-timeout=5s", "--context", "devzone"}, exec.Result{Code: 1})
	}
	code, out, errOut := createModeRun(t, []string{"choose"}, []string{"kubectl", "helm"}, setup)
	if code != 1 || out != "" || !strings.Contains(errOut, "Nothing created") {
		t.Fatalf("code = %d, stdout = %q, stderr = %q", code, out, errOut)
	}
}

// TestCreateModeWrite checks that the write form records the mode in the folder.
func TestCreateModeWrite(t *testing.T) {
	folder := t.TempDir()
	code, out, errOut := createModeRun(t, []string{"write", folder, "kubernetes"}, nil, nil)
	if code != 0 || out != "" || errOut != "" {
		t.Fatalf("code = %d, stdout = %q, stderr = %q", code, out, errOut)
	}
	data, err := os.ReadFile(filepath.Join(folder, ".devzone.modules"))
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "workspace=kubernetes\n" {
		t.Fatalf("modules = %q", data)
	}
}

// TestCreateModeStartPrinted checks that the start form prints the command
// when DEVZONE_NO_START is set.
func TestCreateModeStartPrinted(t *testing.T) {
	t.Setenv("DEVZONE_NO_START", "1")
	folder := filepath.Join(t.TempDir(), "new")
	script := filepath.Join(t.TempDir(), "workspace.sh")
	code, out, errOut := createModeRun(t, []string{"start", folder, script}, nil, nil)
	if code != 0 || !strings.Contains(out, "To start the workspace: cd "+folder) || errOut != "" {
		t.Fatalf("code = %d, stdout = %q, stderr = %q", code, out, errOut)
	}
}

// TestCreateModeUsage checks that an unknown form is refused with status 2.
func TestCreateModeUsage(t *testing.T) {
	code, out, errOut := createModeRun(t, []string{"unknown"}, nil, nil)
	if code != 2 || out != "" || !strings.Contains(errOut, "usage: devzone create-mode") {
		t.Fatalf("code = %d, stdout = %q, stderr = %q", code, out, errOut)
	}
}
