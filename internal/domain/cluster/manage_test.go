package cluster

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/testkit"
)

// manageSetup creates a disposable state file and a fake runner for one command.
func manageSetup(t *testing.T, state string) (ManageOptions, *fake.Runner, *bytes.Buffer, *bytes.Buffer) {
	t.Helper()
	path := filepath.Join(testkit.TempHome(t), ".devzone.modules")
	if err := os.WriteFile(path, []byte(state), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DEVZONE_INSTANCE", "devzone")
	t.Setenv("DEVZONE_INTERACTIVE", "")
	host := filepath.Join(os.Getenv("HOME"), ".kube", "hote.config")
	if err := os.MkdirAll(filepath.Dir(host), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(host, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DEVZONE_KUBE_HOST", host)
	r := fake.New()
	r.On("kubectl", nil, exec.Result{})
	var out, errOut bytes.Buffer
	opts := ManageOptions{
		Runner: r, Out: &out, Err: &errOut, Stdin: strings.NewReader(""),
		StatePath: path,
		Install:   func() int { return 0 },
	}
	return opts, r, &out, &errOut
}

// programContextSet programs the two config queries and the write of the devzone context.
func programContextSet(r *fake.Runner, name string) {
	r.On("kubectl", []string{"config", "view", "-o", `{.contexts[?(@.name=="` + name + `")].context.cluster}`},
		exec.Result{Stdout: []byte(name + "-cluster\n")})
	r.On("kubectl", []string{"config", "view", "-o", `{.contexts[?(@.name=="` + name + `")].context.user}`},
		exec.Result{Stdout: []byte(name + "-user\n")})
	r.On("kubectl", []string{"config", "set-context", "devzone", "--cluster=" + name + "-cluster", "--user=" + name + "-user"},
		exec.Result{})
}

// TestChangeShow checks the read-only form of devzone cluster.
func TestChangeShow(t *testing.T) {
	opts, _, out, _ := manageSetup(t, "postgres=off\n")
	if code := Change(context.Background(), opts, nil); code != 0 {
		t.Fatalf("code = %d", code)
	}
	if !strings.Contains(out.String(), "no cluster chosen") || !strings.Contains(out.String(), "possible: kind-devzone") {
		t.Fatalf("out = %q", out.String())
	}
	opts, _, out, _ = manageSetup(t, "cluster=kind-devzone\n")
	if code := Change(context.Background(), opts, nil); code != 0 ||
		!strings.Contains(out.String(), "cluster kind-devzone (dedicated kind, in the container)") {
		t.Fatalf("code = %d, out = %q", code, out.String())
	}
}

// TestChangeToHostCluster checks the state write and the devzone context on a
// chosen local cluster.
func TestChangeToHostCluster(t *testing.T) {
	opts, r, out, errOut := manageSetup(t, "postgres=off\ncluster=kind-devzone\n")
	r.On("kubectl", []string{"config", "get-contexts", "-o", "name"}, exec.Result{Stdout: []byte("docker-desktop\n")})
	programContextSet(r, "docker-desktop")
	if code := Change(context.Background(), opts, []string{"docker-desktop"}); code != 0 {
		t.Fatalf("code = %d, err = %q", code, errOut.String())
	}
	if !strings.Contains(out.String(), "devzone : services cluster: docker-desktop") {
		t.Fatalf("out = %q", out.String())
	}
	data, _ := os.ReadFile(opts.StatePath)
	if !strings.Contains(string(data), "cluster=docker-desktop") {
		t.Fatalf("state = %q", data)
	}
}

// TestChangePostgresRequiresYes checks that a data loss is never implicit.
func TestChangePostgresRequiresYes(t *testing.T) {
	opts, r, _, errOut := manageSetup(t, "postgres=on\ncluster=kind-devzone\n")
	r.On("kubectl", []string{"config", "get-contexts", "-o", "name"}, exec.Result{Stdout: []byte("docker-desktop\n")})
	if code := Change(context.Background(), opts, []string{"docker-desktop"}); code != 1 ||
		!strings.Contains(errOut.String(), "databases will be deleted from kind-devzone") {
		t.Fatalf("code = %d, err = %q", code, errOut.String())
	}
}

// TestUseSwitchesWorkingCluster checks the context switch and the namespace.
func TestUseSwitchesWorkingCluster(t *testing.T) {
	opts, r, out, errOut := manageSetup(t, "cluster=kind-devzone\n")
	r.On("kubectl", []string{"config", "get-contexts", "-o", "name"}, exec.Result{Stdout: []byte("docker-desktop\nprod\n")})
	r.On("kubectl", []string{"config", "current-context"}, exec.Result{Stdout: []byte("docker-desktop\n")})
	r.On("kubectl", []string{"config", "use-context", "prod"}, exec.Result{})
	r.On("kubectl", []string{"config", "set-context", "prod", "--namespace", "gitlab"}, exec.Result{})
	code := Use(context.Background(), opts, []string{"prod", "--confirm", "prod", "-n", "gitlab"})
	if code != 0 {
		t.Fatalf("code = %d, err = %q", code, errOut.String())
	}
	if !strings.Contains(out.String(), "working cluster: prod") || !strings.Contains(out.String(), "namespace: gitlab") {
		t.Fatalf("out = %q", out.String())
	}
	data, _ := os.ReadFile(opts.StatePath)
	if strings.TrimSpace(string(data)) != "cluster=kind-devzone" {
		t.Fatalf("services cluster changed: %q", data)
	}
}

// TestUseRefusals checks unknown contexts and remote contexts without a confirmation.
func TestUseRefusals(t *testing.T) {
	opts, r, _, errOut := manageSetup(t, "")
	r.On("kubectl", []string{"config", "get-contexts", "-o", "name"}, exec.Result{Stdout: []byte("docker-desktop\nprod\n")})
	r.On("kubectl", []string{"config", "current-context"}, exec.Result{Stdout: []byte("docker-desktop\n")})
	if code := Use(context.Background(), opts, []string{"unknown"}); code != 2 ||
		!strings.Contains(errOut.String(), "unknown context: unknown") {
		t.Fatalf("unknown: code %d, err %q", code, errOut.String())
	}
	errOut.Reset()
	if code := Use(context.Background(), opts, []string{"prod"}); code != 2 ||
		!strings.Contains(errOut.String(), "remote cluster refused: prod (--confirm prod)") {
		t.Fatalf("remote: code %d, err %q", code, errOut.String())
	}
	for _, call := range r.Calls() {
		if strings.Contains(strings.Join(call.Args, " "), "use-context") {
			t.Fatalf("context switched: %+v", r.Calls())
		}
	}
}
