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

// ctxWith builds a command context with a fake runner and captured output.
func ctxWith(args []string, runner *fake.Runner) (*cli.Context, *bytes.Buffer, *bytes.Buffer) {
	out, errOut := &bytes.Buffer{}, &bytes.Buffer{}
	return &cli.Context{Args: args, Out: out, Err: errOut, Stdin: strings.NewReader(""), Runner: runner}, out, errOut
}

// readyKube programs a reachable devzone cluster.
func readyKube(r *fake.Runner) {
	r.On("kubectl", []string{"config", "get-contexts", "-o", "name"}, exec.Result{Stdout: []byte("devzone\n")})
	r.On("kubectl", []string{"cluster-info", "--request-timeout=5s", "--context", "devzone"}, exec.Result{})
}

// TestCreateWorkstationUsage checks a missing folder name is a usage error.
func TestCreateWorkstationUsage(t *testing.T) {
	ctx, _, errOut := ctxWith(nil, fake.New())
	if code := createWorkstationCommand(ctx); code != 2 {
		t.Fatalf("code=%d", code)
	}
	if !strings.Contains(errOut.String(), "usage") {
		t.Fatalf("stderr %q", errOut.String())
	}
}

// TestCreateWorkstationUnknownOption checks unknown options are refused, e.g.
// --docker, nothing is created.
func TestCreateWorkstationUnknownOption(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "mon")
	ctx, _, errOut := ctxWith([]string{target, "--docker"}, fake.New())
	if code := createWorkstationCommand(ctx); code != 1 {
		t.Fatalf("code=%d", code)
	}
	if !strings.Contains(errOut.String(), "unknown option: --docker") {
		t.Fatalf("stderr %q", errOut.String())
	}
	if _, err := os.Stat(target); err == nil {
		t.Fatal("target created")
	}
}

// TestCreateWorkstationGitopsNeedsValue checks a trailing --gitops is refused.
func TestCreateWorkstationGitopsNeedsValue(t *testing.T) {
	ctx, _, errOut := ctxWith([]string{filepath.Join(t.TempDir(), "mon"), "--gitops"}, fake.New())
	if code := createWorkstationCommand(ctx); code != 1 {
		t.Fatalf("code=%d", code)
	}
	if !strings.Contains(errOut.String(), "--gitops expects a value") {
		t.Fatalf("stderr %q", errOut.String())
	}
}

// TestCreateWorkstationCreates checks the Go command creates the folder in
// kubernetes mode against a ready cluster, silently when nothing fails.
func TestCreateWorkstationCreates(t *testing.T) {
	t.Setenv("DEVZONE_NO_START", "1")
	pkg := t.TempDir()
	for _, d := range []string{".devcontainer", "manage/scripts"} {
		if err := os.MkdirAll(filepath.Join(pkg, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(pkg, "manage", "scripts", "uninstall.sh"), []byte("#!/usr/bin/env bash\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	for name, body := range map[string]string{"Makefile": "all:\n", ".gitattributes": "*\n", "README.md": "#\n", "LICENSE": "l\n"} {
		if err := os.WriteFile(filepath.Join(pkg, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(pkg, "package.json"), []byte(`{"version":"1.2.3"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DEVZONE_PAQUET", pkg)
	dir := t.TempDir()
	target := filepath.Join(dir, "mon")
	runner := fake.New()
	readyKube(runner)
	ctx, out, errOut := ctxWith([]string{target, "--kubernetes", "--gitops", "none"}, runner)
	if code := createWorkstationCommand(ctx); code != 0 {
		t.Fatalf("code=%d stderr=%s", code, errOut.String())
	}
	if !strings.Contains(out.String(), "devzone 1.2.3 created in") {
		t.Fatalf("stdout %q", out.String())
	}
	modules, _ := os.ReadFile(filepath.Join(target, ".devzone.modules"))
	if string(modules) != "workspace=kubernetes\n" {
		t.Fatalf(".devzone.modules %q", modules)
	}
}
