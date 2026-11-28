package command

import (
	"bytes"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// deployFixture builds an empty devzone folder and a fake runner: no test
// reaches a cluster, a chart command or the network.
func deployFixture(t *testing.T, argoCD string) (*fake.Runner, string, *bytes.Buffer, *bytes.Buffer) {
	t.Helper()
	root := t.TempDir()
	t.Setenv("DEVZONE_ROOT", root)
	t.Setenv("DEVZONE_STATE", filepath.Join(root, ".devzone.modules"))
	t.Setenv("DEVZONE_ARGOCD_REVISION", "")
	t.Setenv("DEVZONE_REPO_URL", "")
	t.Setenv("DEVZONE_ARGOCD_CONF", "")
	state := "kubernetes=on\n"
	if argoCD != "" {
		state += "argocd=" + argoCD + "\n"
	}
	writeDeployFile(t, filepath.Join(root, ".devzone.modules"), state)
	writeDeployFile(t, filepath.Join(root, "charts", "devzone-workspace", "Chart.yaml"), "name: devzone-workspace\n")
	r := fake.New()
	r.On("kubectl", []string{"config", "get-contexts", "-o", "name"},
		fexec.Result{Stdout: []byte("devzone\n")})
	r.On("kubectl", []string{"--context", "devzone", "get", "namespace", "devzone-argocd"}, fexec.Result{})
	out, errOut := &bytes.Buffer{}, &bytes.Buffer{}
	return r, root, out, errOut
}

// writeDeployFile writes a file of the disposable devzone folder of a test.
func writeDeployFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// deployRun executes the workspace deploy command with the injected runner.
func deployRun(r *fake.Runner, out, errOut *bytes.Buffer, args ...string) int {
	ctx := &cli.Context{Args: append([]string{"deploy"}, args...), Out: out, Err: errOut, Runner: r}
	return workspaceDeploy(ctx)
}

// TestWorkspaceDeployApplication checks that an active Argo CD creates the
// Application with the image parameters, without helm or destructive calls.

func TestWorkspaceDeployApplication(t *testing.T) {
	hostMode(t)
	r, root, out, errOut := deployFixture(t, "on")
	writeDeployFile(t, filepath.Join(root, "package.json"), `{"version": "1.2.3"}`+"\n")
	r.On("kubectl", []string{"--context", "devzone", "apply", "-f", "-"}, fexec.Result{})
	if code := deployRun(r, out, errOut, "registry/example", "1.2.3", "yes"); code != 0 {
		t.Fatalf("code = %d, err = %q", code, errOut.String())
	}
	manifest := ""
	for _, call := range r.Calls() {
		if call.Name == "kubectl" && strings.Join(call.Args, " ") == "--context devzone apply -f -" && call.Opts.Stdin != nil {
			data, err := io.ReadAll(call.Opts.Stdin)
			if err != nil {
				t.Fatal(err)
			}
			manifest = string(data)
		}
		if call.Name == "helm" {
			t.Fatalf("helm was called: %v", call.Args)
		}
		if call.Name == "kubectl" && strings.Contains(strings.Join(call.Args, " "), "delete") {
			t.Fatalf("a resource was deleted during adoption: %v", call.Args)
		}
	}
	for _, want := range []string{"kind: Application", "name: devzone-workspace", "targetRevision: v1.2.3",
		"name: image.tag", "value: \"1.2.3\"", "name: image.repository", "value: \"registry/example\""} {
		if !strings.Contains(manifest, want) {
			t.Fatalf("manifest misses %q: %s", want, manifest)
		}
	}
}

// TestWorkspaceDeployUnknownRevisionFails checks that no namespace, secret or
// helm step is started when the revision cannot be resolved.
func TestWorkspaceDeployUnknownRevisionFails(t *testing.T) {
	hostMode(t)
	r, root, out, errOut := deployFixture(t, "on")
	writeDeployFile(t, filepath.Join(root, "package.json"), `{"version": "0.0.0"}`+"\n")
	r.OnError("git", []string{"ls-remote", "--tags", "--refs", "https://github.com/SimBienvenueHoulBoumi/devzone.git"},
		fexec.Result{}, errors.New("network unreachable"))
	if code := deployRun(r, out, errOut, "registry/example", "1.2.3", "yes"); code == 0 {
		t.Fatal("start continued without a revision")
	}
	if !strings.Contains(errOut.String(), "cannot list the tags") || !strings.Contains(errOut.String(), "DEVZONE_ARGOCD_REVISION") {
		t.Fatalf("unclear failure: %q", errOut.String())
	}
	if len(r.Calls()) != 3 {
		t.Fatalf("partial installation: %v", r.Calls())
	}
	for _, call := range r.Calls() {
		if call.Name == "helm" || (call.Name == "kubectl" && strings.Contains(strings.Join(call.Args, " "), "apply")) {
			t.Fatalf("installation continued after the revision failure: %v", r.Calls())
		}
	}
}

// TestWorkspaceDeployHandsOffWithoutArgoCD checks that the Go command does
// nothing when Argo CD is off: the shell entry point keeps the historical
// helm path, with the same adoption of volumes and secrets.
func TestWorkspaceDeployHandsOffWithoutArgoCD(t *testing.T) {
	hostMode(t)
	r, _, out, errOut := deployFixture(t, "off")
	r.On("kubectl", []string{"--context", "devzone", "get", "namespace", "devzone-argocd"}, fexec.Result{Code: 1})
	if code := deployRun(r, out, errOut, "registry/example", "2.0.0", "no"); code != 3 {
		t.Fatalf("code = %d, want 3 (shell path)", code)
	}
	for _, call := range r.Calls() {
		if call.Name == "helm" {
			t.Fatalf("helm was called by Go: %v", call.Args)
		}
	}
}
