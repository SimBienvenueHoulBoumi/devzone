package e2e

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// TestE2EFullDisable checks --complet: disable first, check the namespace and
// the labelled pods, then reinstall with the seven other steps.
func TestE2EFullDisable(t *testing.T) {
	f := newFixture(t)
	cleanDisable(f)
	t.Setenv("DEVZONE_INSTANCE", "mon-devzone")
	f.r.On("kubectl", []string{"--context", "devzone", "get", "namespace", "devzone-gitlab-mon-devzone"}, execResultCode(1))
	f.r.On("kubectl", []string{"--context", "devzone", "get", "pods", "--all-namespaces",
		"-l", "devzone.instance=mon-devzone", "-o", "name"}, exec.Result{})
	if code := f.run("--complet"); code != 0 {
		t.Fatalf("code = %d, stderr = %q", code, f.err.String())
	}
	if !strings.Contains(f.out.String(), "✔ 8. full: disable") {
		t.Errorf("output = %q", f.out.String())
	}
	if !f.hasCall("disable gitlab") || !f.hasCall("get namespace devzone-gitlab-mon-devzone") ||
		!f.hasCall("get pods --all-namespaces -l devzone.instance=mon-devzone -o name") {
		t.Errorf("checks missing in %v", f.calls())
	}
	if !f.hasCall("is-enabled gitlab") {
		t.Errorf("steps 1 to 7 did not run: %v", f.calls())
	}
}

// TestE2EFullLeftovers checks each leftover of step 8 with its reason.
func TestE2EFullLeftovers(t *testing.T) {
	for _, tc := range []struct {
		name, want string
		setup      func(*fixture)
	}{
		{"namespace", "namespace devzone-gitlab", func(f *fixture) {
			f.r.On("kubectl", []string{"--context", "devzone", "get", "namespace", "devzone-gitlab"}, exec.Result{})
		}},
		{"pod", "labelled container(s) devzone.instance=devzone", func(f *fixture) {
			f.r.On("kubectl", []string{"--context", "devzone", "get", "pods", "--all-namespaces",
				"-l", "devzone.instance=devzone", "-o", "name"}, execResultOut("pod/devzone-web-1\n"))
		}},
		{"secret", "/workspace/.gitlab;", func(f *fixture) {}},
		{"hosts", "/etc/hosts line", func(f *fixture) {}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newFixture(t)
			tc.setup(f)
			if code := f.run("--complet"); code == 0 {
				t.Fatal("code = 0, want failure")
			}
			if !strings.Contains(f.out.String(), "✖ 8. full: disable") ||
				!strings.Contains(f.out.String(), tc.want) {
				t.Errorf("output = %q", f.out.String())
			}
		})
	}
}

// TestE2EFullOnlyPods checks that the leftovers of the instance are read from
// pods only: no other tool than the fakes of the steps is ever called.
func TestE2EFullOnlyPods(t *testing.T) {
	f := newFixture(t)
	cleanDisable(f)
	if code := f.run("--complet"); code != 0 {
		t.Fatalf("code = %d", code)
	}
	for _, c := range f.r.Calls() {
		switch c.Name {
		case "devzone", "kubectl", "git", "ssh-keygen", "bats", "gh", "getent", f.glabPath():
		default:
			t.Errorf("unexpected command %q in %v", c.Name, f.calls())
		}
	}
	if !f.hasCall("-l devzone.instance=devzone -o name") {
		t.Errorf("no pod label check in %v", f.calls())
	}
}

// cleanDisable simulates a complete disable: the secrets folder disappears,
// then the fake devzone enable recreates it with the root token.
func cleanDisable(f *fixture) {
	if err := os.RemoveAll(filepath.Join(f.root, "workspace", ".gitlab")); err != nil {
		f.t.Fatal(err)
	}
	f.r.On(scriptName(), []string{"is-enabled", "gitlab"}, execResultCode(1))
	f.write(f.hosts, "127.0.0.1 localhost\n")
	f.hook = func(name string, args []string) {
		if name == scriptName() && strings.Join(args, " ") == "enable gitlab" {
			dir := filepath.Join(f.root, "workspace", ".gitlab")
			if err := os.MkdirAll(dir, 0o755); err != nil {
				f.t.Error(err)
			}
			f.write(filepath.Join(dir, "root-token"), "token-root-secret\n")
		}
	}
}

// glabPath returns the fake path of the platform CLI of the fixture.
func (f *fixture) glabPath() string { return filepath.Join(f.home, ".local", "bin", "glab") }
