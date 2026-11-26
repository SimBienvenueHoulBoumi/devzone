package argocd

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/relay"
)

// relayCall records one requested port-forward of a test.
type relayCall struct {
	name, contextName, ns, target string
	ports                         []string
}

type modFixture struct {
	r       *fake.Runner
	root    string
	state   string
	out     bytes.Buffer
	err     bytes.Buffer
	secrets string
	relays  []relayCall
}

func newModFixture(t *testing.T) *modFixture {
	t.Helper()
	root := t.TempDir()
	t.Setenv("DEVZONE_ROOT", root)
	t.Setenv("DEVZONE_STATE", filepath.Join(root, ".devzone.modules"))
	t.Setenv("DEVZONE_KUBE_HOST", filepath.Join(root, "hote.config"))
	t.Setenv("DEVZONE_KUBE_CONFIG", filepath.Join(root, "config"))
	t.Setenv("DEVZONE_POD_SCRIPT", "")
	t.Setenv("DEVZONE_WORKSPACE", "")
	t.Setenv("HOME", t.TempDir())
	if err := os.MkdirAll(filepath.Join(root, "workspace"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, ".devzone.modules"), []byte("argocd=off\ncluster=docker-desktop\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	// empty host kubeconfig
	if err := os.WriteFile(filepath.Join(root, "hote.config"), []byte{}, 0o644); err != nil {
		t.Fatal(err)
	}
	r := fake.New()
	f := &modFixture{r: r, root: root, state: filepath.Join(root, ".devzone.modules"), secrets: filepath.Join(root, "workspace", ".argocd")}
	// common kubectl responses
	r.On("kubectl", []string{"config", "get-contexts", "-o", "name"}, fexec.Result{Stdout: []byte("docker-desktop\n")})
	r.On("kubectl", []string{"--context", "docker-desktop", "get", "nodes", "-o", "jsonpath={range .items[*]}{.status.allocatable.memory}{\"\\n\"}{end}"}, fexec.Result{Stdout: []byte("2Gi\n")})
	r.On("kubectl", []string{"--context", "devzone", "get", "nodes", "-o", "jsonpath={range .items[*]}{.status.allocatable.memory}{\"\\n\"}{end}"}, fexec.Result{Stdout: []byte("2Gi\n")})
	r.On("kubectl", []string{"--context", "docker-desktop", "get", "namespace", "devzone-argocd"}, fexec.Result{Code: 1})
	r.On("kubectl", []string{"--context", "docker-desktop", "create", "namespace", "devzone-argocd", "--dry-run=client", "-o", "yaml"}, fexec.Result{Stdout: []byte("kind: Namespace\nmetadata:\n  name: devzone-argocd\n")})
	r.On("kubectl", []string{"--context", "docker-desktop", "apply", "-f", "-"}, fexec.Result{})
	r.On("kubectl", []string{"--context", "docker-desktop", "label", "namespace", "devzone-argocd", "app.kubernetes.io/managed-by=devzone", "--overwrite"}, fexec.Result{})
	// account allow
	r.On("kubectl", []string{"--context", "docker-desktop", "create", "namespace", "devzone-system", "--dry-run=client", "-o", "yaml"}, fexec.Result{Stdout: []byte("kind: Namespace\n")})
	r.On("kubectl", []string{"--context", "docker-desktop", "-n", "devzone-system", "create", "serviceaccount", "devzone-agent", "--dry-run=client", "-o", "yaml"}, fexec.Result{Stdout: []byte("kind: ServiceAccount\n")})
	r.On("kubectl", []string{"--context", "docker-desktop", "-n", "devzone-argocd", "create", "rolebinding", "devzone-agent", "--clusterrole=edit", "--serviceaccount=devzone-system:devzone-agent", "--dry-run=client", "-o", "yaml"}, fexec.Result{Stdout: []byte("kind: RoleBinding\n")})
	// isolation
	r.On("kubectl", []string{"--context", "devzone", "-n", "devzone-argocd", "apply", "-f", "-"}, fexec.Result{})
	// helm
	r.On("helm", []string{"dependency", "build", filepath.Join(root, "charts", "devzone-argocd")}, fexec.Result{})
	r.On("helm", []string{"--kubeconfig", filepath.Join(root, "hote.config"), "--kube-context", "docker-desktop", "upgrade", "--install", "argocd", filepath.Join(root, "charts", "devzone-argocd"), "--namespace", "devzone-argocd", "--create-namespace", "--timeout", "600s", "--wait"}, fexec.Result{})
	// admin secret
	r.On("kubectl", []string{"--context", "devzone", "-n", "devzone-argocd", "get", "secret", "argocd-initial-admin-secret", "-o", "jsonpath={.data.password}"}, fexec.Result{Stdout: []byte("c2VjcmV0LWFkbWlu")})
	// credentials are regenerated in Go and the relay uses the Go launcher
	return f
}

// launcher records the relay request and returns a PID that is not alive.
func (f *modFixture) launcher(dir, name, contextName, ns, target string, ports []string) (int, error) {
	f.relays = append(f.relays, relayCall{name: name, contextName: contextName, ns: ns, target: target, ports: ports})
	return 99999999, nil
}

func (f *modFixture) opts() Options {
	return Options{Runner: f.r, Launcher: relay.Launcher(f.launcher), Out: &f.out, Err: &f.err,
		Root: f.root, StatePath: f.state, KubeHost: filepath.Join(f.root, "hote.config"), KubeConfig: filepath.Join(f.root, "config")}
}

func (f *modFixture) run(args ...string) int {
	return Run(context.Background(), args, &f.out, &f.err, f.opts())
}

func (f *modFixture) markInstalled(t *testing.T) {
	t.Helper()
	f.r.On("kubectl", []string{"--context", "docker-desktop", "get", "namespace", "devzone-argocd"}, fexec.Result{})
	if err := os.MkdirAll(f.secrets, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(f.secrets, "admin.env"), []byte("ARGOCD_URL=https://127.0.0.1:8443\nARGOCD_USER=admin\nARGOCD_PASSWORD=secret-admin\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(f.state, []byte("argocd=on\ncluster=docker-desktop\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestArgocdStatusDisabled(t *testing.T) {
	f := newModFixture(t)
	code := f.run("status")
	if code != 0 || strings.TrimSpace(f.out.String()) != "disabled" {
		t.Fatalf("code=%d out=%q err=%q", code, f.out.String(), f.err.String())
	}
}

func TestArgocdInstall(t *testing.T) {
	f := newModFixture(t)
	code := f.run("install")
	if code != 0 {
		t.Fatalf("code=%d out=%q err=%q", code, f.out.String(), f.err.String())
	}
	if !strings.Contains(f.out.String(), "✔ argocd module ready: https://127.0.0.1:8443") {
		t.Fatalf("out=%q", f.out.String())
	}
	data, err := os.ReadFile(filepath.Join(f.secrets, "admin.env"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "ARGOCD_PASSWORD=secret-admin") {
		t.Fatalf("admin.env=%q", data)
	}
	info, _ := os.Stat(filepath.Join(f.secrets, "admin.env"))
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("mode=%v", info.Mode().Perm())
	}
	if strings.Contains(f.out.String(), "secret-admin") {
		t.Fatalf("password leaked: %q", f.out.String())
	}
}

func TestArgocdInstallMemoryRefused(t *testing.T) {
	f := newModFixture(t)
	f.r.On("kubectl", []string{"--context", "devzone", "get", "nodes", "-o", "jsonpath={range .items[*]}{.status.allocatable.memory}{\"\\n\"}{end}"}, fexec.Result{Stdout: []byte("512Mi\n")})
	code := f.run("install")
	if code != 2 {
		t.Fatalf("code=%d out=%q err=%q", code, f.out.String(), f.err.String())
	}
	if !strings.Contains(f.out.String()+f.err.String(), "at least 1 GB of allocatable memory") {
		t.Fatalf("out=%q err=%q", f.out.String(), f.err.String())
	}
}
