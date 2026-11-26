package command

import (
	"bytes"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// hostCheckRun runs hostCheckCommand with a fake runner programmed by setup
// and returns the status and the standard error
func hostCheckRun(t *testing.T, args []string, setup func(*fake.Runner)) (int, string) {
	t.Helper()
	r := fake.New()
	if setup != nil {
		setup(r)
	}
	var errOut bytes.Buffer
	ctx := &cli.Context{Args: args, Out: &bytes.Buffer{}, Err: &errOut, Runner: r}
	return hostCheckCommand(ctx), errOut.String()
}

// TestHostCheckAnswering: docker info succeeds, status 0, nothing printed
func TestHostCheckAnswering(t *testing.T) {
	t.Setenv("DEVZONE_DOCKER", "")
	code, errOut := hostCheckRun(t, []string{"make desinstaller"}, func(r *fake.Runner) {
		r.On("docker", []string{"info"}, exec.Result{})
	})
	if code != 0 || errOut != "" {
		t.Fatalf("code = %d, stderr = %q; want 0 and nothing", code, errOut)
	}
}

// TestHostCheckStopped: docker info fails, status 1 and the stopped message
func TestHostCheckStopped(t *testing.T) {
	t.Setenv("DEVZONE_DOCKER", "")
	code, errOut := hostCheckRun(t, []string{"devzone uninstall"}, func(r *fake.Runner) {
		r.On("docker", []string{"info"}, exec.Result{Code: 1, Stderr: []byte("no such file")})
	})
	if code != 1 {
		t.Fatalf("code = %d, want 1", code)
	}
	if !strings.Contains(errOut, "Start Docker Desktop") || !strings.HasSuffix(errOut, "then run devzone uninstall again\n") {
		t.Fatalf("stderr = %q", errOut)
	}
}

// TestHostCheckUsesDevzoneDocker: DEVZONE_DOCKER names the command probed,
// and only that command is run
func TestHostCheckUsesDevzoneDocker(t *testing.T) {
	t.Setenv("DEVZONE_DOCKER", "docker-autre")
	r := fake.New()
	r.On("docker-autre", []string{"info"}, exec.Result{})
	var errOut bytes.Buffer
	ctx := &cli.Context{Args: []string{"x"}, Out: &bytes.Buffer{}, Err: &errOut, Runner: r}
	if code := hostCheckCommand(ctx); code != 0 {
		t.Fatalf("code = %d, want 0 with docker-autre answering", code)
	}
	calls := r.Calls()
	if len(calls) != 1 || calls[0].Name != "docker-autre" {
		t.Fatalf("calls = %+v, want one call to docker-autre", calls)
	}
}

// TestHostCheckUsage: anything but one command name is refused with status 2
func TestHostCheckUsage(t *testing.T) {
	for _, args := range [][]string{nil, {"a", "b"}} {
		code, errOut := hostCheckRun(t, args, nil)
		if code != 2 || !strings.Contains(errOut, "usage: devzone host-check") {
			t.Fatalf("args %q: code = %d, stderr = %q", args, code, errOut)
		}
	}
}
