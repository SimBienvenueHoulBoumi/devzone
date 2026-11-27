package command

import (
	"bytes"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// kubeReadyRun runs the internal command with a fake runner and an injected
// lookup that finds only the named programs, so no cluster, PATH or installed
// program is touched.
func kubeReadyRun(t *testing.T, args, programs []string, setup func(*fake.Runner)) (int, string, string, *fake.Runner) {
	t.Helper()
	r := fake.New()
	if setup != nil {
		setup(r)
	}
	var out, errOut bytes.Buffer
	ctx := &cli.Context{Args: args, Out: &out, Err: &errOut, Runner: r}
	return kubeReadyCommandWith(ctx, programLookPath(programs...)), out.String(), errOut.String(), r
}

// kubeReadyPrograms programs the fake answers of a reachable devzone context.
func kubeReadyPrograms(r *fake.Runner) {
	r.On("kubectl", []string{"config", "get-contexts", "-o", "name"}, exec.Result{Stdout: []byte("devzone\n")})
	r.On("kubectl", []string{"cluster-info", "--request-timeout=5s", "--context", "devzone"}, exec.Result{})
}

// kubeReadyUnreachable programs the fake answers of a context that does not answer.
func kubeReadyUnreachable(r *fake.Runner) {
	r.On("kubectl", []string{"config", "get-contexts", "-o", "name"}, exec.Result{Stdout: []byte("devzone\n")})
	r.On("kubectl", []string{"cluster-info", "--request-timeout=5s", "--context", "devzone"}, exec.Result{Code: 1})
	r.On("kubectl", []string{"config", "view", "--minify", "--context", "devzone", "-o", `jsonpath={.clusters[0].cluster.server}`},
		exec.Result{Stdout: []byte("https://127.0.0.1:6443\n")})
}

// TestKubeReadyReady checks that a reachable cluster gives status 0 and no output.
func TestKubeReadyReady(t *testing.T) {
	code, out, errOut, _ := kubeReadyRun(t, nil, []string{"kubectl", "helm"}, kubeReadyPrograms)
	if code != 0 || out != "" || errOut != "" {
		t.Fatalf("code = %d, stdout = %q, stderr = %q; want 0 and no output", code, out, errOut)
	}
}

// TestKubeReadyShortOutput checks that the shell caller captures one short line
// on stdout and the failure status.
func TestKubeReadyShortOutput(t *testing.T) {
	code, out, errOut, _ := kubeReadyRun(t, nil, []string{"kubectl", "helm"}, kubeReadyUnreachable)
	want := "cluster devzone unreachable (https://127.0.0.1:6443)\n"
	if code != 1 || out != want || errOut != "" {
		t.Fatalf("code = %d, stdout = %q, stderr = %q; want 1 and %q", code, out, errOut, want)
	}
}

// TestKubeReadyHintOutput checks that --hint switches to the user message.
func TestKubeReadyHintOutput(t *testing.T) {
	code, out, _, _ := kubeReadyRun(t, []string{"--hint"}, []string{"kubectl", "helm"}, kubeReadyUnreachable)
	want := "✖ Kubernetes cluster devzone unreachable (https://127.0.0.1:6443)\n  Check the contexts: kubectl config get-contexts\n"
	if code != 1 || out != want {
		t.Fatalf("code = %d, stdout = %q; want 1 and %q", code, out, want)
	}
}

// TestKubeReadyMissingProgram checks that a missing program is reported without
// running any fake command.
func TestKubeReadyMissingProgram(t *testing.T) {
	code, out, _, r := kubeReadyRun(t, nil, []string{"helm"}, nil)
	if code != 1 || out != "kubectl missing\n" {
		t.Fatalf("code = %d, stdout = %q; want 1 and kubectl missing", code, out)
	}
	if calls := r.Calls(); len(calls) != 0 {
		t.Fatalf("calls = %+v; want none", calls)
	}
}

// TestKubeReadyUsage checks that an unknown argument is refused with status 2.
func TestKubeReadyUsage(t *testing.T) {
	code, out, errOut, r := kubeReadyRun(t, []string{"--other"}, []string{"kubectl", "helm"}, nil)
	if code != 2 || out != "" || !strings.Contains(errOut, "usage: devzone kube-ready") {
		t.Fatalf("code = %d, stdout = %q, stderr = %q", code, out, errOut)
	}
	if calls := r.Calls(); len(calls) != 0 {
		t.Fatalf("calls = %+v; want none", calls)
	}
}
