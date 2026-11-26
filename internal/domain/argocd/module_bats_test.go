package argocd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// TestBatsArgocdStatusDisabled mirrors "argocd: disabled by default, module status optional".
func TestBatsArgocdStatusDisabled(t *testing.T) {
	f := newModFixture(t)
	code := f.run("status")
	if code != 0 || strings.TrimSpace(f.out.String()) != "disabled" {
		t.Fatalf("code=%d out=%q", code, f.out.String())
	}
}

// TestBatsArgocdStatusReadyRelayStopped mirrors status after installation relay stopped.
func TestBatsArgocdStatusReadyRelayStopped(t *testing.T) {
	f := newModFixture(t)
	f.markInstalled(t)
	code := f.run("status")
	if code != 0 || !strings.Contains(f.out.String(), "relay stopped") {
		t.Fatalf("code=%d out=%q err=%q", code, f.out.String(), f.err.String())
	}
}

// TestBatsArgocdAppModuleDisabled mirrors app refusal when module is off.
func TestBatsArgocdAppModuleDisabled(t *testing.T) {
	f := newModFixture(t)
	code := f.run("app", "list")
	if code != 2 || !strings.Contains(f.err.String(), "module off: devzone enable argocd") {
		t.Fatalf("code=%d err=%q", code, f.err.String())
	}
}

// TestBatsArgocdAppWorkspacePodRedirect mirrors workspace pod redirect.
func TestBatsArgocdAppWorkspacePodRedirect(t *testing.T) {
	f := newModFixture(t)
	f.markInstalled(t)
	t.Setenv("DEVZONE_WORKSPACE", "kubernetes")
	code := f.run("app", "list")
	if code != 2 || !strings.Contains(f.err.String(), "devzone workspace argocd app list") {
		t.Fatalf("code=%d err=%q", code, f.err.String())
	}
}

// TestBatsArgocdUninstall mirrors disable argocd uninstall behavior.
func TestBatsArgocdUninstall(t *testing.T) {
	f := newModFixture(t)
	f.markInstalled(t)
	f.r.On("helm", []string{"--kubeconfig", filepath.Join(f.root, "hote.config"), "--kube-context", "docker-desktop", "uninstall", "argocd", "-n", "devzone-argocd"}, fexec.Result{})
	f.r.On("kubectl", []string{"--context", "docker-desktop", "-n", "devzone-argocd", "delete", "rolebinding", "devzone-agent", "--ignore-not-found"}, fexec.Result{})
	f.r.On("kubectl", []string{"--context", "docker-desktop", "delete", "namespace", "devzone-argocd", "--wait=true"}, fexec.Result{})
	code := f.run("uninstall")
	if code != 0 {
		t.Fatalf("code=%d out=%q err=%q", code, f.out.String(), f.err.String())
	}
	if _, err := os.Stat(f.secrets); !os.IsNotExist(err) {
		t.Fatalf("secrets still exist")
	}
	if !strings.Contains(f.out.String(), "the services stay, under direct helm.") {
		t.Fatalf("out=%q", f.out.String())
	}
}
