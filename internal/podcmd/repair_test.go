package podcmd

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

// repairFixture creates a disposable devzone folder with a pod entry point and
// a state file, so no repair test reaches a real service.
func repairFixture(t *testing.T) (root, script, stateFile string) {
	t.Helper()
	root = t.TempDir()
	script = writeRepairFile(t, root+"/.devcontainer/devzone", "")
	stateFile = writeRepairFile(t, root+"/.devzone.modules", "")
	t.Setenv("DEVZONE_ROOT", root)
	t.Setenv("DEVZONE_STATE", stateFile)
	t.Setenv("DEVZONE_POD_SCRIPT", script)
	return root, script, stateFile
}

// writeRepairFile writes one file of the disposable fixture, creating parents.
func writeRepairFile(t *testing.T, path, content string) string {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

// runPodWithRunner executes a registered command with a programmable runner.
func runPodWithRunner(t *testing.T, runner *fake.Runner, args ...string) (string, string, int) {
	t.Helper()
	var out, errOut bytes.Buffer
	ctx := &cli.Context{Out: &out, Err: &errOut, Runner: runner}
	code, handled := Registry.Run(args, ctx)
	if !handled {
		t.Fatalf("command %v not handled", args)
	}
	return out.String(), errOut.String(), code
}

// TestRepairActiveServices checks that every active repair item runs and is
// reported, including the watcher environment and the final cluster clean.
func TestRepairActiveServices(t *testing.T) {
	_, script, stateFile := repairFixture(t)
	writeRepairFile(t, stateFile, "gitlab=on\npostgres=on\nargocd=on\nmysql=on\n")
	r := fake.New()
	for _, args := range [][]string{
		{"gitlab", "host-set"}, {"gitlab", "relay-start"}, {"postgres", "relay-start"},
		{"argocd", "relay-start"}, {"mysql", "relay-start"}, {"catalog-watcher", "start"},
		{"passwords", "regenerate"},
	} {
		r.On(script, args, exec.Result{})
	}
	r.On(script, []string{"cluster", "clean"}, exec.Result{Stdout: []byte("cleaned\n")})
	out, errOut, code := runPodWithRunner(t, r, "repair")
	if code != 0 || errOut != "" {
		t.Fatalf("code = %d, errOut = %q", code, errOut)
	}
	for _, want := range []string{
		"✔ gitlab name", "✔ gitlab relay", "✔ postgres relay", "✔ argocd relay",
		"✔ mysql relay", "✔ catalog watcher", "✔ credentials", "cleaned",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("repair output misses %q: %q", want, out)
		}
	}
	if !strings.Contains(out, "✔ gitlab name\n✔ gitlab relay\n✔ postgres relay\n✔ argocd relay\n✔ mysql relay\n") {
		t.Errorf("repair order differs: %q", out)
	}
	var watcherEnv []string
	for _, call := range r.Calls() {
		if len(call.Args) == 2 && call.Args[0] == "catalog-watcher" {
			watcherEnv = call.Opts.Env
		}
	}
	if len(watcherEnv) != 2 || !strings.Contains(watcherEnv[0], "DEVZONE_STATE=") ||
		watcherEnv[1] != "DEVZONE_CATALOG_REAL=yes" {
		t.Fatalf("watcher env = %v", watcherEnv)
	}
}

// TestRepairFailureReason checks that a failed item shows its last output line
// and does not stop the following repair items.
func TestRepairFailureReason(t *testing.T) {
	_, script, _ := repairFixture(t)
	r := fake.New()
	r.On(script, []string{"catalog-watcher", "start"}, exec.Result{
		Stderr: []byte("noise\nwatcher refused\n"), Code: 2,
	})
	r.On(script, []string{"passwords", "regenerate"}, exec.Result{})
	r.On(script, []string{"cluster", "clean"}, exec.Result{})
	out, _, code := runPodWithRunner(t, r, "repair")
	if code != 1 {
		t.Fatalf("code = %d, want 1", code)
	}
	if !strings.Contains(out, "✖ catalog watcher : watcher refused") {
		t.Fatalf("failure reason missing: %q", out)
	}
	if !strings.Contains(out, "✔ credentials") {
		t.Fatalf("following item skipped: %q", out)
	}
}

// TestRepairWithoutScript checks that repair refuses to run without the pod
// shell entry point instead of calling a removed shell function.
func TestRepairWithoutScript(t *testing.T) {
	noShell(t)
	_, _, stateFile := repairFixture(t)
	t.Setenv("DEVZONE_POD_SCRIPT", "")
	writeRepairFile(t, stateFile, "")
	var out, errOut bytes.Buffer
	ctx := &cli.Context{Out: &out, Err: &errOut, Runner: fake.New()}
	if code := runRepair(ctx); code != 1 {
		t.Fatalf("code = %d, want 1", code)
	}
	if !strings.Contains(errOut.String(), "pod shell entry point not found") {
		t.Fatalf("errOut = %q", errOut.String())
	}
}
